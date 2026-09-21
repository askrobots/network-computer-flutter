// Mirrors internal/proto/proto.go in the Go repo: signaling messages and input events.

class SignalMessage {
  String type;
  String? name, to, from, sdp, pin, error;
  Map<String, dynamic>? candidate; // RTCIceCandidateInit shape
  List<String>? hosts;

  SignalMessage({
    required this.type,
    this.name,
    this.to,
    this.from,
    this.sdp,
    this.pin,
    this.error,
    this.candidate,
    this.hosts,
  });

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{'type': type};
    if (name != null) m['name'] = name;
    if (to != null) m['to'] = to;
    if (sdp != null) m['sdp'] = sdp;
    if (pin != null) m['pin'] = pin;
    if (candidate != null) m['candidate'] = candidate;
    return m;
  }

  factory SignalMessage.fromJson(Map<String, dynamic> j) => SignalMessage(
        type: j['type'] ?? '',
        name: j['name'],
        to: j['to'],
        from: j['from'],
        sdp: j['sdp'],
        pin: j['pin'],
        error: j['error'],
        candidate: (j['candidate'] as Map?)?.cast<String, dynamic>(),
        hosts: (j['hosts'] as List?)?.cast<String>(),
      );
}

/// One message on the "input" data channel. Same JSON the browser client sends.
/// t: mm (absolute), mr (relative), md/mu (button), wh (wheel), kd/ku (key).
class InputEvent {
  final String t;
  final double? x, y, dx, dy;
  final int? b;
  final String? code;
  InputEvent(this.t, {this.x, this.y, this.dx, this.dy, this.b, this.code});

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{'t': t};
    if (x != null) m['x'] = x;
    if (y != null) m['y'] = y;
    if (dx != null) m['dx'] = dx;
    if (dy != null) m['dy'] = dy;
    if (b != null) m['b'] = b;
    if (code != null) m['code'] = code;
    return m;
  }
}

class IceServer {
  final List<String> urls;
  final String? username, credential;
  IceServer(this.urls, {this.username, this.credential});
  factory IceServer.fromJson(Map<String, dynamic> j) => IceServer(
        (j['urls'] as List).cast<String>(),
        username: j['username'],
        credential: j['credential'],
      );
  Map<String, dynamic> toMap() => {
        'urls': urls,
        if (username != null) 'username': username,
        if (credential != null) 'credential': credential,
      };
}
