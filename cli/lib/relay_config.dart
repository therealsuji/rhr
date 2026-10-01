import 'package:rhr_bridge/relay_defaults.dart';

/// Defaults shared by the terminal attach flow and the Flutter custom-device
/// helper. Keeping these values in one package prevents the two entry points
/// from drifting apart.
export 'package:rhr_bridge/relay_defaults.dart';

/// Must stay below the native player's 45-second developer presence lease.
const developerLeasePingInterval = Duration(seconds: 20);

/// Orders relay candidates for one run. A local relay is always preferred for
/// same-network traffic; an explicitly configured relay replaces the public
/// fallback instead of leaking the session code to the shared service.
List<String> relayCandidates({String? local, String? configured}) {
  return <String>[
    if (local != null) local,
    configured ?? defaultPublicRelay,
  ].toSet().toList(growable: false);
}
