import 'package:flutter/material.dart';

import '../screens/navigation.dart';
import '../screens/person_screen.dart';
import '../services/api/api_service.dart';

/// Opens a person's page when [request] gets an id (a briefing notification was tapped),
/// then sets it back to null.
final class PersonRequestListener extends StatefulWidget {
  const PersonRequestListener({
    required this.request,
    required this.child,
    this.onAsk,
    this.api,
    this.navigator,
    this.onShow,
    super.key,
  });

  final ValueNotifier<String?> request;
  final Widget child;
  final AskCallback? onAsk;
  final MemoryApi? api;

  /// Where the page opens; the app's navigator unless given.
  final GlobalKey<NavigatorState>? navigator;

  /// Called just before the page opens (the tab it opens in gets selected).
  final VoidCallback? onShow;

  @override
  State<PersonRequestListener> createState() => _PersonRequestListenerState();
}

final class _PersonRequestListenerState extends State<PersonRequestListener> {
  ApiService? _ownedApi;

  @override
  void initState() {
    super.initState();
    widget.request.addListener(_open);
    // A tap that launched the app arrived before this widget existed
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void didUpdateWidget(covariant PersonRequestListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request != widget.request) {
      oldWidget.request.removeListener(_open);
      widget.request.addListener(_open);
    }
  }

  @override
  void dispose() {
    widget.request.removeListener(_open);
    _ownedApi?.dispose();
    super.dispose();
  }

  void _open() {
    final id = widget.request.value;
    if (!mounted || id == null) return;
    widget.request.value = null;
    final api = widget.api ?? (_ownedApi ??= ApiService());
    widget.onShow?.call();
    (widget.navigator?.currentState ?? Navigator.of(context)).push<void>(MaterialPageRoute(
      builder: (_) => PersonScreen(personId: id, api: api, onAsk: widget.onAsk),
    ));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
