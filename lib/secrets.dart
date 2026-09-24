import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Credentials (the rendezvous password, pairing tokens) live in the
/// platform keychain, not in plain app preferences. Values saved by older
/// versions in preferences are moved there on first read. If the keychain
/// can't be used, preferences stay in use: a credential is never lost.
class Secrets {
  static const _store = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
    // the login keychain: the data-protection one needs a signed entitlement
    mOptions: MacOsOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
        usesDataProtectionKeychain: false),
  );

  static Future<String?> read(String key) async {
    final p = await SharedPreferences.getInstance();
    try {
      final v = await _store.read(key: key);
      if (v != null) return v;
      final old = p.getString(key);
      if (old != null) {   // migrate from plain preferences
        await _store.write(key: key, value: old);
        if (await _store.read(key: key) == old) await p.remove(key);
      }
      return old;
    } catch (e) {
      debugPrint('nc secrets: keychain unavailable ($e); using preferences');
      return p.getString(key);
    }
  }

  static Future<void> write(String key, String value) async {
    try {
      await _store.write(key: key, value: value);
      (await SharedPreferences.getInstance()).remove(key);
    } catch (e) {
      debugPrint('nc secrets: keychain unavailable ($e); using preferences');
      await (await SharedPreferences.getInstance()).setString(key, value);
    }
  }

  static Future<void> delete(String key) async {
    try {
      await _store.delete(key: key);
    } catch (_) {}
    (await SharedPreferences.getInstance()).remove(key);
  }
}
