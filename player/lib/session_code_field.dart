// One way to enter a session code, shared by the lobby and the connector
// screen.
//
// A code arrives one of three ways — typed, pasted, or scanned — and each
// used to be handled separately: the lobby owned the scanner and the QR
// payload parser, the connector screen had a bare TextField and no scanner
// at all. Both now mount this widget, so the connector gains scanning and
// the parsing lives in exactly one place.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:rhr_bridge/session_code.dart';

const _violet = Color(0xFF7C4DFF);
const _ink = Color(0xFFF3F1FA);
const _inkDim = Color(0xFFA79FC4);
const _surface = Color(0xFF1A1330);
const _surfaceHi = Color(0xFF2E2350);
const _hint = Color(0xFF5A4E80);

/// A code plus the relays it should be dialled on.
///
/// A typed code carries no relay of its own, so those fields are null and the
/// caller keeps whatever relay it already had. A scanned QR usually names one.
class SessionCodeEntry {
  const SessionCodeEntry({
    required this.code,
    this.relay,
    this.fallbackRelays = const [],
  });

  final String code;
  final String? relay;
  final List<String> fallbackRelays;
}

/// An invitation to join an account, scanned from `rhr invite`.
///
/// Distinct from a session code: a code starts one session, while this joins
/// the phone to an account for good. The payload names the service so the
/// phone redeems over HTTPS with the account service rather than through the
/// relay, which does not authenticate its peers.
class AccountInvite {
  const AccountInvite({
    required this.token,
    required this.service,
    required this.account,
  });

  final String token;
  final String service;

  /// Whose account this is, for the consent screen. A display name only.
  final String account;
}

