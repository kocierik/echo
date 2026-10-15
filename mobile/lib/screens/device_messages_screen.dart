import 'dart:async';

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/device/ble_service.dart';

class DeviceMessagesScreen extends StatefulWidget {
  const DeviceMessagesScreen({super.key});

  @override
  State<DeviceMessagesScreen> createState() => _DeviceMessagesScreenState();
}

class _DeviceMessagesScreenState extends State<DeviceMessagesScreen> {
  List<String> _messages = [];
  StreamSubscription<String>? _messageSubscription;

  @override
  void initState() {
    super.initState();
    _messages = List.from(bleService.messages);
    _messageSubscription = bleService.messageStream.listen((msg) {
      if (!mounted) return;
      setState(() {
        _messages = List.from(bleService.messages);
      });
    });
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    super.dispose();
  }

  void _clear() {
    // No persistent clear on service; just clear local view
    setState(() {
      _messages.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device messages'),
        backgroundColor: palette.background,
        foregroundColor: palette.text,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: _messages.isEmpty ? null : _clear,
            tooltip: 'Clear view',
          ),
        ],
      ),
      body: ColoredBox(
        color: palette.background,
        child: SafeArea(
          child: _messages.isEmpty
              ? Center(
                  child: Text(
                    'No device messages',
                    style: TextStyle(color: palette.text2),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages.length,
                  separatorBuilder: (_, __) => Divider(color: palette.border),
                  itemBuilder: (context, i) {
                    final msg = _messages[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(msg, style: TextStyle(color: palette.text)),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
