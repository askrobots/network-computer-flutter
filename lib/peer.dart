import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
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
  RTCDataChannel? _file;          // opened with the others: later ones never report open here
  RTCDataChannel? _fileIn;        // files from the desk
  String? _inName;
  int _inSize = 0;
  BytesBuilder? _inData;
  Completer<String>? _fileAnswer;
  Future<void> _fileQueue = Future.value();
  MediaStream? _mic;
  Timer? _statsTimer;
  int _lastBytes = 0, _lastFrames = 0;
  DateTime _lastAt = DateTime.now();

  void Function(Map<String, dynamic> candidate)? onIceCandidate;
  void Function(RTCPeerConnectionState)? onState;
  void Function(PeerStats)? onStats;
  void Function()? onControlOpen;
  /// A file from the desk was saved (its path), or failed (null, reason).
  void Function(String? path, String note)? onFileReceived;
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

    pc.onTrack = (event) async {
      debugPrint('nc track: ${event.track.kind} streams=${event.streams.length}');
      if (event.track.kind != 'video') return;
      MediaStream stream;
      if (event.streams.isNotEmpty) {
        stream = event.streams[0];
      } else {
        // some platforms deliver the track without its stream: wrap it ourselves
        stream = await createLocalMediaStream('remote-video');
        await stream.addTrack(event.track);
      }
      renderer.srcObject = stream;
      debugPrint('nc renderer: textureId=${renderer.textureId} src=${renderer.srcObject?.id}');
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
    // The microphone is opened with the connection and attached muted; the mic
    // button only unmutes it. Attaching a track later (replaceTrack) left the
    // iPhone sending no audio at all. No permission: the call works without.
    MediaStreamTrack? micTrack;
    try {
      final mic = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true, // keep the desktop's sound out of the mic
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });
      _mic = mic;
      micTrack = mic.getAudioTracks().first;
      micTrack.enabled = false;
    } catch (e) {
      debugPrint('nc mic: unavailable ($e)');
    }
    final init = RTCRtpTransceiverInit(
        direction: TransceiverDirection.SendRecv, streams: _mic == null ? [] : [_mic!]);
    if (micTrack != null) {
      await pc.addTransceiver(track: micTrack, kind: RTCRtpMediaType.RTCRtpMediaTypeAudio, init: init);
    } else {
      await pc.addTransceiver(kind: RTCRtpMediaType.RTCRtpMediaTypeAudio, init: init);
    }
    await _loudspeaker(); // capturing puts iOS in call mode: earpiece otherwise

    _input = await pc.createDataChannel(
        'input', RTCDataChannelInit()..ordered = false..maxRetransmits = 0);
    final file = await pc.createDataChannel('file', RTCDataChannelInit()); // reliable, ordered
    _file = file;
    file.onMessage = (m) {
      final a = _fileAnswer;
      if (a != null && !a.isCompleted && !m.isBinary) a.complete(m.text);
    };
    // files from the desk ("Send to my device") arrive on a channel we open
    final fileIn = await pc.createDataChannel('file-in', RTCDataChannelInit());
    _fileIn = fileIn;
    fileIn.onMessage = _onFileIn;
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

  /// Send a file to the desk (saved on its Desktop): its own reliable channel,
  /// a JSON header, 16 KB pieces with flow control, then "end"; the desk
  /// answers "ok NAME" or "error: WHY". Same as the browser's file drop.
  Future<String> sendFile(String name, Uint8List data, void Function(double) progress) {
    // one file at a time on the file channel
    final done = _fileQueue.then((_) => _sendFileNow(name, data, progress));
    _fileQueue = done.then((_) {}, onError: (_) {});
    return done;
  }

  Future<String> _sendFileNow(String name, Uint8List data, void Function(double) progress) async {
    final ch = _file;
    if (ch == null || ch.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw 'the file channel is not open';
    }
    final answer = Completer<String>();
    _fileAnswer = answer;
    await ch.send(RTCDataChannelMessage(jsonEncode({'name': name, 'size': data.length})));
    const piece = 16 * 1024;
    for (var i = 0; i < data.length && !answer.isCompleted; i += piece) {
      while ((ch.bufferedAmount ?? 0) > 4 * 1024 * 1024) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      final end = i + piece < data.length ? i + piece : data.length;
      await ch.send(RTCDataChannelMessage.fromBinary(data.sublist(i, end)));
      progress(end / data.length);
    }
    if (!answer.isCompleted) await ch.send(RTCDataChannelMessage('end'));
    return answer.future.timeout(const Duration(minutes: 2));
  }

  /// A file from the desk: header, pieces, "end"; saved in the app's Documents
  /// (on iPhone: Files › On My iPhone › Network Computer); answers "ok NAME".
  Future<void> _onFileIn(RTCDataChannelMessage m) async {
    final ch = _fileIn;
    if (ch == null) return;
    if (m.isBinary) {
      _inData?.add(m.binary);
      return;
    }
    if (m.text != 'end') {
      try {
        final h = jsonDecode(m.text) as Map<String, dynamic>;
        _inName = '${h['name']}'.split('/').last.split('\\').last;
        _inSize = (h['size'] as num).toInt();
        _inData = BytesBuilder(copy: false);
      } catch (_) {
        await ch.send(RTCDataChannelMessage('error: bad header'));
      }
      return;
    }
    final name = _inName, data = _inData;
    _inName = null; _inData = null;
    if (name == null || data == null) return;
    if (data.length != _inSize) {
      await ch.send(RTCDataChannelMessage('error: got ${data.length} of $_inSize bytes'));
      onFileReceived?.call(null, '$name did not arrive whole');
      return;
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      var path = '${dir.path}/$name';
      final dot = name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name, ext = dot > 0 ? name.substring(dot) : '';
      for (var i = 2; File(path).existsSync(); i++) {
        path = '${dir.path}/$stem ($i)$ext';
      }
      await File(path).writeAsBytes(data.takeBytes());
      await ch.send(RTCDataChannelMessage('ok ${path.split('/').last}'));
      onFileReceived?.call(path, path.split('/').last);
    } catch (e) {
      await ch.send(RTCDataChannelMessage('error: $e'));
      onFileReceived?.call(null, '$name: $e');
    }
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

  /// Mute or unmute the microphone (opened with the connection).
  Future<void> setMic(bool on) async {
    final tracks = _mic?.getAudioTracks() ?? <MediaStreamTrack>[];
    if (tracks.isEmpty) {
      if (on) throw 'no microphone (allow it in Settings, then reconnect)';
      return;
    }
    for (final t in tracks) {
      t.enabled = on;
    }
    debugPrint('nc mic: ${on ? 'on' : 'off'}');
  }

  Future<void> _closeMic() async {
    for (final t in _mic?.getTracks() ?? <MediaStreamTrack>[]) {
      await t.stop();
    }
    await _mic?.dispose();
    _mic = null;
  }

  /// The desk's sound on the loudspeaker: iOS otherwise picks the earpiece for
  /// a call-style session.
  Future<void> _loudspeaker() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await Helper.setSpeakerphoneOn(true);
    } catch (e) {
      debugPrint('nc audio route: $e');
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
        case 'outbound-rtp':
          if (r.values['kind'] == 'audio') _micSent = r.values['bytesSent'];
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
    if (!kReleaseMode && ++_polls % 5 == 0 && inbound != null) {   // every 5 s in debug/profile runs
      final v = inbound.values;
      debugPrint('nc video: bytes=${v['bytesReceived']} packets=${v['packetsReceived']} '
          'framesReceived=${v['framesReceived']} decoded=${v['framesDecoded']} dropped=${v['framesDropped']} '
          'size=${v['frameWidth']}x${v['frameHeight']} decoder=${v['decoderImplementation']} '
          'keyframes=${v['keyFramesDecoded']} pli=${v['pliCount']} path=${s.path} '
          'view=${renderer.videoWidth}x${renderer.videoHeight} mic-bytes-sent=$_micSent');
    }
  }
  int _polls = 0;
  Object? _micSent;

  Future<void> close() async {
    _statsTimer?.cancel();
    await _closeMic();
    await _input?.close();
    await _file?.close();
    await _fileIn?.close();
    await _ctl?.close();
    await _pc?.close();
    renderer.srcObject = null;
  }
}
