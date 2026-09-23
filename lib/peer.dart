import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'protocol.dart';

class PeerStats {
  String path = '?';
  double rttMs = 0, fps = 0, mbps = 0, jitterMs = 0;
  int width = 0, height = 0, lost = 0;
  bool relayed = false;
  String codec = '?';
}

/// One WebRTC session to a host: receives video+audio, sends input on an
/// unreliable "input" channel, and uses a reliable "control" channel for
/// everything that must arrive: screen size, keyboard layout, clipboard,
/// voice, the launcher (the same messages as the browser client).
class PeerClient {
  final List<IceServer> ice;
  final bool relayOnly;
  final RTCVideoRenderer renderer;

  RTCPeerConnection? _pc;
  RTCDataChannel? _input;
  RTCDataChannel? _ctl;
  RTCRtpTransceiver? _audioTx;
  MediaStream? _mic;
  Timer? _statsTimer;
  int _lastBytes = 0, _lastFrames = 0;
  DateTime _lastAt = DateTime.now();

  void Function(Map<String, dynamic> candidate)? onIceCandidate;
  void Function(RTCPeerConnectionState)? onState;
  void Function(PeerStats)? onStats;
  void Function()? onControlOpen;
  void Function(Map<String, dynamic>)? onControl;

  PeerClient(this.ice, this.relayOnly, this.renderer);

  Future<void> start() async {
    final config = {
      'iceServers': ice.map((e) => e.toMap()).toList(),
      'sdpSemantics': 'unified-plan',
      if (relayOnly) 'iceTransportPolicy': 'relay',
    };
    final pc = await createPeerConnection(config);
    _pc = pc;

    pc.onTrack = (event) {
      if (event.track.kind == 'video' && event.streams.isNotEmpty) {
        renderer.srcObject = event.streams[0];
      }
    };
    pc.onIceCandidate = (c) {
      final m = c.toMap();
      if (m['candidate'] != null) onIceCandidate?.call(Map<String, dynamic>.from(m));
    };
    pc.onConnectionState = (s) {
      onState?.call(s);
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) _startStats();
    };

    await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly));
    // Send+receive audio, but with no track until the mic is switched on:
    // setMic() attaches or detaches it without renegotiating.
    _audioTx = await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv));

    _input = await pc.createDataChannel(
        'input', RTCDataChannelInit()..ordered = false..maxRetransmits = 0);
    final ctl = await pc.createDataChannel('control', RTCDataChannelInit()); // reliable, ordered
    _ctl = ctl;
    ctl.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen) onControlOpen?.call();
    };
    ctl.onMessage = (m) {
      if (m.isBinary) return;
      try {
        final v = jsonDecode(m.text);
        if (v is Map<String, dynamic>) onControl?.call(v);
      } catch (_) {}
    };
  }

  bool get controlOpen => _ctl?.state == RTCDataChannelState.RTCDataChannelOpen;

  /// Send on the reliable control channel (in order, never dropped).
  void sendControl(Map<String, dynamic> m) {
    if (controlOpen) _ctl!.send(RTCDataChannelMessage(jsonEncode(m)));
  }

  Future<String> createOffer() async {
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    return offer.sdp!;
  }

  Future<void> setAnswer(String sdp) async =>
      _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));

  Future<void> addCandidate(Map<String, dynamic> c) async => _pc!.addCandidate(
      RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']));

  void send(InputEvent e) {
    final dc = _input;
    if (dc != null && dc.state == RTCDataChannelState.RTCDataChannelOpen) {
      dc.send(RTCDataChannelMessage(jsonEncode(e.toJson())));
    }
  }

  /// Switch the microphone on or off. The mic is captured only while on.
  Future<void> setMic(bool on) async {
    final tx = _audioTx;
    if (tx == null) return;
    if (on) {
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true, // keep the desktop's sound out of the mic
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });
      _mic = stream;
      await tx.sender.replaceTrack(stream.getAudioTracks().first);
      // Capturing puts iOS in call mode, which routes sound to the earpiece.
      await Helper.setSpeakerphoneOn(true);
    } else {
      await tx.sender.replaceTrack(null);
      for (final t in _mic?.getTracks() ?? <MediaStreamTrack>[]) {
        await t.stop();
      }
      await _mic?.dispose();
      _mic = null;
    }
  }

  void _startStats() {
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  Future<void> _poll() async {
    final pc = _pc;
    if (pc == null) return;
    final reports = await pc.getStats();
    final s = PeerStats();
    final cand = <String, StatsReport>{};
    StatsReport? pair, inbound;
    for (final r in reports) {
      switch (r.type) {
        case 'candidate-pair':
          if (r.values['nominated'] == true && r.values['state'] == 'succeeded') pair = r;
          break;
        case 'local-candidate':
        case 'remote-candidate':
          cand[r.id] = r;
          break;
        case 'inbound-rtp':
          if (r.values['kind'] == 'video') inbound = r;
          break;
      }
    }
    if (pair != null) {
      final l = cand[pair.values['localCandidateId']]?.values['candidateType'];
      final rc = cand[pair.values['remoteCandidateId']]?.values['candidateType'];
      s.relayed = l == 'relay' || rc == 'relay';
      s.path = '$l → $rc';
      s.rttMs = ((pair.values['currentRoundTripTime'] as num?) ?? 0).toDouble() * 1000;
    }
    if (inbound != null) {
      final now = DateTime.now();
      final dt = now.difference(_lastAt).inMilliseconds / 1000.0;
      final bytes = (inbound.values['bytesReceived'] as num?)?.toInt() ?? 0;
      final frames = (inbound.values['framesDecoded'] as num?)?.toInt() ?? 0;
      s.lost = (inbound.values['packetsLost'] as num?)?.toInt() ?? 0;
      if (dt > 0) {
        s.mbps = (bytes - _lastBytes) * 8 / dt / 1e6;
        s.fps = (frames - _lastFrames) / dt;
      }
      _lastBytes = bytes; _lastFrames = frames; _lastAt = now;
      s.width = (inbound.values['frameWidth'] as num?)?.toInt() ?? 0;
      s.height = (inbound.values['frameHeight'] as num?)?.toInt() ?? 0;
      s.jitterMs = ((inbound.values['jitter'] as num?) ?? 0).toDouble() * 1000;
    }
    onStats?.call(s);
  }

  Future<void> close() async {
    _statsTimer?.cancel();
    await setMic(false);
    await _input?.close();
    await _ctl?.close();
    await _pc?.close();
    renderer.srcObject = null;
  }
}
