import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'protocol.dart';

/// The US key that types [ch] on the desk, and whether it needs Shift.
/// The desk keeps a US layout, so any character a US keyboard can type works;
/// anything else (é, emoji) returns null.
(String, bool)? usKey(String ch) {
  if (ch.length != 1) return null;
  final c = ch.codeUnitAt(0);
  if (c >= 97 && c <= 122) return ('Key${ch.toUpperCase()}', false);
  if (c >= 65 && c <= 90) return ('Key$ch', true);
  if (c >= 48 && c <= 57) return ('Digit$ch', false);
  if (ch == '\n') return ('Enter', false);
  if (ch == '\t') return ('Tab', false);
  return _us[ch];
}

const _us = {
  ' ': ('Space', false),
  '!': ('Digit1', true), '@': ('Digit2', true), '#': ('Digit3', true),
  r'$': ('Digit4', true), '%': ('Digit5', true), '^': ('Digit6', true),
  '&': ('Digit7', true), '*': ('Digit8', true), '(': ('Digit9', true),
  ')': ('Digit0', true), '`': ('Backquote', false), '~': ('Backquote', true),
  '-': ('Minus', false), '_': ('Minus', true), '=': ('Equal', false),
  '+': ('Equal', true), '[': ('BracketLeft', false), '{': ('BracketLeft', true),
  ']': ('BracketRight', false), '}': ('BracketRight', true),
  '\\': ('Backslash', false), '|': ('Backslash', true),
  ';': ('Semicolon', false), ':': ('Semicolon', true),
  "'": ('Quote', false), '"': ('Quote', true), ',': ('Comma', false),
  '<': ('Comma', true), '.': ('Period', false), '>': ('Period', true),
  '/': ('Slash', false), '?': ('Slash', true),
  // what a phone keyboard may type instead of the plain ones
  '‘': ('Quote', false), '’': ('Quote', false),
  '“': ('Quote', true), '”': ('Quote', true),
};

/// Typing on a touch device: the device's own keyboard for text, and a bar
/// with the keys it lacks (esc, tab, ctrl, alt, super, arrows, F1–F12).
///
/// The device keyboard types into a hidden field that always holds a few
/// invisible characters, so Backspace has something to delete; every change
/// is turned into key presses on the desk and the field is reset.
///
/// ctrl, alt, super and shift on the bar apply to the next key and then let
/// go (tap ctrl, then c: copy); hold one down on the bar to keep it on.
class SoftKeyboard extends StatefulWidget {
  const SoftKeyboard({super.key, required this.onEvent, this.autofocus = true});
  final void Function(InputEvent) onEvent;
  final bool autofocus;

  @override
  State<SoftKeyboard> createState() => _SoftKeyboardState();
}

class _SoftKeyboardState extends State<SoftKeyboard> {
  static const _sentinel = '\u200B\u200B\u200B\u200B';

  final _focus = FocusNode();
  final _field = TextEditingController(text: _sentinel);
  final Set<String> _mods = {}; // down on the desk, until the next key
  final Set<String> _locked = {}; // down until tapped again
  bool _fn = false;

