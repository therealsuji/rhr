// A Flutter debug engine discovered on this phone via mDNS: enough to build
// the loopback VM service URI (http://127.0.0.1:<port>/<authCode>/) that the
// connector tunnels to the developer.
class VmServiceEndpoint {
  const VmServiceEndpoint({
    required this.appLabel,
    required this.port,
    required this.authCode,
  });

  final String appLabel;
  final int port;
  final String authCode;

  factory VmServiceEndpoint.fromMap(Map<Object?, Object?> map) {
    return VmServiceEndpoint(
      appLabel: (map['appLabel'] as String?) ?? 'Flutter app',
      port: (map['port'] as num?)?.toInt() ?? 0,
      authCode: (map['authCode'] as String?) ?? '',
    );
  }
}
