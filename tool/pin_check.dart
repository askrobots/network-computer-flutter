// Exercises the client's TLS pinning against a live secure-mode rendezvous.
//   dart run tool/pin_check.dart <https-url> <password> <fingerprint>
import 'dart:io';
import 'package:network_computer/signaling.dart';

Future<String> attempt(String label, Endpoint ep) async {
  try {
    final c = SignalingClient(ep);
    await c.authenticate();
    final hosts = await c.fetchHosts();
    await c.connect(); // WebSocket over the same pinned client
    c.close();
    return '$label: OK (mode=${c.mode}, hosts=$hosts, websocket connected)';
  } catch (e) {
    return '$label: refused -> $e';
  }
}

Future<void> main(List<String> a) async {
  final base = Uri.parse(a[0]);
  final pw = a[1], fp = a[2];
  final wrong = '00${fp.substring(2)}';
  final colons = [for (var i = 0; i < fp.length; i += 2) fp.substring(i, i + 2)].join(':').toUpperCase();
  print(await attempt('correct pin      ', Endpoint(base, 'nc', pw, fingerprint: fp)));
  print(await attempt('pin as AB:CD:..  ', Endpoint(base, 'nc', pw, fingerprint: 'SHA256 $colons')));
  print(await attempt('wrong pin        ', Endpoint(base, 'nc', pw, fingerprint: wrong)));
  print(await attempt('no pin           ', Endpoint(base, 'nc', pw)));
  print(await attempt('bad password     ', Endpoint(base, 'nc', 'nope', fingerprint: fp)));
  exit(0);
}
