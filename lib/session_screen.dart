import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import 'protocol.dart';
import 'peer.dart';
import 'session_store.dart';

/// The live session. Touch as a trackpad by default: drag moves the pointer
/// relatively, tap clicks, two-finger drag scrolls. A keyboard sheet and a
/// modifier bar cover keys a soft keyboard lacks.
class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key});
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  bool showStats = false;
  bool keyboardOpen = false;
  double sensitivity = 2.0;
  final _focus = FocusNode();
  final _hidden = TextEditingController();
  final Set<String> _sticky = {};

  void _send(InputEvent e) => context.read<SessionStore>().send(e);

  @override
  void dispose() { _focus.dispose(); _hidden.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SessionStore>();
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // video + trackpad
            Positioned.fill(child: _trackpad(store)),
            // hidden text field feeding key events
            Offstage(
              offstage: true,
              child: KeyboardListener(
                focusNode: _focus,
                onKeyEvent: _onKey,
                child: TextField(controller: _hidden),
              ),
            ),
            // top bar
            _topBar(store),
            if (showStats) _statsCard(store.stats),
            if (keyboardOpen) Align(alignment: Alignment.bottomCenter, child: _modBar()),
          ],
        ),
      ),
    );
  }

  Widget _trackpad(SessionStore store) {
    return LayoutBuilder(builder: (context, box) {
      Offset toNorm(Offset p) => Offset(
          (p.dx / box.maxWidth).clamp(0.0, 1.0),
          (p.dy / box.maxHeight).clamp(0.0, 1.0));
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) {
          final n = toNorm(d.localPosition);
          _send(InputEvent('mm', x: n.dx, y: n.dy));
        },
        onTap: () { _send(InputEvent('md', b: 0)); _send(InputEvent('mu', b: 0)); },
        onPanUpdate: (d) {
          _send(InputEvent('mr',
              dx: d.delta.dx * sensitivity, dy: d.delta.dy * sensitivity));
        },
        onLongPressStart: (d) => _send(InputEvent('md', b: 0)),
        onLongPressEnd: (d) => _send(InputEvent('mu', b: 0)),
        onSecondaryTap: () { _send(InputEvent('md', b: 2)); _send(InputEvent('mu', b: 2)); },
        child: RTCVideoView(store.renderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain),
      );
    });
  }

  Widget _topBar(SessionStore store) {
    final s = store.stats;
    return Positioned(
      top: 8, left: 8, right: 8,
      child: Row(children: [
        _pill(Icon(Icons.circle, size: 10,
            color: s.relayed ? const Color(0xFFFFB454) : const Color(0xFF3AD29F)),
            s.relayed ? 'relay ${s.rttMs.toStringAsFixed(0)}ms'
                       : 'direct ${s.rttMs.toStringAsFixed(0)}ms'),
        const Spacer(),
        _round(Icons.bar_chart, () => setState(() => showStats = !showStats)),
        _round(Icons.keyboard, () {
          setState(() => keyboardOpen = !keyboardOpen);
          if (keyboardOpen) { _focus.requestFocus(); } else { _focus.unfocus(); }
        }),
        _round(Icons.close, () => context.read<SessionStore>().disconnect()),
      ]),
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

  Widget _round(IconData icon, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Material(
          color: const Color(0xCC1C2129),
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

  static const _mods = [
    ('esc', 'Escape', false), ('ctrl', 'ControlLeft', true),
    ('alt', 'AltLeft', true), ('cmd', 'MetaLeft', true),
    ('tab', 'Tab', false), ('↑', 'ArrowUp', false), ('↓', 'ArrowDown', false),
    ('←', 'ArrowLeft', false), ('→', 'ArrowRight', false), ('del', 'Delete', false),
  ];

  Widget _modBar() => Container(
        color: const Color(0xCC000000),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: _mods.map((m) {
            final on = _sticky.contains(m.$2);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: TextButton(
                style: TextButton.styleFrom(
                  backgroundColor: on ? const Color(0xFF4C8DFF) : const Color(0xE61C2129),
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  if (m.$3) {
                    setState(() {
                      if (on) { _sticky.remove(m.$2); _send(InputEvent('ku', code: m.$2)); }
                      else { _sticky.add(m.$2); _send(InputEvent('kd', code: m.$2)); }
                    });
                  } else {
                    _send(InputEvent('kd', code: m.$2));
                    _send(InputEvent('ku', code: m.$2));
                  }
                },
                child: Text(m.$1, style: const TextStyle(fontFamily: 'monospace')),
              ),
            );
          }).toList()),
        ),
      );

  void _onKey(KeyEvent e) {
    if (e is KeyRepeatEvent) return;
    final code = _mapKey(e.logicalKey);
    if (code == null) return;
    _send(InputEvent(e is KeyDownEvent ? 'kd' : 'ku', code: code));
  }

  String? _mapKey(LogicalKeyboardKey k) {
    final label = k.keyLabel;
    if (label.length == 1) {
      final c = label.toUpperCase().codeUnitAt(0);
      if (c >= 65 && c <= 90) return 'Key\${label.toUpperCase()}';
      if (c >= 48 && c <= 57) return 'Digit\$label';
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) return 'Enter';
    if (k == LogicalKeyboardKey.space) return 'Space';
    if (k == LogicalKeyboardKey.backspace) return 'Backspace';
    if (k == LogicalKeyboardKey.tab) return 'Tab';
    if (k == LogicalKeyboardKey.escape) return 'Escape';
    if (k == LogicalKeyboardKey.arrowUp) return 'ArrowUp';
    if (k == LogicalKeyboardKey.arrowDown) return 'ArrowDown';
    if (k == LogicalKeyboardKey.arrowLeft) return 'ArrowLeft';
    if (k == LogicalKeyboardKey.arrowRight) return 'ArrowRight';
    if (k == LogicalKeyboardKey.period) return 'Period';
    if (k == LogicalKeyboardKey.comma) return 'Comma';
    if (k == LogicalKeyboardKey.slash) return 'Slash';
    if (k == LogicalKeyboardKey.minus) return 'Minus';
    return null;
  }
}
