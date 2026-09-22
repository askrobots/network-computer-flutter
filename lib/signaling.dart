import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'protocol.dart';

/// Endpoint + Basic auth for the rendezvous.
class Endpoint {
  final Uri base; // http(s)://host:port
  final String user, password;

  /// SHA-256 of the rendezvous certificate, for a self-signed secure-mode
  /// server. Empty means normal certificate-authority verification.
  final String fingerprint;
  Endpoint(this.base, this.user, this.password, {String fingerprint = ''})
      : fingerprint = normalizeFingerprint(fingerprint);

  String get authHeader =>
      'Basic ${base64.encode(utf8.encode('$user:$password'))}';

  Uri get wsUri {
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return base.replace(scheme: scheme, path: '/ws');
  }
}

/// Accepts "AB:CD:..", "abcd..", or "sha256 abcd.."; returns lowercase hex.
String normalizeFingerprint(String fp) {
  var f = fp.trim().toLowerCase();
  if (f.startsWith('sha256')) f = f.substring(6);
  return f.replaceAll(RegExp(r'[^0-9a-f]'), '');
}

/// An HttpClient for [ep]. With a fingerprint it trusts no certificate
/// authority at all and accepts exactly the one certificate whose SHA-256
/// matches, so a CA-issued cert from an attacker is refused too.
HttpClient clientFor(Endpoint ep) {
  if (ep.fingerprint.isEmpty) return HttpClient();
  final c = HttpClient(context: SecurityContext(withTrustedRoots: false));
  c.badCertificateCallback = (X509Certificate cert, String host, int port) =>
      sha256.convert(cert.der).toString() == ep.fingerprint;
  return c;
}

/// WebSocket signaling + the /config and /hosts HTTP calls.
///
/// Credentials are exchanged once at POST /auth for a bearer token, which is
/// then used for every call. The rendezvous also still accepts HTTP Basic, so
/// this degrades gracefully against an older server.
class SignalingClient {
  final Endpoint ep;
  WebSocket? _ws;
  String? _token;
  String mode = 'insecure';
  void Function(SignalMessage)? onMessage;
  void Function(Object?)? onClose;

  SignalingClient(this.ep) : _http = clientFor(ep);

  final HttpClient _http;

  /// Trade username+password for a token. Falls back to Basic if the server
  /// has no /auth endpoint.
  Future<void> authenticate() async {
    try {
      final req = await _http.postUrl(ep.base.replace(path: '/auth'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'user': ep.user, 'password': ep.password}));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode == 401) throw 'Rendezvous rejected the password';
      if (resp.statusCode == 404) return; // older server: stay on Basic
      if (resp.statusCode >= 300) throw 'Rendezvous returned HTTP ${resp.statusCode}';
      final j = jsonDecode(body) as Map<String, dynamic>;
      _token = j['token'] as String?;
      mode = (j['mode'] as String?) ?? 'insecure';
    } on HandshakeException {
      throw ep.fingerprint.isEmpty
          ? 'TLS certificate not trusted (self-signed? add its fingerprint)'
          : 'TLS fingerprint does not match this rendezvous';
    } on SocketException catch (e) {
      throw 'Cannot reach rendezvous: ${e.message}';
    }
  }

  String get _authHeader =>
      _token != null ? 'Bearer $_token' : ep.authHeader;

  Future<T> _getJson<T>(String path, T Function(dynamic) parse) async {
    final req = await _http.getUrl(ep.base.replace(path: path));
    req.headers.set(HttpHeaders.authorizationHeader, _authHeader);
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
        headers: {HttpHeaders.authorizationHeader: _authHeader},
        customClient: _http);
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