/// Reads a join invitation, or null when the QR is something else.
AccountInvite? parseAccountInvite(String raw) {
  try {
    final map = jsonDecode(raw.trim()) as Map<String, dynamic>;
    if (map['v'] != 1) return null;
    final token = map['join'];
    final service = map['service'];
    if (token is! String || service is! String) return null;
    // Only https: an invitation is a durable credential, and the plaintext
    // LAN relay this tool also speaks would expose it to the network.
    if (!service.startsWith('https://')) return null;
    return AccountInvite(
      token: token,
      service: service,
      account: map['account'] is String ? map['account'] as String : '',
    );
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
}

/// Parses what a QR carries: either the structured payload the CLI prints
/// (`{"code":..,"relay":..,"relays":[..]}`) or a bare code string.
SessionCodeEntry parseSessionPayload(String raw) {
  final trimmed = raw.trim();
  try {
    final map = jsonDecode(trimmed) as Map<String, dynamic>;
    final code = map['code'] is String ? map['code'] as String : trimmed;
    if (map['relays'] case final List relays) {
      final parsed = relays.whereType<String>().toList(growable: false);
      if (parsed.isNotEmpty) {
        return SessionCodeEntry(
          code: code,
          relay: parsed.first,
          fallbackRelays: parsed.skip(1).toList(growable: false),
        );
      }
    }
    if (map['relay'] case final String relay) {
      return SessionCodeEntry(code: code, relay: relay);
    }
    return SessionCodeEntry(code: code);
  } on FormatException {
    return SessionCodeEntry(code: trimmed);
  } on TypeError {
    // Valid JSON that isn't an object — a bare quoted string, say.
    return SessionCodeEntry(code: trimmed);
  }
}

/// Normalises anything a user can put in the field into `rhr-xxxx-xxxx-xxxx`.
///
/// Everything outside the code alphabet is dropped rather than rejected, so a
/// pasted `rhr-abcd-efgh-jkmn` and a typed `ABCDEFGHJKMN` land identically.
/// The prefix is stripped first because `h` and `r` are themselves alphabet
/// characters — left in, a paste would shift the whole code by three.
String formatSessionCodeInput(String raw) {
  var input = raw.toLowerCase();
  if (input.startsWith('rhr-')) input = input.substring(4);
  final body = input
      .split('')
      .where(rhrSessionCodeAlphabet.contains)
      .take(12)
      .join();
  final groups = <String>[];
  for (var i = 0; i < body.length; i += 4) {
    groups.add(body.substring(i, i + 4 > body.length ? body.length : i + 4));
  }
  return groups.isEmpty ? '' : 'rhr-${groups.join('-')}';
}

/// Keeps the field in `rhr-` form as the user types, hyphenating every four
/// characters and holding the caret at the end of what they entered.
class _SessionCodeFormatter extends TextInputFormatter {
  const _SessionCodeFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final input = newValue.text.toLowerCase();
    final text = 'rhr-'.startsWith(input)
        ? input
        : formatSessionCodeInput(input);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// Text field with a scanner button and a primary action beside it.
///
/// The controller is the caller's: both screens already keep the code around
/// for their own copy (the session card, the `rhr attach` line), so owning it
/// here would only force them to mirror it back.
class SessionCodeField extends StatelessWidget {
  const SessionCodeField({
    super.key,
    required this.controller,
    required this.actionLabel,
    required this.onSubmit,
    required this.onScanned,
    this.onInvite,
    this.enabled = true,
    this.errorText,
  });

  final TextEditingController controller;

  /// Label of the button beside the field — "Connect" in the lobby, where it
  /// starts the session; the connector screen picks a target afterwards.
  final String actionLabel;

  /// Null disables the action button without disabling entry.
  final VoidCallback? onSubmit;

  /// Called with the parsed scan. The caller applies the relays, because only
  /// it knows what its current ones are.
  final ValueChanged<SessionCodeEntry> onScanned;

  /// Called when the QR turns out to be an invitation to join an account
  /// rather than a session code. Absent on screens that cannot join.
  final ValueChanged<AccountInvite>? onInvite;

  final bool enabled;

  /// Shown under the field. A code complaint belongs against the input that
  /// caused it — a screen-level banner can end up scrolled out of sight below
  /// a long list, which reads as the button doing nothing at all.
  final String? errorText;

  Future<void> _scan(BuildContext context) async {
    final raw = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScannerScreen()));
    if (raw == null) return;
    // An account invitation and a session code arrive through the same
    // camera, so which one this is decides what happens next.
    final invite = parseAccountInvite(raw);
    if (invite != null) {
      onInvite?.call(invite);
      return;
    }
    final entry = parseSessionPayload(raw);
    controller.text = formatSessionCodeInput(entry.code);
    onScanned(
      SessionCodeEntry(
        code: controller.text,
        relay: entry.relay,
        fallbackRelays: entry.fallbackRelays,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            autocorrect: false,
            enableSuggestions: false,
            inputFormatters: const [_SessionCodeFormatter()],
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => onSubmit?.call(),
            style: const TextStyle(color: _ink, fontSize: 14),
            decoration: InputDecoration(
              errorText: errorText,
              hintText: 'rhr-xxxx-xxxx-xxxx',
              hintStyle: const TextStyle(color: _hint),
              prefixIcon: const Icon(Icons.tag, color: _inkDim, size: 18),
              suffixIcon: IconButton(
                tooltip: 'Scan QR',
                icon: const Icon(
                  Icons.qr_code_scanner_rounded,
                  color: _inkDim,
                  size: 20,
                ),
                onPressed: enabled ? () => _scan(context) : null,
              ),
              filled: true,
              fillColor: _surface,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 16,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: _surfaceHi),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: _violet, width: 1.5),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        FilledButton(
          onPressed: enabled ? onSubmit : null,
          style: FilledButton.styleFrom(
            backgroundColor: _violet,
            foregroundColor: Colors.white,
            disabledBackgroundColor: _surfaceHi,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          child: Text(
            actionLabel,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// Full-screen camera QR scanner. Pops with the raw scanned string; returns
/// null if the user backs out.
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan the dev QR')),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(
            onDetect: (capture) {
              if (_handled) return;
              final raw = capture.barcodes
                  .map((b) => b.rawValue)
                  .firstWhere(
                    (v) => v != null && v.isNotEmpty,
                    orElse: () => null,
                  );
              if (raw == null) return;
              _handled = true;
              Navigator.of(context).pop(raw);
            },
          ),
          // Simple viewfinder.
          Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: _violet, width: 3),
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          const Positioned(
            bottom: 48,
            child: Text(
              'Point at the QR in the dev’s terminal',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}
