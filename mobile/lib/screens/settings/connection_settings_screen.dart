import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/api/api_exception.dart';
import '../../services/api/api_service.dart';
import '../../services/app/app_lifecycle_coordinator.dart';
import '../../services/app/network_policy.dart';
import 'settings_components.dart';

class ConnectionSettingsScreen extends StatefulWidget {
  const ConnectionSettingsScreen({
    required this.networkPolicy,
    required this.preferences,
    this.apiServiceFactory,
    super.key,
  });

  final NetworkPolicy networkPolicy;
  final SharedPreferences preferences;
  final ApiService Function()? apiServiceFactory;

  @override
  State<ConnectionSettingsScreen> createState() =>
      _ConnectionSettingsScreenState();
}

class _ConnectionSettingsScreenState
    extends State<ConnectionSettingsScreen> {
  late final ApiService _api;
  final _serverController = TextEditingController();
  final _keyController = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _showKey = false;
  String? _error;
  String? _success;

  @override
  void initState() {
    super.initState();
    _api = (widget.apiServiceFactory ?? ApiService.new)();
    _load();
  }

  @override
  void dispose() {
    _serverController.dispose();
    _keyController.dispose();
    _api.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final server = await _api.getServerUrl();
      if (!mounted) return;
      _serverController.text = server;
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Echo could not load the server settings.';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setAllowCellular(bool value) async {
    final previous = widget.networkPolicy.allowCellular;
    setState(() => widget.networkPolicy.setAllowCellular(value));
    final saved = await widget.preferences.setBool(
      AppLifecycleCoordinator.allowCellularPreferenceKey,
      value,
    );
    if (!saved && mounted) {
      setState(() {
        widget.networkPolicy.setAllowCellular(previous);
        _error = 'Echo could not save the network preference.';
      });
    }
  }

  Future<void> _save() async {
    final server = _serverController.text.trim();
    final key = _keyController.text.trim();
    final uri = Uri.tryParse(server);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      setState(() {
        _error = 'Enter a valid HTTP or HTTPS server URL.';
        _success = null;
      });
      return;
    }
    if (key.isEmpty) {
      setState(() {
        _error = 'Enter the API key to update the connection.';
        _success = null;
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
      _success = null;
    });
    try {
      final valid = await _api.validateCredentials(server, key);
      if (!valid) {
        throw const ApiException(
          statusCode: null,
          code: 'invalid_credentials',
          message: 'Connection failed. Check the URL and API key.',
          retryable: false,
        );
      }
      await _api.configure(server, key);
      final connected = await _api.testConnection();
      if (!connected) {
        throw const ApiException(
          statusCode: null,
          code: 'saved_credentials_rejected',
          message: 'The server rejected the saved credentials.',
          retryable: false,
        );
      }
      if (!mounted) return;
      _keyController.clear();
      setState(() => _success = 'Connection settings saved.');
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on TimeoutException {
      if (mounted) setState(() => _error = 'The server timed out. Try again.');
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Echo could not reach the server. Try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Connection',
      children: [
        const SettingsSection('BACKEND'),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: Column(
              children: [
                TextField(
                  key: const Key('server-url-field'),
                  controller: _serverController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Server URL'),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('api-key-field'),
                  controller: _keyController,
                  obscureText: !_showKey,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'API key',
                    suffixIcon: IconButton(
                      tooltip: _showKey ? 'Hide API key' : 'Show API key',
                      onPressed: () => setState(() => _showKey = !_showKey),
                      icon: Icon(
                        _showKey ? Icons.visibility_off : Icons.visibility,
                      ),
                    ),
                  ),
                ),
                if (_error != null) SettingsMessage(_error!, error: true),
                if (_success != null) SettingsMessage(_success!),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('save-connection'),
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_done_outlined),
                    label: Text(_saving ? 'Checking...' : 'Test and save'),
                  ),
                ),
              ],
            ),
          ),
        const SettingsSection('NETWORK'),
        SettingsRow(
          icon: Icons.cell_tower_rounded,
          title: 'Use cellular data',
          subtitle: 'When off, uploads wait for Wi-Fi or Ethernet.',
          trailing: Switch(
            key: const Key('allow-cellular-switch'),
            value: widget.networkPolicy.allowCellular,
            onChanged: _setAllowCellular,
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Text('Roaming access follows your system network settings.'),
        ),
      ],
    );
  }
}