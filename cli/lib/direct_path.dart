/// The route the phone's ICE agent settled on, as the `path` control message
/// reports it. The phone is the controlling side, so it knows both ends of
/// the selected pair; `local` is the phone's candidate and `remote` is ours.
///
/// Returns null for anything that is not a well-formed `path` message.
String? describeDirectPath(Map<String, dynamic> message) {
  if (message['t'] != 'path') return null;
  final network = message['network'];
  final family = message['family'];
  final protocol = message['protocol'];
  final local = message['local'];
  final remote = message['remote'];
  if (network is! String ||
      family is! String ||
      protocol is! String ||
      local is! String ||
      remote is! String) {
    return null;
  }
  final ip = switch (family) {
    'ipv4' => 'IPv4',
    'ipv6' => 'IPv6',
    _ => family,
  };
  return 'direct path: phone on $network, $ip/${protocol.toUpperCase()}, '
      'phone ${_candidate(local)} to computer ${_candidate(remote)}';
}

/// ICE candidate types (RFC 8445 5.1.1) in words an agent can repeat.
String _candidate(String type) => switch (type) {
  'host' => 'local address',
  'srflx' => 'public address (STUN)',
  'prflx' => 'public address (learned)',
  'relay' => 'relay',
  _ => type,
};
