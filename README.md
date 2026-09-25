# network-computer (Flutter client)

One client for [network-computer](https://github.com/askrobots/network-computer),
across **Android, iPhone, iPad, and macOS / Windows / Linux desktop** from a single
Dart codebase. See and drive a remote Linux or Mac desktop over WebRTC, with the
phone or tablet as trackpad and keyboard.

Status: first cut. Connects through `nc-rendezvous` with the same signaling and
Basic-auth + host-PIN as the browser and (former) native clients, renders video in
hardware via `flutter_webrtc`, sends touch, keyboard and modifier-bar input, and
shows live stats. This supersedes the native Swift iOS app: one codebase for every
device.

## Build

Needs the Flutter SDK (3.35+). Then per target:

```sh
flutter pub get
flutter run                 # a connected device or desktop
flutter build apk           # Android (needs the Android SDK / Android Studio)
flutter build ipa           # iOS / iPad (needs Xcode + CocoaPods)
flutter build macos         # macOS desktop (needs CocoaPods)
```

The Android SDK, Xcode and CocoaPods are the usual Flutter platform prerequisites;
`flutter doctor` lists what is missing.

## Use

1. Run `nc-rendezvous` and `nc-host` from the Go repo.
2. Enter the rendezvous URL, user, password, pick the host, enter its PIN.
3. Connect. On a touch screen:

   | Gesture | On the desk |
   |---|---|
   | Tap | Left click |
   | Double tap | Double click |
   | Touch and hold, let go | Right click |
   | Two-finger tap | Right click |
   | Touch and hold, then move | Drag |
   | One-finger drag | Move the pointer (trackpad) |
   | Two-finger drag | Scroll |

   The keyboard button brings up the device's keyboard plus a bar with esc, tab,
   ctrl, alt, super, shift, arrows, home/end, page up/down, delete and fn (F1–F12).
   Modifiers apply to the next key; hold one to lock it. A mouse, trackpad or
   hardware keyboard (iPad Magic Keyboard, USB) works as usual.

## Layout

```
lib/protocol.dart        signaling + input event models (mirror internal/proto)
lib/signaling.dart       rendezvous WebSocket + /config,/hosts, Basic auth
lib/peer.dart            flutter_webrtc peer: video/audio in, input + stats
lib/session_store.dart   connection state, auto-reconnect
lib/connect_screen.dart  connection UI (remembers settings)
lib/session_screen.dart  video, top bar, voice, stats
lib/touch_pad.dart       touch gestures → clicks, drags, scroll
lib/soft_keyboard.dart   device keyboard → desk keys, plus the key bar
```

## License

MIT.
