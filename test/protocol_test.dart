import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_computer/protocol.dart';
import 'package:network_computer/signaling.dart';

void main() {
  test('offer carries pin and pairing token in the Go field names', () {
    final m = SignalMessage(type: 'offer', to: 'box', sdp: 'v=0', pin: '424242', pair: 'abc.def');
    final j = jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>;
    expect(j['pin'], '424242');
    expect(j['pair'], 'abc.def');
  });

  test('answer from the host yields its pairing token', () {
    final m = SignalMessage.fromJson(
        {'type': 'answer', 'from': 'c3', 'sdp': 'v=0', 'pair': 'tok.sig'});
    expect(m.pair, 'tok.sig');
  });

  test('absent fields are omitted, not sent as null', () {
    final j = SignalMessage(type: 'offer', to: 'box', sdp: 'v=0').toJson();
    expect(j.containsKey('pin'), isFalse);
    expect(j.containsKey('pair'), isFalse);
  });

  test('fingerprints normalise from any common format', () {
    const hex = 'ab12cd34';
    expect(normalizeFingerprint('AB:12:CD:34'), hex);
    expect(normalizeFingerprint('sha256 ab12cd34'), hex);
    expect(normalizeFingerprint('  AB12CD34 '), hex);
  });
}
