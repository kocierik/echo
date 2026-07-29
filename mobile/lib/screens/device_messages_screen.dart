import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/ble_service.dart';

class DeviceMessagesScreen extends StatefulWidget {
  const DeviceMessagesScreen({super.key});

  @override
  State<DeviceMessagesScreen> createState() => _DeviceMessagesScreenState();
}

class _DeviceMessagesScreenState extends State<DeviceMessagesScreen> {
  List<String> _messages = [];

  @override
  void initState() {
    super.initState();
    _messages = List.from(bleService.messages);
    bleService.messageStream.listen((msg) {
      if (!mounted) return;
      setState(() {
        _messages = List.from(bleService.messages);
      });
    });
  }

  void _clear() {
    // No persistent clear on service; just clear local view
    setState(() {
      _messages.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device messages'),
        backgroundColor: AppColors.bgBase,
        foregroundColor: AppColors.foreground,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: _messages.isEmpty ? null : _clear,
            tooltip: 'Clear view',
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.bgBase, AppColors.bgDeep],
          ),
        ),
        child: SafeArea(
          child: _messages.isEmpty
              ? const Center(child: Text('No device messages', style: TextStyle(color: AppColors.foregroundMuted)))
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages.length,
                  separatorBuilder: (_, __) => const Divider(color: AppColors.border),
                  itemBuilder: (context, i) {
                    final msg = _messages[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(msg, style: const TextStyle(color: AppColors.foreground)),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
