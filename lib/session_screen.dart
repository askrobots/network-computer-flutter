import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import 'protocol.dart';
import 'peer.dart';
import 'session_store.dart';
import 'soft_keyboard.dart';
import 'touch_pad.dart';

/// The live session. Touch as a trackpad by default: drag moves the pointer
/// relatively, tap clicks, two-finger drag scrolls (see touch_pad.dart). The
/// keyboard button brings up the device's keyboard with a bar of the keys it
/// lacks (see soft_keyboard.dart); a hardware keyboard types directly.
class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key});
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  bool showStats = false;
  bool keyboardOpen = false;
  double sensitivity = 2.0;
  int _noticeSeen = 0;

  void _send(InputEvent e) => context.read<SessionStore>().send(e);

  @override
  void initState() {
    super.initState();
    // Hardware keyboards (iPad, Bluetooth, USB, this Mac) are caught here,
    // whatever has focus: tapping the voice button used to take focus from
    // the keyboard's text field, and keys stopped reaching the desk.
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SessionStore>();
    if (store.noticeSeq != _noticeSeen) {
      _noticeSeen = store.noticeSeq;
      final msg = store.notice;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
      });
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        // the key bar sits under the picture, not over it, so nothing on the
        // desk hides behind it; the device's keyboard pushes both up
        child: Column(children: [
          Expanded(
            // expand: with only positioned children a loose Stack collapses
            // to 0x0 and the whole session draws black
            child: Stack(
              fit: StackFit.expand,
              children: [
                // video + trackpad
                Positioned.fill(child: _trackpad(store)),
                // top bar
                _topBar(store),
                if (showStats) _statsCard(store.stats),
                // bottom left: voice panel and button
                Positioned(
                  left: 0, bottom: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (store.voicePanel) _voicePanel(store),
                      _voiceButton(store),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (keyboardOpen) SoftKeyboard(onEvent: _send),
        ]),
      ),
    );
  }

  Widget _trackpad(SessionStore store) => TouchPad(
        videoSize: () => Size(store.renderer.videoWidth.toDouble(), store.renderer.videoHeight.toDouble()),
        onEvent: _send,
        sensitivity: sensitivity,
        child: _video(store),
      );

  Widget _video(SessionStore store) => RTCVideoView(store.renderer,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain);

  Widget _topBar(SessionStore store) {
    final s = store.stats;
    return Positioned(
      top: 8, left: 8, right: 8,
      child: Row(children: [
        _pill(Icon(Icons.circle, size: 10,
            color: s.relayed ? const Color(0xFFFFB454) : const Color(0xFF3AD29F)),
            '${s.relayed ? 'relay' : 'direct'} ${s.rttMs.toStringAsFixed(0)}ms'
                '${store.mode == 'secure' ? '' : ' · insecure'}'),
        const Spacer(),
        _round(store.micOn ? Icons.mic : Icons.mic_off,
            () => context.read<SessionStore>().toggleMic(),
            active: store.micOn),
        _round(Icons.search, () => context.read<SessionStore>().launch()),
        _round(Icons.keyboard, () => setState(() => keyboardOpen = !keyboardOpen)),
        _more(),
        _round(Icons.close, () => context.read<SessionStore>().disconnect()),
      ]),
    );
  }

  /// Less frequent things, so the bar fits a phone.
  Widget _more() => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Material(
          color: const Color(0xCC1C2129),
          shape: const CircleBorder(),
          child: PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz, size: 18),
            onSelected: (v) {
              final store = context.read<SessionStore>();
              switch (v) {
                case 'screen': _screenSheet(); break;
                case 'clipup': store.sendClipboard(); break;
                case 'files': store.sendFiles(); break;
                case 'clipdown': store.getClipboard(); break;
                case 'stats': setState(() => showStats = !showStats); break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'screen', child: ListTile(leading: Icon(Icons.monitor), title: Text('Screen size…'))),
              PopupMenuItem(value: 'files', child: ListTile(leading: Icon(Icons.upload_file), title: Text('Send a photo or file to the desk'))),
              PopupMenuItem(value: 'clipup', child: ListTile(leading: Icon(Icons.upload), title: Text("Send this clipboard to the desk"))),
              PopupMenuItem(value: 'clipdown', child: ListTile(leading: Icon(Icons.download), title: Text("Get the desk's clipboard"))),
              PopupMenuItem(value: 'stats', child: ListTile(leading: Icon(Icons.bar_chart), title: Text('Stats'))),
            ],
          ),
        ),
      );

  /// Screen size for the desk: match this device (or twice as sharp), or a preset.
  void _screenSheet() {
    final store = context.read<SessionStore>();
    final mq = MediaQuery.of(context);
    int r8(double v) => (v / 8).floor() * 8;
    (int, int) fit(double w, double h) {
      final f = [1.0, 2560 / w, 1600 / h].reduce((a, b) => a < b ? a : b);
      return (r8(w * f), r8(h * f));
    }
    final m1 = fit(mq.size.width, mq.size.height);
    final m2 = fit(mq.size.width * mq.devicePixelRatio, mq.size.height * mq.devicePixelRatio);
    final sizes = <(String, int, int)>[
      ('Match this screen (${m1.$1}×${m1.$2})', m1.$1, m1.$2),
      ('Match, sharp (${m2.$1}×${m2.$2}): use a bigger scale', m2.$1, m2.$2),
      ('1280 × 720', 1280, 720), ('1600 × 900', 1600, 900), ('1920 × 1080', 1920, 1080),
    ];
    var scale = store.displayScale;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xF21C2129),
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.all(12), child: Text('Desk screen size')),
          Wrap(spacing: 6, children: [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0].map((v) => ChoiceChip(
                label: Text('${(v * 100).round()}%'),
                selected: scale == v,
                onSelected: (_) => set(() => scale = v),
              )).toList()),
          ...sizes.map((sz) => ListTile(
                title: Text(sz.$1),
                selected: store.displayW == sz.$2 && store.displayH == sz.$3,
                onTap: () { Navigator.pop(ctx); store.setDisplay(sz.$2, sz.$3, scale); },
              )),
        ]),
      )),
    );
  }

  Widget _voiceButton(SessionStore store) => Padding(
        padding: const EdgeInsets.all(12),
        child: Material(
          color: store.voiceOn ? const Color(0xFFD33333) : const Color(0xE61C2129),
          shape: const CircleBorder(),
          elevation: 4,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => context.read<SessionStore>().toggleVoice(),
            child: const SizedBox(width: 56, height: 56, child: Icon(Icons.record_voice_over, size: 26)),
          ),
        ),
      );

  Widget _voicePanel(SessionStore store) => Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Container(
          width: MediaQuery.of(context).size.width.clamp(0, 440) - 24,
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.4),
          decoration: BoxDecoration(
            color: const Color(0xE6121620),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
              child: Row(children: [
                Text(store.voiceState, style: const TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                const Text('keep listening', style: TextStyle(fontSize: 12, color: Color(0xFFAABBCC))),
                Switch(value: store.keepListening,
                    onChanged: (v) => context.read<SessionStore>().setKeepListening(v)),
                IconButton(icon: const Icon(Icons.close, size: 18),
                    onPressed: () => context.read<SessionStore>().hideVoicePanel()),
              ]),
            ),
            Flexible(child: ListView(
              shrinkWrap: true,
              reverse: true,   // newest at the bottom, scrolled into view
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              children: store.voiceLines.reversed.map(_voiceLine).toList(),
            )),
          ]),
        ),
      );

  Widget _voiceLine((String, String) l) {
    final (kind, text) = l;
    final (prefix, color) = switch (kind) {
      'heard' => ('You: ', Colors.white),
      'said' => ('Desk: ', const Color(0xFFBFE0FF)),
      'did' => ('✓ ', const Color(0xFF99DD99)),
      _ => ('⚠ ', const Color(0xFFFFBB88)),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Text('$prefix$text', style: TextStyle(color: color, fontSize: 14)),
    );
  }

  Widget _pill(Widget leading, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xCC1C2129),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          leading, const SizedBox(width: 7),
          Text(text, style: const TextStyle(fontSize: 12.5)),
        ]),
      );

  Widget _round(IconData icon, VoidCallback onTap, {bool active = false}) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Material(
          color: active ? const Color(0xFFFF5D5D) : const Color(0xCC1C2129),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: 40, height: 40, child: Icon(icon, size: 18)),
          ),
        ),
      );

  Widget _statsCard(PeerStats s) => Positioned(
        top: 56, left: 12,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xCC12151A),
            borderRadius: BorderRadius.circular(10),
          ),
          child: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFF9AA4B2)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${s.width}×${s.height}  ${s.fps.toStringAsFixed(0)} fps'),
              Text('${s.mbps.toStringAsFixed(1)} Mb/s  ${s.codec}'),
              Text('${s.path}  ${s.rttMs.toStringAsFixed(0)} ms'),
              Text('lost ${s.lost}  jitter ${s.jitterMs.toStringAsFixed(1)} ms'),
            ]),
          ),
        ),
      );

  final Map<LogicalKeyboardKey, String> _downAs = {};   // so each keyup matches its keydown

  bool _onHardwareKey(KeyEvent e) {
    if (!mounted) return false;
    if (e is KeyRepeatEvent) return true;
    if (e is KeyUpEvent) {
      final code = _downAs.remove(e.logicalKey);
      if (code != null) _send(InputEvent('ku', code: code));
      return code != null;
    }
    final code = _mapKey(e);
    if (code == null) return false;
    _downAs[e.logicalKey] = code;
    _send(InputEvent('kd', code: code));
    return true;
  }

  // Characters go as the US key that types them (the desk stays US), so any
  // layout works; the rest by name. Cmd acts as Ctrl on the desk.
  static const _usCode = {
    '!': 'Digit1', '@': 'Digit2', '#': 'Digit3', r'$': 'Digit4', '%': 'Digit5', '^': 'Digit6',
    '&': 'Digit7', '*': 'Digit8', '(': 'Digit9', ')': 'Digit0', '`': 'Backquote', '~': 'Backquote',
    '-': 'Minus', '_': 'Minus', '=': 'Equal', '+': 'Equal', '[': 'BracketLeft', '{': 'BracketLeft',
    ']': 'BracketRight', '}': 'BracketRight', '\\': 'Backslash', '|': 'Backslash', ';': 'Semicolon',
    ':': 'Semicolon', "'": 'Quote', '"': 'Quote', ',': 'Comma', '<': 'Comma', '.': 'Period',
    '>': 'Period', '/': 'Slash', '?': 'Slash', ' ': 'Space',
  };
  static final _named = {
    LogicalKeyboardKey.enter: 'Enter', LogicalKeyboardKey.numpadEnter: 'Enter',
    LogicalKeyboardKey.backspace: 'Backspace', LogicalKeyboardKey.delete: 'Delete',
    LogicalKeyboardKey.tab: 'Tab', LogicalKeyboardKey.escape: 'Escape', LogicalKeyboardKey.space: 'Space',
    LogicalKeyboardKey.arrowUp: 'ArrowUp', LogicalKeyboardKey.arrowDown: 'ArrowDown',
    LogicalKeyboardKey.arrowLeft: 'ArrowLeft', LogicalKeyboardKey.arrowRight: 'ArrowRight',
    LogicalKeyboardKey.home: 'Home', LogicalKeyboardKey.end: 'End',
    LogicalKeyboardKey.pageUp: 'PageUp', LogicalKeyboardKey.pageDown: 'PageDown',
    LogicalKeyboardKey.shiftLeft: 'ShiftLeft', LogicalKeyboardKey.shiftRight: 'ShiftRight',
    LogicalKeyboardKey.controlLeft: 'ControlLeft', LogicalKeyboardKey.controlRight: 'ControlRight',
    LogicalKeyboardKey.altLeft: 'AltLeft', LogicalKeyboardKey.altRight: 'AltRight',
    LogicalKeyboardKey.metaLeft: 'ControlLeft', LogicalKeyboardKey.metaRight: 'ControlRight',
    LogicalKeyboardKey.capsLock: 'CapsLock',
    LogicalKeyboardKey.f1: 'F1', LogicalKeyboardKey.f2: 'F2', LogicalKeyboardKey.f3: 'F3',
    LogicalKeyboardKey.f4: 'F4', LogicalKeyboardKey.f5: 'F5', LogicalKeyboardKey.f6: 'F6',
    LogicalKeyboardKey.f7: 'F7', LogicalKeyboardKey.f8: 'F8', LogicalKeyboardKey.f9: 'F9',
    LogicalKeyboardKey.f10: 'F10', LogicalKeyboardKey.f11: 'F11', LogicalKeyboardKey.f12: 'F12',
  };

  String? _mapKey(KeyEvent e) {
    final named = _named[e.logicalKey];
    if (named != null) return named;
    var ch = e.character;
    if (ch == null || ch.isEmpty || ch.codeUnitAt(0) < 32) {   // with Ctrl held: a control code
      final l = e.logicalKey.keyLabel;
      ch = l.length == 1 ? l.toLowerCase() : null;
    }
    if (ch == null || ch.length != 1) return null;
    final c = ch.toUpperCase().codeUnitAt(0);
    if (c >= 65 && c <= 90) return 'Key${ch.toUpperCase()}';
    if (c >= 48 && c <= 57) return 'Digit$ch';
    return _usCode[ch];
  }
}
