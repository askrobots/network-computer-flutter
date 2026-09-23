import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'signaling.dart';
import 'session_store.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});
  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final url = TextEditingController();
  final user = TextEditingController(text: 'nc');
  final pass = TextEditingController();
  final pin = TextEditingController();
  final fp = TextEditingController();
  String host = '';
  bool relayOnly = false;
  bool paired = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('pin'); // PIN is no longer stored; pairing replaces it
    setState(() {
      url.text = p.getString('url') ?? 'https://';
      user.text = p.getString('user') ?? 'nc';
      pass.text = p.getString('pass') ?? '';
      fp.text = p.getString('fp') ?? '';
      host = p.getString('host') ?? '';
      relayOnly = p.getBool('relay') ?? false;
    });
    // Developer test hook: --dart-define=NC_AUTO_URL=... (and NC_AUTO_PASS,
    // NC_AUTO_HOST, NC_AUTO_PIN) fills the form and connects, so a build can
    // be checked end to end without typing. Values come from the command line
    // at build time; nothing is stored in the source.
    const autoUrl = String.fromEnvironment('NC_AUTO_URL');
    if (autoUrl.isNotEmpty) {
      setState(() {
        url.text = autoUrl;
        pass.text = const String.fromEnvironment('NC_AUTO_PASS');
        pin.text = const String.fromEnvironment('NC_AUTO_PIN');
        const h = String.fromEnvironment('NC_AUTO_HOST');
        if (h.isNotEmpty) host = h;
      });
      await _refresh();
      if (mounted) await _connect();
      return;
    }
    _refresh();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('url', url.text);
    await p.setString('user', user.text);
    await p.setString('pass', pass.text);
    await p.setString('fp', fp.text);
    await p.setString('host', host);
    await p.setBool('relay', relayOnly);
  }

  Endpoint? _endpoint() {
    final u = Uri.tryParse(url.text.trim());
    if (u == null || u.host.isEmpty) return null;
    return Endpoint(u, user.text.trim(), pass.text, fingerprint: fp.text);
  }

  Future<void> _refresh() async {
    final ep = _endpoint();
    if (ep == null) return;
    final store = context.read<SessionStore>();
    await store.refreshHosts(ep);
    if (host.isEmpty && store.hosts.isNotEmpty) setState(() => host = store.hosts.first);
    await _checkPaired();
  }

  Future<void> _checkPaired() async {
    final ep = _endpoint();
    final p = ep != null && host.isNotEmpty && await SessionStore.isPaired(ep, host);
    if (mounted) setState(() => paired = p);
  }

  Future<void> _connect() async {
    final ep = _endpoint();
    if (ep == null) { _snack('Enter a valid rendezvous URL'); return; }
    if (host.isEmpty) { _snack('Pick a host'); return; }
    final store = context.read<SessionStore>();
    await _save();
    await store.connect(ep, host, pin.text.trim(), relayOnly);
  }

  void _snack(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SessionStore>();
    final connecting = store.state == ConnState.connecting;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [
                      Container(
                        width: 40, height: 40,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          gradient: const LinearGradient(
                              colors: [Color(0xFF4C8DFF), Color(0xFF3AD29F)]),
                        ),
                        child: const Icon(Icons.desktop_windows, size: 22),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(child: Text('Network Computer',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
                    ]),
                    const SizedBox(height: 20),
                    _field(url, 'Rendezvous', hint: 'https://host:8765'),
                    Row(children: [
                      Expanded(child: _field(user, 'User')),
                      const SizedBox(width: 10),
                      Expanded(child: _field(pass, 'Password', obscure: true)),
                    ]),
                    const SizedBox(height: 4),
                    Row(children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: store.hosts.contains(host) ? host : null,
                          decoration: const InputDecoration(labelText: 'Host'),
                          items: store.hosts
                              .map((h) => DropdownMenuItem(value: h, child: Text(h)))
                              .toList(),
                          onChanged: (v) { setState(() => host = v ?? ''); _checkPaired(); },
                        ),
                      ),
                      IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
                    ]),
                    _field(pin, paired ? 'Host PIN (paired — not needed)' : 'Host PIN',
                        keyboard: TextInputType.number),
                    _field(fp, 'TLS fingerprint (optional)',
                        hint: 'only for a self-signed secure-mode rendezvous'),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Force TURN relay'),
                      value: relayOnly,
                      onChanged: (v) => setState(() => relayOnly = v),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: connecting ? null : _connect,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: connecting
                            ? Text(store.status)
                            : const Text('Connect'),
                      ),
                    ),
                    if (store.state == ConnState.failed)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(store.status,
                            style: const TextStyle(color: Color(0xFFFF5D5D))),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label,
      {String? hint, bool obscure = false, TextInputType? keyboard}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: c,
        obscureText: obscure,
        keyboardType: keyboard,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(labelText: label, hintText: hint),
      ),
    );
  }
}
