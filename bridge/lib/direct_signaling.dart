import 'dart:convert';

/// Messages exchanged over the existing session WebSocket while a direct
/// WebRTC data channel is being negotiated.
///
/// The relay does not interpret these messages; it only forwards them. Keeping
/// the wire format here makes the signaling contract shared by the Dart bridge
/// and the CLI without giving the relay access to tunnel payloads.
sealed class DirectSignal {
  const DirectSignal();

  static DirectSignal decode(Object raw) {
    final value = switch (raw) {
      String text => jsonDecode(text),
      Map<String, dynamic> map => map,
      _ => throw const FormatException('direct signal must be JSON object'),
    };
    if (value is! Map<String, dynamic>) {
      throw const FormatException('direct signal must be JSON object');
    }

    final version = value['v'];
    if (version != 1) {
      throw FormatException('unsupported direct signal version: $version');
    }

    return switch (value['t']) {
      'direct_offer' => DirectDescriptionSignal._fromJson(value, 'offer'),
      'direct_answer' => DirectDescriptionSignal._fromJson(value, 'answer'),
      'direct_candidate' => DirectCandidateSignal._fromJson(value),
      'direct_end' => const DirectEndSignal(),
      'direct_error' => DirectErrorSignal._fromJson(value),
      _ => throw FormatException('unknown direct signal type: ${value['t']}'),
    };
  }

  Map<String, dynamic> toJson();

  String encode() => jsonEncode(toJson());
}

final class DirectDescriptionSignal extends DirectSignal {
  DirectDescriptionSignal.offer(this.sdp) : type = 'offer';

  DirectDescriptionSignal.answer(this.sdp) : type = 'answer';

  DirectDescriptionSignal._fromJson(Map<String, dynamic> json, this.type)
    : sdp = _requiredString(json, 'sdp');

  final String type;
  final String sdp;

  bool get isOffer => type == 'offer';
  bool get isAnswer => type == 'answer';

  @override
  Map<String, dynamic> toJson() => {'v': 1, 't': 'direct_$type', 'sdp': sdp};
}

final class DirectCandidateSignal extends DirectSignal {
  const DirectCandidateSignal({
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });

  DirectCandidateSignal._fromJson(Map<String, dynamic> json)
    : candidate = _optionalString(json, 'candidate'),
      sdpMid = _optionalString(json, 'sdpMid'),
      sdpMLineIndex = _optionalInt(json, 'sdpMLineIndex');

  /// Null represents the end-of-candidates marker.
  final String? candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;

  @override
  Map<String, dynamic> toJson() => {
    'v': 1,
    't': 'direct_candidate',
    if (candidate != null) 'candidate': candidate,
    if (sdpMid != null) 'sdpMid': sdpMid,
    if (sdpMLineIndex != null) 'sdpMLineIndex': sdpMLineIndex,
  };
}

final class DirectEndSignal extends DirectSignal {
  const DirectEndSignal();

  @override
  Map<String, dynamic> toJson() => const {'v': 1, 't': 'direct_end'};
}

final class DirectErrorSignal extends DirectSignal {
  const DirectErrorSignal(this.message);

  DirectErrorSignal._fromJson(Map<String, dynamic> json)
    : message = _requiredString(json, 'message');

  final String message;

  @override
  Map<String, dynamic> toJson() => {
    'v': 1,
    't': 'direct_error',
    'message': message,
  };
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('direct signal field "$key" must be non-empty');
  }
  return value;
}

String? _optionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.isEmpty) {
    throw FormatException('direct signal field "$key" must be a string');
  }
  return value;
}

int? _optionalInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! int) {
    throw FormatException('direct signal field "$key" must be an integer');
  }
  return value;
}
