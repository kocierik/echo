import 'dart:async';

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../widgets/panel.dart';
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
              // Reversed: it opens on the latest message, the oldest above it
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _messages.length,
                  itemBuilder: (context, fromEnd) {
                    final i = _messages.length - 1 - fromEnd;
                    return PanelListRow(
                      index: i,
                      count: _messages.length,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Text(_messages[i], style: TextStyle(color: palette.text)),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
