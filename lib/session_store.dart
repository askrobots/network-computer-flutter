import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'protocol.dart';
import 'signaling.dart';
import 'secrets.dart';
import 'peer.dart';

enum ConnState { idle, connecting, connected, failed }

/// App-wide connection state. Handles connect, auto-reconnect and input send.
class SessionStore extends ChangeNotifier {
  final renderer = RTCVideoRenderer();
  ConnState state = ConnState.idle;
  String status = '';
  List<String> hosts = [];
  PeerStats stats = PeerStats();
  bool micOn = false;

  // voice: the desk listens (nc-voice); here only the button and the transcript
  bool voiceOn = false, voicePanel = false, keepListening = false;
  String voiceState = 'Voice off';
  final List<(String, String)> voiceLines = []; // (kind, text): heard, said, did, error
  bool _micByVoice = false;
  Timer? _micOffTimer;

  /// A short message for the user (shown briefly by the session screen).
  String notice = '';
  int noticeSeq = 0;

  // screen size chosen for the desk: null keeps the host's default
  int? displayW, displayH;
  double displayScale = 1;
  String _clipIn = '';

  SignalingClient? _sig;
  PeerClient? _peer;
  Endpoint? _ep;
  String _host = '', _pin = '';
  bool _relayOnly = false, _wantRetry = false;
  int _retries = 0;

  Future<void> init() async => renderer.initialize();

  String mode = 'insecure';

  Future<void> refreshHosts(Endpoint ep) async {
    try {
      final c = SignalingClient(ep);
      await c.authenticate();
      mode = c.mode;
      hosts = await c.fetchHosts();
      notifyListeners();
    } catch (e) {
      _fail('$e');
    }
  }

  Future<void> connect(Endpoint ep, String host, String pin, bool relayOnly) async {
    _ep = ep; _host = host; _pin = pin; _relayOnly = relayOnly;
    _wantRetry = true; _retries = 0;
    await _open();
  }

  Future<void> _open() async {
    _set(ConnState.connecting, 'fetching config');
    try {
      final sig = SignalingClient(_ep!);
      await sig.authenticate();
      mode = sig.mode;
      final ice = await sig.fetchIceServers();
      final peer = PeerClient(ice, _relayOnly, renderer);
      _sig = sig; _peer = peer;

      peer.onIceCandidate = (c) =>
          sig.send(SignalMessage(type: 'ice', to: _host, candidate: c));
      peer.onState = (s) {
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _retries = 0;
          _set(ConnState.connected, '');
        } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _dropped();
        }
      };
      peer.onStats = (st) { stats = st; notifyListeners(); };
      peer.onControlOpen = _controlOpen;
      peer.onFileReceived = (path, note) {
        debugPrint('nc file in: $note -> $path');
        _say(path == null ? 'Not saved: $note'
            : defaultTargetPlatform == TargetPlatform.iOS ? 'From the desk: $note (Files › Network Computer)'
            : 'From the desk: $note ($path)');
      };
      peer.onControl = _onControl;

      // Candidates can arrive before the answer is applied (saving the pairing
      // token is async): hold them until it is, or they are rejected and lost.
      var answered = false;
      final early = <Map<String, dynamic>>[];
      sig.onMessage = (m) async {
        switch (m.type) {
          case 'answer':
            if (m.sdp != null) await peer.setAnswer(m.sdp!);
            answered = true;
            for (final c in early) {
              await peer.addCandidate(c);
            }
            early.clear();
            if (m.pair != null) await _savePair(m.pair!);
            break;
          case 'ice':
            if (m.candidate == null) break;
            if (answered) {
              await peer.addCandidate(m.candidate!);
            } else {
              early.add(m.candidate!);
            }
            break;
          case 'error':
            final err = (m.error ?? '').toLowerCase();
            if (err.contains('pairing')) await _clearPair();
            _fail(m.error ?? 'rendezvous error');
            if (err.contains('pin')) _wantRetry = false;
            break;
        }
      };
      sig.onClose = (_) {
        if (state == ConnState.connecting) _dropped();
      };

