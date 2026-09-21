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
3. Connect. Drag = move pointer (trackpad), tap = click, long-press = drag,
   two-finger = right-click. The keyboard button opens a soft keyboard plus a
   modifier bar (esc, ctrl, alt, cmd, arrows) with sticky modifiers. A hardware
   keyboard (iPad Magic Keyboard, USB) is captured too.

## Layout

```
lib/protocol.dart        signaling + input event models (mirror internal/proto)
lib/signaling.dart       rendezvous WebSocket + /config,/hosts, Basic auth
lib/peer.dart            flutter_webrtc peer: video/audio in, input + stats
lib/session_store.dart   connection state, auto-reconnect
lib/connect_screen.dart  connection UI (remembers settings)
lib/session_screen.dart  video + trackpad + keyboard + stats
```

## License

MIT.
