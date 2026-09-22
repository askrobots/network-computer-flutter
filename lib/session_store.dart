import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'protocol.dart';
import 'signaling.dart';
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

      sig.onMessage = (m) async {
        switch (m.type) {
          case 'answer':
            if (m.pair != null) await _savePair(m.pair!);
            if (m.sdp != null) await peer.setAnswer(m.sdp!);
            break;
          case 'ice':
            if (m.candidate != null) await peer.addCandidate(m.candidate!);
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
    await _peer?.close();
    _peer = null;
    _sig?.close();
    _sig = null;
  }

  void send(InputEvent e) => _peer?.send(e);

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
  Future<String?> _loadPair() async =>
      (await SharedPreferences.getInstance()).getString(_pairKey());
  Future<void> _savePair(String t) async =>
      (await SharedPreferences.getInstance()).setString(_pairKey(), t);
  Future<void> _clearPair() async =>
      (await SharedPreferences.getInstance()).remove(_pairKey());

  /// Whether a pairing token is stored for [ep] + [host] (for the UI hint).
  static Future<bool> isPaired(Endpoint ep, String host) async =>
      (await SharedPreferences.getInstance()).getString('pair:${ep.base}|$host') != null;

  void _set(ConnState s, String msg) { state = s; status = msg; notifyListeners(); }
  void _fail(String msg) { state = ConnState.failed; status = msg; notifyListeners(); }

  @override
  void dispose() { _teardown(); renderer.dispose(); super.dispose(); }
}