      await peer.start();
      _set(ConnState.connecting, 'signaling');
      await sig.connect();
      final sdp = await peer.createOffer();
      final pair = await _loadPair();
      sig.send(SignalMessage(
          type: 'offer', to: _host, sdp: sdp,
          pin: _pin.isEmpty ? null : _pin, pair: pair));
      _set(ConnState.connecting, 'waiting for $_host');
    } catch (e) {
      _fail('$e');
      await _teardown();
    }
  }

  void _dropped() {
    if (!_wantRetry) return;
    _set(ConnState.connecting, 'reconnecting…');
    _teardown();
    _retries++;
    final delay = Duration(milliseconds: (1000 * _retries).clamp(1000, 5000));
    Future.delayed(delay, () { if (_wantRetry) _open(); });
  }

  Future<void> disconnect() async {
    _wantRetry = false;
    await _teardown();
    _set(ConnState.idle, '');
  }

  Future<void> _teardown() async {
    micOn = false;
    voiceOn = false;
    _micByVoice = false;
    _micOffTimer?.cancel();
    await _peer?.close();
    _peer = null;
    _sig?.close();
    _sig = null;
  }

  void send(InputEvent e) => _peer?.send(e);

  void _say(String msg) { notice = msg; noticeSeq++; notifyListeners(); }

  Future<void> _controlOpen() async {
    // keys arrive as US positions (see the session screen's key map)
    _peer?.sendControl({'t': 'keyboard', 'layout': 'us'});
    // the desk's clock follows this device (Etc/GMT+4 is UTC-4: the sign is inverted)
    final off = DateTime.now().timeZoneOffset;
    if (off.inMinutes % 60 == 0) {
      final h = -off.inHours;
      _peer?.sendControl({'t': 'tz', 'text': h == 0 ? 'Etc/UTC' : 'Etc/GMT${h > 0 ? '+' : ''}$h'});
    }
    final p = await SharedPreferences.getInstance();
    keepListening = p.getBool('voiceKeep') ?? false;
    final w = p.getInt('displayW'), h = p.getInt('displayH');
    if (w != null && h != null) {
      setDisplay(w, h, p.getDouble('displayScale') ?? 1, save: false);
    }
    voiceOn = false;
    notifyListeners();
    // Developer test hook (--dart-define=NC_AUTO_VOICE=true): press the voice
    // button once, 3 s after connecting, so the mic path can be checked
    // end to end without a hand on the screen.
    if (const bool.fromEnvironment('NC_AUTO_VOICE')) {
      Future.delayed(const Duration(seconds: 3), toggleVoice);
    }
    // (--dart-define=NC_AUTO_SEND=/path/file): send that file after connecting.
    const autoSend = String.fromEnvironment('NC_AUTO_SEND');
    if (autoSend.isNotEmpty) {
      Future.delayed(const Duration(seconds: 2), () async {
        final data = File(autoSend).readAsBytesSync();
        await _sendBytes(autoSend.split('/').last, data);   // twice: the channel is reused
        await _sendBytes(autoSend.split('/').last, data);
      });
    }
  }

  void _onControl(Map<String, dynamic> m) {
    switch (m['t']) {
      case 'voice':
        _onVoice('${m['kind'] ?? ''}', '${m['text'] ?? ''}');
        break;
      case 'clip': // the desk's clipboard, in pieces
        _clipIn += '${m['text'] ?? ''}';
        if (m['more'] == true) return;
        final t = _clipIn;
        _clipIn = '';
        Clipboard.setData(ClipboardData(text: t));
        _say('Copied from the desk');
        break;
      case 'clipnone':
        _say("The desk's clipboard has no text");
        break;
    }
  }

  // ---------- voice ----------
  static const _states = {
    'listening': 'Listening…', 'hearing': 'Hearing you…',
    'thinking': 'Thinking…', 'off': 'Voice off',
  };

  void _onVoice(String kind, String text) {
    voicePanel = true;
    if (kind == 'state') {
      voiceState = _states[text] ?? text;
      if (text == 'off') _voiceStopped();
    } else {
      voiceLines.add((kind, text));
      if (voiceLines.length > 40) voiceLines.removeAt(0);
      if (kind == 'error' && text.contains('not running')) _voiceStopped();
    }
    notifyListeners();
  }

  void _voiceStopped() {
    voiceOn = false;
    voiceState = 'Voice off';
    if (_micByVoice) {
      // the reply's last words are still on their way: stop the mic a bit later
      _micOffTimer?.cancel();
      _micOffTimer = Timer(const Duration(milliseconds: 1500), () async {
        if (!voiceOn && _micByVoice && micOn) {
          _micByVoice = false;
          await toggleMic();
        }
      });
    }
  }

  /// One tap, one phrase (or continuous with keepListening). Turns the mic on if needed.
  Future<void> toggleVoice() async {
    final peer = _peer;
    if (peer == null || !peer.controlOpen) return;
    _micOffTimer?.cancel();
    if (!voiceOn) {
      if (!micOn) {
        await toggleMic();
        if (!micOn) return;
        _micByVoice = true;
        // the phone's audio takes a moment to start flowing: don't let the
        // desk start listening (and its 8 s timeout) before it does
        await Future.delayed(const Duration(milliseconds: 600));
      }
      voiceOn = true;
      voicePanel = true;
      voiceState = keepListening ? 'Starting…' : 'Say one thing…';
      peer.sendControl({'t': 'voice', 'on': true, 'once': !keepListening});
    } else {
      peer.sendControl({'t': 'voice', 'on': false});
      _voiceStopped();
    }
    notifyListeners();
  }

  Future<void> setKeepListening(bool v) async {
    keepListening = v;
    (await SharedPreferences.getInstance()).setBool('voiceKeep', v);
    notifyListeners();
  }

  void hideVoicePanel() { voicePanel = false; notifyListeners(); }

  // ---------- launcher, screen, clipboard ----------
  void launch() => _peer?.sendControl({'t': 'launch'});

  Future<void> setDisplay(int w, int h, double scale, {bool save = true}) async {
    displayW = w; displayH = h; displayScale = scale;
    _peer?.sendControl({'t': 'display', 'w': w, 'h': h, 's': scale});
    if (save) {
      final p = await SharedPreferences.getInstance();
      await p.setInt('displayW', w);
      await p.setInt('displayH', h);
      await p.setDouble('displayScale', scale);
      _say('Screen $w×$h at ${(scale * 100).round()}%');
    }
    notifyListeners();
  }

  /// This device's clipboard to the desk (then paste there as usual).
  Future<void> sendClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) { _say('No text on this clipboard'); return; }
    const piece = 4096;
    var i = 0;
    while (i < text.length) {
      var end = i + piece < text.length ? i + piece : text.length;
      // keep surrogate pairs together
      if (end < text.length && (text.codeUnitAt(end - 1) & 0xFC00) == 0xD800) end--;
      _peer?.sendControl({'t': 'clip', 'text': text.substring(i, end), 'more': end < text.length});
      i = end;
    }
    _say('Clipboard sent to the desk');
  }

  /// Photos, videos or files from this device to the desk's Desktop.
  Future<void> sendFiles() async {
    final peer = _peer;
    if (peer == null) return;
    final picked = await FilePicker.pickFiles(allowMultiple: true, withData: true);
    if (picked == null) return;
    for (final f in picked.files) {
      final data = f.bytes;
      if (data == null) { _say('${f.name}: could not read it'); continue; }
      await _sendBytes(f.name, data);
    }
  }

  Future<void> _sendBytes(String name, Uint8List data) async {
    final peer = _peer;
    if (peer == null) return;
    try {
      var shown = 0;
      final r = await peer.sendFile(name, data, (p) {
        final pct = (p * 100).round();
        if (pct >= shown + 20) { shown = pct; _say('Sending $name: $pct%'); }
      });
      debugPrint('nc file: $name -> $r');
      _say(r.startsWith('ok ') ? "On the desk's Desktop: ${r.substring(3)}" : '$name: $r');
    } catch (e) {
      debugPrint('nc file: $name failed: $e');
      _say('$name: $e');
    }
  }

  /// The desk's clipboard to this device.
  void getClipboard() => _peer?.sendControl({'t': 'clipnow'});

  Future<void> toggleMic() async {
    final want = !micOn;
    try {
      await _peer?.setMic(want);
      micOn = want;
    } catch (e) {
      micOn = false;
      status = 'Microphone unavailable: $e';
    }
    notifyListeners();
  }

  // Pairing: after a correct PIN the host returns a signed token; keep one per
  // rendezvous+host and offer it next time so the PIN is typed once.
  String _pairKey() => 'pair:${_ep!.base}|$_host';
  Future<String?> _loadPair() => Secrets.read(_pairKey());
  Future<void> _savePair(String t) => Secrets.write(_pairKey(), t);
  Future<void> _clearPair() => Secrets.delete(_pairKey());

  /// Whether a pairing token is stored for [ep] + [host] (for the UI hint).
  static Future<bool> isPaired(Endpoint ep, String host) async =>
      await Secrets.read('pair:${ep.base}|$host') != null;

  void _set(ConnState s, String msg) { state = s; status = msg; notifyListeners(); }
  void _fail(String msg) { state = ConnState.failed; status = msg; notifyListeners(); }

  @override
  void dispose() { _teardown(); renderer.dispose(); super.dispose(); }
}
