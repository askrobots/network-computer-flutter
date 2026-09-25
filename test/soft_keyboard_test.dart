import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_computer/protocol.dart';
import 'package:network_computer/soft_keyboard.dart';

const z = '\u200B\u200B\u200B\u200B'; // what the hidden field holds between keys

Future<List<String>> run(WidgetTester t, Future<void> Function() act) async {
  final got = <String>[];
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SoftKeyboard(
            onEvent: (InputEvent e) => got.add('${e.t} ${e.code}'),
          ),
        ),
      ),
    ),
  );
  await t.pump();
  await act();
  await t.pump();
  return got;
}

final field = find.byKey(const Key('soft-keyboard-field'));

void main() {
  test('US keys for characters', () {
    expect(usKey('a'), ('KeyA', false));
    expect(usKey('A'), ('KeyA', true));
    expect(usKey('7'), ('Digit7', false));
    expect(usKey('&'), ('Digit7', true));
    expect(usKey('?'), ('Slash', true));
    expect(usKey('’'), ('Quote', false));
    expect(usKey('\n'), ('Enter', false));
    expect(usKey('é'), null);
  });

  testWidgets('the device keyboard comes up by itself', (t) async {
    await run(t, () async {});
    expect(t.testTextInput.isVisible, true);
  });

  testWidgets('typing: letters, capitals with shift, space', (t) async {
    final e = await run(t, () => t.enterText(field, '${z}Hi a'));
    expect(e, [
      'kd ShiftLeft',
      'kd KeyH',
      'ku KeyH',
      'ku ShiftLeft',
      'kd KeyI',
      'ku KeyI',
      'kd Space',
      'ku Space',
      'kd KeyA',
      'ku KeyA',
    ]);
  });

  testWidgets('each key on its own, as a keyboard types them', (t) async {
    final e = await run(t, () async {
      await t.enterText(field, '${z}o');
      await t.enterText(field, '${z}k');
    });
    expect(e, ['kd KeyO', 'ku KeyO', 'kd KeyK', 'ku KeyK']);
  });

  testWidgets('backspace, and return is Enter', (t) async {
    final e = await run(t, () async {
      await t.enterText(field, z.substring(1));
      await t.enterText(field, '$z\n');
    });
    expect(e, ['kd Backspace', 'ku Backspace', 'kd Enter', 'ku Enter']);
  });

  testWidgets('ctrl on the bar applies to the next key, then lets go', (
    t,
  ) async {
    final e = await run(t, () async {
      await t.tap(find.text('ctrl'));
      await t.pump();
      await t.enterText(field, '${z}c');
      await t.enterText(field, '${z}v');
    });
    expect(e, [
      'kd ControlLeft',
      'kd KeyC',
      'ku KeyC',
      'ku ControlLeft',
      'kd KeyV',
      'ku KeyV',
    ]);
  });

  testWidgets('holding ctrl keeps it on until tapped again', (t) async {
    final e = await run(t, () async {
      await t.longPress(find.text('ctrl'));
      await t.pump();
      await t.enterText(field, '${z}a');
      await t.enterText(field, '${z}c');
      await t.tap(find.text('ctrl'));
    });
    expect(e, [
      'kd ControlLeft',
      'kd KeyA',
      'ku KeyA',
      'kd KeyC',
      'ku KeyC',
      'ku ControlLeft',
    ]);
  });

  testWidgets('keys on the bar: esc, arrows, and F keys behind fn', (t) async {
    final e = await run(t, () async {
      await t.tap(find.text('esc'));
      await t.tap(find.text('↑'));
      expect(find.text('F5'), findsNothing);
      await t.tap(find.text('fn'));
      await t.pump();
      await t.tap(find.text('F5'));
    });
    expect(e, [
      'kd Escape',
      'ku Escape',
      'kd ArrowUp',
      'ku ArrowUp',
      'kd F5',
      'ku F5',
    ]);
  });

  testWidgets('ctrl on the bar also lets go after a key on a real keyboard', (
    t,
  ) async {
    final e = await run(t, () async {
      await t.tap(find.text('ctrl'));
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.keyA);
    });
    expect(e, ['kd ControlLeft', 'ku ControlLeft']);
  });
}
