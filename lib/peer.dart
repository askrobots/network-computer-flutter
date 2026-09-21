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

/// One WebRTC session to a host: receives video+audio, sends input on a data channel.
class PeerClient {
  final List<IceServer> ice;
  final bool relayOnly;
  final RTCVideoRenderer renderer;

  RTCPeerConnection? _pc;
  RTCDataChannel? _input;
  Timer? _statsTimer;
  int _lastBytes = 0, _lastFrames = 0;
  DateTime _lastAt = DateTime.now();

  void Function(Map<String, dynamic> candidate)? onIceCandidate;
  void Function(RTCPeerConnectionState)? onState;
  void Function(PeerStats)? onStats;

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
    await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly));

    _input = await pc.createDataChannel(
        'input', RTCDataChannelInit()..ordered = false..maxRetransmits = 0);
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
    await _input?.close();
    await _pc?.close();
    renderer.srcObject = null;
  }
}
