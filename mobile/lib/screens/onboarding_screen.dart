import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const OnboardingScreen({super.key, required this.onComplete});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _serverController = TextEditingController(text: 'https://');
  final _keyController = TextEditingController();
  final _api = ApiService();
  bool _loading = false;
  String? _error;

  Future<void> _connect() async {
    setState(() { _loading = true; _error = null; });

    final server = _serverController.text.trim();
    final key = _keyController.text.trim();

    if (server.isEmpty || key.isEmpty) {
      setState(() { _error = 'Both fields are required'; _loading = false; });
      return;
    }

    await _api.configure(server, key);
    final ok = await _api.testConnection();

    if (ok) {
      widget.onComplete();
    } else {
      setState(() { _error = 'Connection failed. Check URL and key.'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.bgBase, AppColors.bgDeep],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10, height: 10,
                      decoration: const BoxDecoration(
                        color: AppColors.success,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('Echo',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Connect to your second brain',
                  style: TextStyle(color: AppColors.foregroundMuted, fontSize: 15),
                ),
                const SizedBox(height: 48),
                TextField(
                  controller: _serverController,
                  decoration: const InputDecoration(hintText: 'Server URL'),
                  keyboardType: TextInputType.url,
                  style: const TextStyle(fontSize: 15),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _keyController,
                  decoration: const InputDecoration(hintText: 'API Key'),
                  obscureText: true,
                  style: const TextStyle(fontSize: 15),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: AppColors.error, fontSize: 13)),
                ],
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _connect,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    child: _loading
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Connect', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
