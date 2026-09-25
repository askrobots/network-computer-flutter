import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'protocol.dart';

/// Touch on the desk's picture, the usual way for a remote desktop on a
/// tablet or phone:
///
///   tap                      left click where the finger is
///   double tap               double click there
///   touch and hold, let go   right click there (context menus)
///   two-finger tap           right click too
///   touch and hold, move     drag (windows, text selection)
///   one-finger drag          move the pointer, like a trackpad
///   two-finger drag          scroll
///
/// A mouse or trackpad on the device (iPad, Mac) right-clicks as usual.
/// Positions are measured against the picture, which is fitted inside the
/// view ("contain"), not against the view: with bars around it, a touch would
/// otherwise land off target.
class TouchPad extends StatefulWidget {
  const TouchPad({
    super.key,
    required this.child,
    required this.videoSize,
    required this.onEvent,
    this.sensitivity = 2.0,
  });

  final Widget child;
  final Size Function()
  videoSize; // the desk picture's size in pixels (0x0 until known)
  final void Function(InputEvent) onEvent;
  final double sensitivity;

  @override
  State<TouchPad> createState() => _TouchPadState();
}

class _TouchPadState extends State<TouchPad> {
  Size _box = Size.zero;
  Offset _down = Offset.zero; // where the latest tap or hold began
  bool _dragging = false; // touch-and-hold turned into a drag
  int _fingers = 0; // fingers in the current scale gesture
  // fingers down right now, counted directly: a second finger turns a tap
  // into a two-finger gesture (the tap recognizer alone would still click)
  final Map<int, Offset> _touches = {};
  int _mostTouches = 0;
  double _touchMoved = 0;
  DateTime _firstTouch = DateTime.now();
  Offset _lastTwoFingerSpot = Offset.zero; // the first of two fingers to lift

  void _send(InputEvent e) => widget.onEvent(e);

  Offset _norm(Offset p) {
    final v = widget.videoSize();
    final bw = _box.width, bh = _box.height;
    if (bw <= 0 || bh <= 0) return Offset.zero;
    if (v.width <= 0 || v.height <= 0) {
      return Offset((p.dx / bw).clamp(0.0, 1.0), (p.dy / bh).clamp(0.0, 1.0));
    }
    final k = (bw / v.width) < (bh / v.height) ? bw / v.width : bh / v.height;
    final w = v.width * k, h = v.height * k;
    final left = (bw - w) / 2, top = (bh - h) / 2;
    return Offset(
      ((p.dx - left) / w).clamp(0.0, 1.0),
      ((p.dy - top) / h).clamp(0.0, 1.0),
    );
  }

  void _moveTo(Offset p) {
    final n = _norm(p);
    _send(InputEvent('mm', x: n.dx, y: n.dy));
  }

  void _click(int button, {int times = 1}) {
    for (var i = 0; i < times; i++) {
      _send(InputEvent('md', b: button));
      _send(InputEvent('mu', b: button));
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        _box = Size(box.maxWidth, box.maxHeight);
        return Listener(
          onPointerDown: (e) {
            if (e.kind != PointerDeviceKind.touch) {
              _mostTouches = 0; // a mouse click is never part of a finger tap
              return;
            }
            if (_touches.isEmpty) {
              _mostTouches = 0;
              _touchMoved = 0;
              _firstTouch = DateTime.now();
            }
            _touches[e.pointer] = e.localPosition;
            if (_touches.length > _mostTouches) _mostTouches = _touches.length;
          },
          onPointerMove: (e) {
            final was = _touches[e.pointer];
            if (was == null) return;
            _touchMoved += (e.localPosition - was).distance;
            _touches[e.pointer] = e.localPosition;
          },
          onPointerUp: (e) => _touchUp(e.pointer),
          onPointerCancel: (e) => _touchUp(e.pointer),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // tap and double tap
            onTapDown: (d) => _down = d.localPosition,
            onTap: () {
              if (_mostTouches < 2) {
                _moveTo(_down);
                _click(0);
              }
            },
            onDoubleTapDown: (d) => _down = d.localPosition,
            onDoubleTap: () {
              if (_mostTouches < 2) {
                _moveTo(_down);
                _click(0, times: 2);
              }
            },
            // touch and hold: right click, or a drag if the finger moves
            onLongPressStart: (d) {
              _down = d.localPosition;
              _dragging = false;
              _moveTo(_down);
            },
            onLongPressMoveUpdate: (d) {
              if (!_dragging) {
                _dragging = true;
                _send(InputEvent('md', b: 0));
              }
              _moveTo(d.localPosition);
            },
            onLongPressEnd: (d) {
              if (_dragging) {
                _send(InputEvent('mu', b: 0));
              } else {
                _click(2);
              }
              _dragging = false;
            },
            // one finger moves the pointer; two fingers scroll, or right click on a tap
            onScaleStart: (d) => _fingers = d.pointerCount,
            onScaleUpdate: (d) {
              if (d.pointerCount > _fingers) _fingers = d.pointerCount;
              if (d.pointerCount >= 2) {
                final dy = -d.focalPointDelta.dy * 3,
                    dx = -d.focalPointDelta.dx * 3;
                if (dx != 0 || dy != 0) _send(InputEvent('wh', dx: dx, dy: dy));
              } else if (_fingers == 1) {
                _send(
                  InputEvent(
                    'mr',
                    dx: d.focalPointDelta.dx * widget.sensitivity,
                    dy: d.focalPointDelta.dy * widget.sensitivity,
                  ),
                );
              }
            },
            onScaleEnd: (d) => _fingers = 0,
            // a mouse or trackpad's own right button
            onSecondaryTapDown: (d) => _down = d.localPosition,
            onSecondaryTap: () {
              _moveTo(_down);
              _click(2);
            },
            child: widget.child,
          ),
        );
      },
    );
  }

  // all fingers up: two fingers that neither moved nor lingered were a tap
  void _touchUp(int pointer) {
    final at = _touches.remove(pointer);
    if (at == null || _touches.isNotEmpty) {
      if (at != null) _lastTwoFingerSpot = at;
      return;
    }
    final quick =
        DateTime.now().difference(_firstTouch) <
        const Duration(milliseconds: 400);
    if (_mostTouches == 2 && _touchMoved < 12 && quick) {
      _moveTo(
        Offset(
          (at.dx + _lastTwoFingerSpot.dx) / 2,
          (at.dy + _lastTwoFingerSpot.dy) / 2,
        ),
      );
      _click(2);
    }
  }
}
