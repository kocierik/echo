import 'package:flutter/material.dart';

/// Calls [onOpen] each time [requests] changes (a promises notification asked for
/// the Tasks page), and once at start for a request made before it existed.
final class TasksRequestListener extends StatefulWidget {
  const TasksRequestListener({
    required this.requests,
    required this.onOpen,
    required this.child,
    super.key,
  });

  final ValueNotifier<int> requests;
  final VoidCallback onOpen;
  final Widget child;

  @override
  State<TasksRequestListener> createState() => _TasksRequestListenerState();
}

final class _TasksRequestListenerState extends State<TasksRequestListener> {
  late int _seen = widget.requests.value;

  @override
  void initState() {
    super.initState();
    widget.requests.addListener(_onRequest);
  }

  @override
  void didUpdateWidget(covariant TasksRequestListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.requests != widget.requests) {
      oldWidget.requests.removeListener(_onRequest);
      widget.requests.addListener(_onRequest);
      _seen = widget.requests.value;
    }
  }

  @override
  void dispose() {
    widget.requests.removeListener(_onRequest);
    super.dispose();
  }

  void _onRequest() {
    if (!mounted || widget.requests.value == _seen) return;
    _seen = widget.requests.value;
    widget.onOpen();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
