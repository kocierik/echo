import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

class IntegrationsScreen extends StatefulWidget {
  const IntegrationsScreen({super.key});

  @override
  State<IntegrationsScreen> createState() => _IntegrationsScreenState();
}

class _IntegrationsScreenState extends State<IntegrationsScreen> {
  final _api = ApiService();
  List<Map<String, dynamic>> _providers = [];
  List<Map<String, dynamic>> _userIntegrations = [];
  bool _loading = true;
  String? _pendingProviderId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final providers = await _api.getAvailableProviders();
      final integrations = await _api.getUserIntegrations();
      setState(() {
        _providers = providers;
        _userIntegrations = integrations;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  bool _isEnabled(String providerId) {
    return _userIntegrations.any((i) => i['provider'] == providerId && i['enabled'] == true);
  }

  String? _getIntegrationId(String providerId) {
    final match = _userIntegrations.where((i) => i['provider'] == providerId).toList();
    return match.isNotEmpty ? match.first['id'] : null;
  }

  Future<void> _toggle(Map<String, dynamic> provider) async {
    final providerId = provider['id'] as String;
    if (_pendingProviderId != null) return;

    HapticFeedback.mediumImpact();
    final authType = provider['auth_type'] ?? 'manual';
    final integrationId = _getIntegrationId(providerId);

    setState(() => _pendingProviderId = providerId);
    try {
      if (integrationId != null) {
        // Toggle existing
        final current = _isEnabled(providerId);
        await _api.updateIntegration(integrationId, enabled: !current);
      } else if (authType == 'oauth2') {
        // OAuth flow: open browser for authorization
        final url = await _api.getOAuthUrl(providerId);
        await _launchUrl(url);
        // Poll for connection (user completes in browser)
        await _pollForConnection(providerId);
      } else {
        // Manual config: show dialog
        final config = await _showConfigDialog(provider);
        if (config != null) {
          await _api.createIntegration(providerId, config);
        }
      }
    } catch (error) {
      if (mounted) {
        final message = error.toString().replaceFirst('Exception: ', '');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } finally {
      await _load();
      if (mounted) setState(() => _pendingProviderId = null);
    }
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        // Fallback: try with platformDefault
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (e) {
      // Fallback: show copyable URL
      if (mounted) {
        Clipboard.setData(ClipboardData(text: url));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copied — open it in your browser to connect')),
        );
      }
    }
  }

  Future<void> _pollForConnection(String providerId) async {
    // Check every 2s for up to 60s if the integration was created via OAuth callback
    int attempts = 0;
    await Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 2));
      attempts++;
      await _load();
      if (_isEnabled(providerId) || attempts >= 30) return false;
      return true;
    });
  }

  Future<Map<String, dynamic>?> _showConfigDialog(Map<String, dynamic> provider) async {
    final fields = List<Map<String, dynamic>>.from(provider['config_fields'] ?? []);
    final controllers = <String, TextEditingController>{};
    for (final f in fields) {
      controllers[f['key']] = TextEditingController();
    }

    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Connect ${provider['name']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: fields.map((f) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              controller: controllers[f['key']],
              obscureText: f['type'] == 'password',
              decoration: InputDecoration(
                labelText: f['label'],
                labelStyle: const TextStyle(fontSize: 13, color: AppColors.foregroundMuted),
              ),
              style: const TextStyle(fontSize: 14),
            ),
          )).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: AppColors.foregroundMuted)),
          ),
          TextButton(
            onPressed: () {
              final config = <String, dynamic>{};
              for (final f in fields) {
                config[f['key']] = controllers[f['key']]!.text.trim();
              }
              Navigator.pop(ctx, config);
            },
            child: const Text('Connect', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }

  IconData _getIcon(String icon) {
    switch (icon) {
      case 'check_circle': return Icons.check_circle_outline_rounded;
      case 'calendar_today': return Icons.calendar_today_rounded;
      case 'note': return Icons.note_alt_outlined;
      case 'send': return Icons.send_rounded;
      case 'chat': return Icons.chat_outlined;
      default: return Icons.extension_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Integrations'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.bgBase, AppColors.bgDeep],
          ),
        ),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _providers.length,
                itemBuilder: (_, i) => _ProviderCard(
                  provider: _providers[i],
                  enabled: _isEnabled(_providers[i]['id']),
                  pending: _pendingProviderId == _providers[i]['id'],
                  icon: _getIcon(_providers[i]['icon'] ?? ''),
                  onTap: () => _toggle(_providers[i]),
                ),
              ),
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  final Map<String, dynamic> provider;
  final bool enabled;
  final bool pending;
  final IconData icon;
  final VoidCallback onTap;

  const _ProviderCard({required this.provider, required this.enabled, required this.pending, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.bgElevated,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: enabled ? AppColors.success.withOpacity(0.3) : AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: enabled ? AppColors.success.withOpacity(0.1) : AppColors.surface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 20, color: enabled ? AppColors.success : AppColors.foregroundMuted),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(provider['name'] ?? '', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.foreground)),
                  const SizedBox(height: 2),
                  Text(provider['description'] ?? '', style: const TextStyle(fontSize: 12, color: AppColors.foregroundMuted), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Container(
              constraints: const BoxConstraints(minWidth: 42, minHeight: 24),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: enabled ? AppColors.success.withOpacity(0.1) : AppColors.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: pending
                  ? const SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      enabled ? 'ON' : 'OFF',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: enabled ? AppColors.success : AppColors.foregroundMuted),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
