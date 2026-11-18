import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/signed_in_device.dart';
import '../../services/api/api_exception.dart';
import '../../services/api/api_service.dart';
import 'connect_app_sheet.dart';
import '../../services/app/app_runtime.dart';
import '../../utils/formatting.dart';
import 'settings_components.dart';

/// Settings → Devices: the phones signed in to the account. This one can sign
/// out; the others can be revoked (they will have to sign in again).
final class DevicesScreen extends StatefulWidget {
  const DevicesScreen(
      {this.api, this.signOut, this.clock = DateTime.now, super.key});

  /// The app's server, unless injected.
  final DevicesApi? api;

  /// Signs this phone out (the session's logout), unless injected.
  final Future<void> Function()? signOut;
  final DateTime Function() clock;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

final class _DevicesScreenState extends State<DevicesScreen> {
  late final DevicesApi _api;
  ApiService? _ownedApi;
  List<SignedInDevice>? _devices;
  String? _error;
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? (_ownedApi = ApiService());
    unawaited(_load());
  }

  @override
  void dispose() {
    _ownedApi?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final devices = await _api.listDevices();
      if (!mounted) return;
      // This phone first, then the most recently used
      devices.sort((a, b) {
        if (a.current != b.current) return a.current ? -1 : 1;
        final aUsed = a.lastUsedAt ?? a.createdAt ?? DateTime(0);
        final bUsed = b.lastUsedAt ?? b.createdAt ?? DateTime(0);
        return bUsed.compareTo(aUsed);
      });
      setState(() => _devices = devices);
    } catch (error) {
      if (!mounted) return;
      setState(
          () => _error = userMessage(error, 'Could not load your devices.'));
    }
  }

  Future<bool> _confirm(String title, String body, String action) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(body),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(action),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _revoke(SignedInDevice device) async {
    final confirmed = await _confirm(
      'Revoke ${device.name}?',
      device.isConnectedApp
          ? 'It will lose access to your memory.'
          : 'It will have to sign in again.',
      'Revoke',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy.add(device.id));
    try {
      await _api.revokeDevice(device.id);
      if (!mounted) return;
      setState(() => _devices = [
            for (final d in _devices ?? const <SignedInDevice>[])
              if (d.id != device.id) d,
          ]);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(userMessage(error, 'Could not revoke it.'))),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(device.id));
    }
  }

  Future<void> _signOut() async {
    final confirmed = await _confirm(
      'Sign out of this phone?',
      'Echo stops listening through it until you sign in again.',
      'Sign out',
    );
    if (!confirmed) return;
    final signOut = widget.signOut ??
        () async => AppRuntime.maybeCoordinator?.sessionController.logout();
    await signOut();
  }

  String _subtitle(SignedInDevice device) {
    if (device.current) return 'This phone';
    final used = device.lastUsedAt;
    if (used != null) return 'Last used ${dayLabel(used, widget.clock())}';
    final created = device.createdAt;
    return created == null
        ? 'Never used'
        : 'Signed in ${dayLabel(created, widget.clock())}';
  }

  /// Asks a name, creates a read-only key for it, then shows the setup once.
  Future<void> _connectApp() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NameDialog(),
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final app = await _api.connectApp(name);
      if (!mounted) return;
      unawaited(_load());
      await showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => ConnectAppSheet(app: app),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(userMessage(error, 'Could not connect it.'))),
      );
    }
  }

  /// When an assistant last read the memory: the sign of a key in use, or forgotten.
  String _appUsed(SignedInDevice device) {
    final used = device.lastUsedAt;
    if (used != null) return 'Last used ${dayLabel(used, widget.clock())}';
    final created = device.createdAt;
    return created == null
        ? 'Never used'
        : 'Created ${dayLabel(created, widget.clock())}, never used';
  }

  Widget _row(SignedInDevice device) {
    final phone = device.platform != null;
    return SettingsRow(
      key: Key('device-${device.id}'),
      icon: device.isConnectedApp
          ? Icons.hub_outlined
          : !phone
              ? Icons.key_rounded
              : device.platform == 'android'
                  ? Icons.phone_android_rounded
                  : Icons.phone_iphone_rounded,
      title: device.name,
      subtitle: device.isConnectedApp
          ? '${_appUsed(device)} · read-only'
          : phone
              ? _subtitle(device)
              : 'A key made on the server, for scripts',
      trailing: _busy.contains(device.id)
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              key: Key(device.current
                  ? 'devices-sign-out'
                  : 'devices-revoke-${device.id}'),
              onPressed: () =>
                  unawaited(device.current ? _signOut() : _revoke(device)),
              child: Text(device.current ? 'Sign out' : 'Revoke'),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices;
    // Phones signed in through the app; keys made on the server (make create-key)
    // have no platform. This phone counts as a phone even with an old key.
    final phones = [
      for (final d in devices ?? const <SignedInDevice>[])
        if (d.platform != null || d.current) d,
    ];
    final apps = [
      for (final d in devices ?? const <SignedInDevice>[])
        if (d.isConnectedApp) d,
    ];
    final keys = [
      for (final d in devices ?? const <SignedInDevice>[])
        if (d.platform == null && !d.current && !d.isConnectedApp) d,
    ];
    return SettingsPageScaffold(
      title: 'Devices',
      children: [
        if (_error != null) ...[
          SettingsMessage(_error!, error: true),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('devices-retry'),
                onPressed: () => unawaited(_load()),
                child: const Text('Retry'),
              ),
            ),
          ),
        ] else if (devices == null)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          if (phones.isNotEmpty) ...[
            const SettingsSection('PHONES'),
            for (final device in phones) _row(device),
          ],
          const SettingsSection('CONNECTED APPS'),
          for (final device in apps) _row(device),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('connect-app'),
                onPressed: () => unawaited(_connectApp()),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Connect an assistant'),
              ),
            ),
          ),
          if (keys.isNotEmpty) ...[
            const SettingsSection('OTHER KEYS'),
            for (final device in keys) _row(device),
          ],
        ],
      ],
    );
  }
}


/// The name of a new connected app ("Claude Code"), to find it in the list later.
final class _NameDialog extends StatefulWidget {
  const _NameDialog();

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

final class _NameDialogState extends State<_NameDialog> {
  final _names = TextEditingController(text: 'Claude Code');

  @override
  void dispose() {
    _names.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Connect an assistant'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('It will read your memory and change nothing. Name it to find it '
              'here later.'),
          const SizedBox(height: 12),
          TextField(
            controller: _names,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_names.text.trim()),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
