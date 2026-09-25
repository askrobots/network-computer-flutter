import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_computer/protocol.dart';
import 'package:network_computer/touch_pad.dart';

// A 1024x768 view (a 4:3 iPad) showing a 1280x720 desk: the picture is
// 1024x576 with 96 px bars above and below.
Future<List<String>> run(
  WidgetTester t,
  Future<void> Function() gesture,
) async {
  final events = <String>[];
  await t.binding.setSurfaceSize(const Size(1024, 768));
  await t.pumpWidget(
    MaterialApp(
      home: TouchPad(
        videoSize: () => const Size(1280, 720),
        onEvent: (InputEvent e) {
          final j = e.toJson();
          final t = j['t'];
          if (t == 'mm') {
            events.add(
              'mm ${(j['x'] as double).toStringAsFixed(2)},${(j['y'] as double).toStringAsFixed(2)}',
            );
          } else if (t == 'md' || t == 'mu') {
            events.add('$t ${j['b'] ?? 0}');
          } else {
            events.add('$t');
          }
        },
        child: const SizedBox.expand(),
      ),
    ),
  );
  await gesture();
  await t.pumpAndSettle(const Duration(seconds: 1));
  return events;
}

// the middle of the picture, and a quarter of the way down it
const mid = Offset(512, 96 + 288), quarter = Offset(512, 96 + 144);

void main() {
  testWidgets(
    'tap: left click where the finger is (measured on the picture, not the bars)',
    (t) async {
      final e = await run(t, () async {
        await t.tapAt(quarter);
      });
      expect(e, ['mm 0.50,0.25', 'md 0', 'mu 0']);
    },
  );

  testWidgets('double tap: a double click', (t) async {
    final e = await run(t, () async {
      await t.tapAt(mid);
      await t.pump(const Duration(milliseconds: 80));
      await t.tapAt(mid);
    });
    expect(e, ['mm 0.50,0.50', 'md 0', 'mu 0', 'md 0', 'mu 0']);
  });

  testWidgets('touch and hold, let go: right click', (t) async {
    final e = await run(t, () async {
      await t.longPressAt(mid);
    });
    expect(e, ['mm 0.50,0.50', 'md 2', 'mu 2']);
  });

  testWidgets('touch and hold, then move: a drag', (t) async {
    final e = await run(t, () async {
      final g = await t.startGesture(quarter);
      await t.pump(const Duration(milliseconds: 700));
      await g.moveBy(const Offset(0, 144));
      await t.pump();
      await g.up();
    });
    expect(e.first, 'mm 0.50,0.25');
    expect(e[1], 'md 0');
    expect(e.contains('mm 0.50,0.50'), isTrue);
    expect(e.last, 'mu 0');
  });

  testWidgets('two-finger tap: right click', (t) async {
    final e = await run(t, () async {
      final a = await t.startGesture(mid - const Offset(20, 0), pointer: 1);
      final b = await t.startGesture(mid + const Offset(20, 0), pointer: 2);
      await t.pump(const Duration(milliseconds: 50));
      await a.up();
      await b.up();
    });
    expect(e.where((x) => x.startsWith('md') || x.startsWith('mu')).toList(), [
      'md 2',
      'mu 2',
    ]);
  });

  testWidgets('two-finger drag: scroll, and no clicks', (t) async {
    final e = await run(t, () async {
      final a = await t.startGesture(mid - const Offset(20, 0), pointer: 1);
      final b = await t.startGesture(mid + const Offset(20, 0), pointer: 2);
      for (var i = 0; i < 5; i++) {
        await a.moveBy(const Offset(0, -20));
        await b.moveBy(const Offset(0, -20));
        await t.pump(const Duration(milliseconds: 16));
      }
      await a.up();
      await b.up();
    });
    expect(e.contains('wh'), isTrue);
    expect(e.any((x) => x.startsWith('md')), isFalse);
  });

  testWidgets('one-finger drag: moves the pointer, no clicks', (t) async {
    final e = await run(t, () async {
      await t.dragFrom(mid, const Offset(100, 0));
    });
    expect(e.contains('mr'), isTrue);
    expect(e.any((x) => x.startsWith('md')), isFalse);
  });

  testWidgets('a mouse right button: right click', (t) async {
    final e = await run(t, () async {
      await t.tapAt(
        mid,
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
    });
    expect(e, ['mm 0.50,0.50', 'md 2', 'mu 2']);
  });

  testWidgets('a mouse click after a two-finger tap still clicks', (t) async {
    final e = await run(t, () async {
      final a = await t.startGesture(mid, pointer: 1);
      final b = await t.startGesture(mid + const Offset(40, 0), pointer: 2);
      await a.up();
      await b.up();
      await t.pump(const Duration(milliseconds: 500));
      await t.tapAt(mid, kind: PointerDeviceKind.mouse);
      await t.pump(const Duration(milliseconds: 500));
    });
    expect(e.where((x) => x == 'md 0').length, 1);
  });
}
