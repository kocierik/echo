import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../theme/app_theme.dart';
import 'device_messages_screen.dart';
import 'integrations_screen.dart';
import 'rules_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _api = ApiService();
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
    _load();
  }

  @override
  void dispose() {
    _serverController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final server = await _api.getServerUrl();
    if (!mounted) return;
    setState(() {
      _serverController.text = server;
      _loading = false;
    });
  }

  Future<void> _save() async {
    final server = _serverController.text.trim();
    final key = _keyController.text.trim();
    if (server.isEmpty || key.isEmpty) {
      setState(() {
        _error = 'Enter both server URL and API key.';
        _success = null;
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
      _success = null;
    });
    final valid = await _api.validateCredentials(server, key);
    if (!mounted) return;
    if (!valid) {
      setState(() {
        _saving = false;
        _error = 'Connection failed. Check the URL and API key.';
      });
      return;
    }

    await _api.configure(server, key);
    if (!mounted) return;
    _keyController.clear();
    setState(() {
      _saving = false;
      _success = 'Connection settings saved.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgBase,
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                const _SectionTitle('CONNECTION'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  child: Column(
                    children: [
                      TextField(
                        controller: _serverController,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Server URL',
                          hintText: 'https://echo.example.com',
                          prefixIcon: Icon(Icons.cloud_outlined),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _keyController,
                        obscureText: !_showKey,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          labelText: 'New API key',
                          hintText: 'Required to update settings',
                          prefixIcon: const Icon(Icons.key_rounded),
                          suffixIcon: IconButton(
                            tooltip: _showKey ? 'Hide API key' : 'Show API key',
                            onPressed: () => setState(() => _showKey = !_showKey),
                            icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
                          ),
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(_error!, style: const TextStyle(color: AppColors.error, fontSize: 13)),
                        ),
                      ],
                      if (_success != null) ...[
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(_success!, style: const TextStyle(color: AppColors.success, fontSize: 13)),
                        ),
                      ],
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: _saving
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.check_rounded),
                          label: Text(_saving ? 'Checking...' : 'Test and save'),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: AppColors.border),
                const _SectionTitle('AUTOMATIONS'),
                _SettingsRow(
                  icon: Icons.auto_awesome_rounded,
                  title: 'Rules',
                  subtitle: 'Run actions when Echo recognizes something',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const RulesScreen()),
                  ),
                ),
                _SettingsRow(
                  icon: Icons.extension_rounded,
                  title: 'Integrations',
                  subtitle: 'Google Calendar, Todoist, Notion and more',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const IntegrationsScreen()),
                  ),
                ),
                const Divider(height: 1, color: AppColors.border),
                const _SectionTitle('DEVICE'),
                _SettingsRow(
                  icon: Icons.monitor_heart_outlined,
                  title: 'Device diagnostics',
                  subtitle: 'BLE transfer and upload messages',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const DeviceMessagesScreen()),
                  ),
                ),
              ],
            ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 10),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          color: AppColors.foregroundMuted,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Icon(icon, color: AppColors.accent),
      title: Text(title, style: const TextStyle(fontSize: 15, color: AppColors.foreground)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12, color: AppColors.foregroundMuted)),
      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.foregroundMuted),
      onTap: onTap,
    );
  }
}