  @override
  void initState() {
    super.initState();
    _reset();
    HardwareKeyboard.instance.addHandler(_afterHardwareKey);
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_afterHardwareKey);
    for (final m in {..._mods, ..._locked}) {
      widget.onEvent(InputEvent('ku', code: m));
    }
    _focus.dispose();
    _field.dispose();
    super.dispose();
  }

  void _reset() => _field.value = const TextEditingValue(
    text: _sentinel,
    selection: TextSelection.collapsed(offset: _sentinel.length),
  );

  void _changed(String text) {
    // wait while an input method is still composing (dictation, accents)
    final composing = _field.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    final kept = '\u200B'.allMatches(text).length;
    for (var i = kept; i < _sentinel.length; i++) {
      _press('Backspace');
    }
    for (final ch in text.replaceAll('\u200B', '').split('')) {
      final k = usKey(ch);
      if (k != null) _press(k.$1, shift: k.$2);
    }
    _reset();
  }

  void _press(String code, {bool shift = false}) {
    final addShift =
        shift && !_mods.contains('ShiftLeft') && !_locked.contains('ShiftLeft');
    if (addShift) widget.onEvent(InputEvent('kd', code: 'ShiftLeft'));
    widget.onEvent(InputEvent('kd', code: code));
    widget.onEvent(InputEvent('ku', code: code));
    if (addShift) widget.onEvent(InputEvent('ku', code: 'ShiftLeft'));
    if (_mods.isNotEmpty) {
      for (final m in _mods) {
        widget.onEvent(InputEvent('ku', code: m));
      }
      setState(_mods.clear);
    }
  }

  // a key on a real keyboard is "the next key" too: let the bar's one-shot
  // modifiers go once it is up (the session sends the key itself)
  bool _afterHardwareKey(KeyEvent e) {
    if (e is KeyUpEvent &&
        _mods.isNotEmpty &&
        !_modifierKeys.contains(e.logicalKey)) {
      for (final m in _mods) {
        widget.onEvent(InputEvent('ku', code: m));
      }
      setState(_mods.clear);
    }
    return false;
  }

  static final _modifierKeys = {
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.fn,
  };

  void _toggle(String code, {bool lock = false}) {
    setState(() {
      if (_mods.contains(code) || _locked.contains(code)) {
        _mods.remove(code);
        _locked.remove(code);
        widget.onEvent(InputEvent('ku', code: code));
      } else {
        (lock ? _locked : _mods).add(code);
        widget.onEvent(InputEvent('kd', code: code));
      }
    });
  }

  void _showKeyboard() {
    if (_focus.hasFocus) {
      SystemChannels.textInput.invokeMethod('TextInput.show');
    } else {
      _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xCC000000),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // the hidden field the device keyboard types into
          SizedBox(
            height: 1,
            child: Opacity(
              opacity: 0,
              child: TextField(
                key: const Key('soft-keyboard-field'),
                controller: _field,
                focusNode: _focus,
                onChanged: _changed,
                // taps on the desk picture are clicks there: keep typing here
                onTapOutside: (_) {},
                keyboardType:
                    TextInputType.multiline, // Return types a newline: Enter
                maxLines: null,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                smartDashesType: SmartDashesType.disabled,
                smartQuotesType: SmartQuotesType.disabled,
                textCapitalization: TextCapitalization.none,
                showCursor: false,
                enableInteractiveSelection: false,
                decoration: const InputDecoration.collapsed(hintText: null),
              ),
            ),
          ),
          if (_fn)
            _row([
              for (var i = 1; i <= 12; i++) _key('F$i', 'F$i'),
              _key('ins', 'Insert'),
              _key('prt sc', 'PrintScreen'),
            ]),
          _row([
            _button('abc', _showKeyboard, tip: 'show the keyboard'),
            _button('fn', () => setState(() => _fn = !_fn), on: _fn),
            _key('esc', 'Escape'),
            _key('tab', 'Tab'),
            _mod('ctrl', 'ControlLeft'),
            _mod('alt', 'AltLeft'),
            _mod('super', 'MetaLeft'),
            _mod('shift', 'ShiftLeft'),
            _key('←', 'ArrowLeft'),
            _key('↑', 'ArrowUp'),
            _key('↓', 'ArrowDown'),
            _key('→', 'ArrowRight'),
            _key('home', 'Home'),
            _key('end', 'End'),
            _key('pg up', 'PageUp'),
            _key('pg dn', 'PageDown'),
            _key('del', 'Delete'),
          ]),
        ],
      ),
    );
  }

  Widget _row(List<Widget> keys) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(children: keys),
  );

  Widget _key(String label, String code) => _button(label, () => _press(code));

  Widget _mod(String label, String code) => _button(
    label,
    () => _toggle(code),
    onLong: () => _toggle(code, lock: true),
    on: _mods.contains(code) || _locked.contains(code),
    locked: _locked.contains(code),
  );

  Widget _button(
    String label,
    VoidCallback tap, {
    VoidCallback? onLong,
    bool on = false,
    bool locked = false,
    String? tip,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2.5, vertical: 2),
    child: Tooltip(
      message: tip ?? '',
      triggerMode: tip == null
          ? TooltipTriggerMode.manual
          : TooltipTriggerMode.longPress,
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 40),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          backgroundColor: locked
              ? const Color(0xFF2E6BE0)
              : on
              ? const Color(0xFF4C8DFF)
              : const Color(0xE61C2129),
          foregroundColor: Colors.white,
          side: locked
              ? const BorderSide(color: Colors.white, width: 1.5)
              : null,
        ),
        onPressed: tap,
        onLongPress: onLong,
        child: Text(label, style: const TextStyle(fontFamily: 'monospace')),
      ),
    ),
  );
}
