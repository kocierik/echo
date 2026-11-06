import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/whatsapp.dart';
import '../../services/api/api_exception.dart';
import '../../services/api/whatsapp_api.dart';
import '../../theme/app_theme.dart';
import 'settings_components.dart';

/// Profile's subtitle for WhatsApp.
String whatsAppText(WhatsAppStatus status) => switch (status.state) {
      'linked' => 'Linked: ${status.phone ?? ''}'.trim(),
      'linking' => 'Waiting for the code in WhatsApp…',
      'unreachable' => "Echo cannot reach WhatsApp right now.",
      'blocked' => 'Refused by WhatsApp: the number may be blocked.',
      _ => 'Let Echo read your private chats.',
    };

/// Profile → WhatsApp: what linking means (unofficial; private chats only, read-only,
/// kept in memory for 7 days), linking with a pairing code, and unlinking.
final class WhatsAppScreen extends StatefulWidget {
  const WhatsAppScreen({
    required this.api,
    this.pollInterval = const Duration(seconds: 3),
    super.key,
  });

  final WhatsAppApi api;

  /// While a code is shown: how often to check WhatsApp took it.
  final Duration pollInterval;

  @override
  State<WhatsAppScreen> createState() => _WhatsAppScreenState();
}

final class _WhatsAppScreenState extends State<WhatsAppScreen> {
  final _phone = TextEditingController();
  WhatsAppStatus? _status;
  String? _code;
  String? _error;
  bool _busy = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    _poll?.cancel();
    try {
      final status = await widget.api.getWhatsApp();
      if (!mounted) return;
      // The code shown was typed and accepted: say it worked
      final justLinked = status.isLinked && (_code != null || _status?.state == 'linking');
      if (justLinked) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          key: Key('whatsapp-linked'),
          content: Text('WhatsApp linked. Echo can now read your private chats.'),
        ));
      }
      setState(() {
        _status = status;
        if (status.isLinked) _code = null;
        if (_code != null && (status.state == 'unlinked' || status.state == 'blocked')) {
          // The bridge gave the link up: the code was not typed in time or not accepted
          _code = null;
          if (status.state == 'unlinked') {
            _error = 'The code expired or was not accepted. Ask for a new one.';
          }
        }
      });
    } catch (_) {
      if (mounted && _code == null) {
        setState(() => _error = 'Could not load WhatsApp. Check your connection.');
      }
    }
    // While a code is shown, keep checking, also after a failed check
    if (mounted && _code != null) {
      _poll = Timer(widget.pollInterval, () => unawaited(_load()));
    }
  }

  Future<void> _link() async {
    final phone = _phone.text.trim();
    if (phone.isEmpty || _busy) return;
    if (!phone.startsWith('+') && !phone.startsWith('00')) {
      // "333 1234567" would be another country's number, maybe a stranger's
      setState(() => _error = 'Write the number with its country code, like +39 333 123 4567.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final code = await widget.api.linkWhatsApp(phone);
      if (!mounted) return;
      setState(() => _code = code);
      await _load();
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.statusCode == 409) {
        // Linked meanwhile (another phone, a retry)
        await _load();
        return;
      }
      setState(() => _error = switch (error.statusCode) {
            504 => 'WhatsApp did not answer in time. Try again.',
            422 => 'Write the number with its country code, like +39 333 123 4567.',
            _ => 'Could not get a code. Check the number, with its country code, and try again.',
          });
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Could not get a code. Check the number, with its country code, and try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlink() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unlink WhatsApp?'),
        content: const Text(
          'Echo stops reading your chats and forgets the messages it held.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Unlink'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.unlinkWhatsApp();
      await _load();
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not unlink. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "ABCD1234" as "ABCD-1234", as WhatsApp shows its boxes.
  static String _spaced(String code) =>
      code.length == 8 ? '${code.substring(0, 4)}-${code.substring(4)}' : code;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final status = _status;
    final note = textTheme.bodyMedium?.copyWith(color: palette.text2);
    return SettingsPageScaffold(
      title: 'WhatsApp',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            'Echo reads your private chats (not groups) to answer you and for your '
            'routines. It never sends anything or marks a message as read, and keeps '
            'messages only in memory, for 7 days at most.',
            style: note,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Text(
            'The connection is not official: WhatsApp may block the number that uses it.',
            style: textTheme.bodyMedium?.copyWith(color: palette.red),
          ),
        ),
        if (status == null && _error == null)
          const Center(child: CircularProgressIndicator())
        else if (status?.state == 'unreachable')
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text("Echo cannot reach WhatsApp right now. Try again later.", style: note),
          )
        else if (status != null && status.isLinked) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(whatsAppText(status), style: textTheme.titleMedium),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: TextButton.icon(
                key: const Key('whatsapp-unlink'),
                onPressed: _busy ? null : () => unawaited(_unlink()),
                icon: Icon(Icons.link_off_rounded, color: palette.red),
                label: Text('Unlink', style: TextStyle(color: palette.red)),
              ),
            ),
          ),
        ] else if (_code != null) ...[
          Center(
            child: SelectableText(
              _spaced(_code!),
              key: const Key('whatsapp-code'),
              style: textTheme.headlineMedium?.copyWith(letterSpacing: 4),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text(
              '1. Open WhatsApp → Settings → Linked devices.\n'
              '2. Link a device → Link with phone number instead.\n'
              '3. Type this code. This page updates once it is linked.',
              style: note,
            ),
          ),
        ] else if (status != null) ...[
          if (status.state == 'blocked')
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                'WhatsApp refused this device: the number may be blocked. You can try '
                'linking again.',
                style: textTheme.bodyMedium?.copyWith(color: palette.red),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              key: const Key('whatsapp-phone'),
              controller: _phone,
              keyboardType: TextInputType.phone,
              autofillHints: const [AutofillHints.telephoneNumber],
              decoration: const InputDecoration(
                labelText: 'Your WhatsApp number',
                hintText: '+39 333 123 4567',
              ),
              onSubmitted: (_) => unawaited(_link()),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: FilledButton(
                key: const Key('whatsapp-link'),
                onPressed: _busy ? null : () => unawaited(_link()),
                child: Text(_busy ? 'Asking WhatsApp…' : 'Get the code'),
              ),
            ),
          ),
        ],
        if (_error != null) SettingsMessage(_error!, error: true),
      ],
    );
  }
}
