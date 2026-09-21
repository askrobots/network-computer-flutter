import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'protocol.dart';

/// Endpoint + Basic auth for the rendezvous.
class Endpoint {
  final Uri base; // http(s)://host:port
  final String user, password;
  Endpoint(this.base, this.user, this.password);

  String get authHeader =>
      'Basic ${base64.encode(utf8.encode('$user:$password'))}';

  Uri get wsUri {
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return base.replace(scheme: scheme, path: '/ws');
  }
}

/// WebSocket signaling + the /config and /hosts HTTP calls, all Basic-authed.
class SignalingClient {
  final Endpoint ep;
  WebSocket? _ws;
  void Function(SignalMessage)? onMessage;
  void Function(Object?)? onClose;

  SignalingClient(this.ep);

  final _http = HttpClient();

  Future<T> _getJson<T>(String path, T Function(dynamic) parse) async {
    final req = await _http.getUrl(ep.base.replace(path: path));
    req.headers.set(HttpHeaders.authorizationHeader, ep.authHeader);
    final resp = await req.close();
    if (resp.statusCode == 401) throw 'Rendezvous rejected the password';
    if (resp.statusCode >= 300) throw 'Rendezvous returned HTTP ${resp.statusCode}';
    final body = await resp.transform(utf8.decoder).join();
    return parse(jsonDecode(body));
  }

  Future<List<IceServer>> fetchIceServers() => _getJson('/config', (j) =>
      ((j['iceServers'] as List?) ?? [])
          .map((e) => IceServer.fromJson((e as Map).cast<String, dynamic>()))
          .toList());

  Future<List<String>> fetchHosts() =>
      _getJson('/hosts', (j) => (j as List).cast<String>());

  Future<void> connect() async {
    final ws = await WebSocket.connect(ep.wsUri.toString(),
        headers: {HttpHeaders.authorizationHeader: ep.authHeader});
    _ws = ws;
    ws.listen(
      (data) {
        try {
          onMessage?.call(SignalMessage.fromJson(jsonDecode(data as String)));
        } catch (_) {}
      },
      onDone: () => onClose?.call(null),
      onError: (e) => onClose?.call(e),
      cancelOnError: true,
    );
  }

  void send(SignalMessage m) => _ws?.add(jsonEncode(m.toJson()));
  void close() => _ws?.close();
}
