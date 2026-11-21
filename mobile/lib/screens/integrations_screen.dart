import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/action_models.dart';
import '../services/api/api_exception.dart';
import '../services/api/api_service.dart';
import '../theme/app_theme.dart';
import 'settings/settings_components.dart';

typedef UrlLauncher = Future<bool> Function(Uri uri);

Future<bool> _defaultLauncher(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

/// Detail of the backend's 503 when COMPOSIO_API_KEY is missing.
const notConfiguredDetail = 'Composio is not configured';

/// SnackBar when a background reload fails while a list is shown.
const refreshFailedMessage = "Couldn't refresh the list.";

class IntegrationsScreen extends StatefulWidget {
  const IntegrationsScreen({
    this.api,
    this.launcher,
    this.extras = const [],
    this.activity,
    super.key,
  });

  /// Injected API (not disposed by the screen); a private one is created when
  /// omitted.
  final ApiService? api;
  final UrlLauncher? launcher;

  /// Above the apps to connect: the phone's own apps and WhatsApp (Profile's rows).
  final List<Widget> extras;

  /// What Echo did in these apps (Profile's Activity row), first.
  final Widget? activity;

  @override
  State<IntegrationsScreen> createState() => _IntegrationsScreenState();
}

class _IntegrationsScreenState extends State<IntegrationsScreen> with WidgetsBindingObserver {
  late final ApiService _api = widget.api ?? ApiService();
  final _searchController = TextEditingController();
  Timer? _debounce;
  int _requestId = 0;

  List<Toolkit> _toolkits = const [];
  bool _loading = true;
  bool _unavailable = false;
  String? _error;
  String? _pendingSlug;

  /// An app whose connect page was opened: back in Echo, whether it worked is said.
  Toolkit? _connecting;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _searchController.dispose();
    if (widget.api == null) _api.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load(silent: true, report: true);
  }

  /// A list (not the spinner, an error or the setup text) is on screen.
  bool get _showingList => !_loading && _error == null && !_unavailable;

  /// A failed silent reload (after connect/disconnect, on resume) keeps the
  /// list on screen and says so in a SnackBar; true when it handled it.
  bool _keptListAfterFailure(bool silent) {
    if (!silent || !_showingList) return false;
    _showMessage(refreshFailedMessage);
    return true;
  }

  /// Loads the toolkits. A [silent] reload shows no spinner and, if it fails
  /// while a list is shown, keeps that list; only the initial or an explicit
  /// load (Retry, search) replaces it with the error view.
  Future<void> _load({bool silent = false, bool report = false}) async {
    final id = ++_requestId;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
        _unavailable = false;
      });
    }
    try {
      final query = _searchController.text.trim();
      final toolkits = await _api.getToolkits(query: query);
      if (!mounted || id != _requestId) return;
      setState(() {
        _toolkits = toolkits;
        _loading = false;
        _error = null;
        _unavailable = false;
      });
      if (report) _reportConnection(toolkits);
    } on ApiException catch (error) {
      if (!mounted || id != _requestId) return;
      if (_keptListAfterFailure(silent)) return;
      setState(() {
        _loading = false;
        // Only the server's "no API key" 503 is a setup state; other 503s
        // (e.g. a proxy) are ordinary errors with Retry.
        _unavailable = error.code == 'unavailable' && error.message == notConfiguredDetail;
        _error = _unavailable ? null : error.message;
      });
    } catch (_) {
      if (!mounted || id != _requestId) return;
      if (_keptListAfterFailure(silent)) return;
      setState(() {
        _loading = false;
        _unavailable = false;
        _error = 'Could not load integrations.';
      });
    }
  }

  /// Back from an app's connect page: connected, or not yet.
  void _reportConnection(List<Toolkit> toolkits) {
    final asked = _connecting;
    if (asked == null) return;
    _connecting = null;
    final now = toolkits.where((t) => t.slug == asked.slug).firstOrNull;
    _showMessage(
      now?.connected == true
          ? '${asked.name} connected. Echo can use it now.'
          : '${asked.name} is not connected yet. Finish in the browser, or tap Connect again.',
    );
  }

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _load);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _messageOf(Object error) =>
      error is ApiException ? error.message : 'Something went wrong.';

  Future<void> _connect(Toolkit toolkit) async {
    if (_pendingSlug != null) return;
    HapticFeedback.mediumImpact();
    setState(() => _pendingSlug = toolkit.slug);
    try {
      final url = await _api.connectToolkit(toolkit.slug);
      final launcher = widget.launcher ?? _defaultLauncher;
      var launched = false;
      try {
        launched = await launcher(Uri.parse(url));
      } catch (_) {
        launched = false;
      }
      if (!launched) {
        await Clipboard.setData(ClipboardData(text: url));
        _showMessage('Link copied. Open it in your browser to connect.');
      }
      _connecting = toolkit;
    } catch (error) {
      _showMessage(_messageOf(error));
    } finally {
      if (mounted) setState(() => _pendingSlug = null);
      await _load(silent: true);
    }
  }

  Future<void> _confirmDisconnect(Toolkit toolkit) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(
          'Disconnect ${toolkit.name}? Echo will no longer be able to use it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _pendingSlug != null) return;
    setState(() => _pendingSlug = toolkit.slug);
    try {
      await _api.disconnectToolkit(toolkit.slug);
    } catch (error) {
      _showMessage(_messageOf(error));
    } finally {
      if (mounted) setState(() => _pendingSlug = null);
      await _load(silent: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    // One list that scrolls: the apps on this phone, then the other apps and their search
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(title: const Text('Apps')),
      body: Builder(builder: (context) {
        final head = [
          if (widget.activity case final activity?) ...[
            const SizedBox(height: 8),
            SettingsGroup(children: [activity]),
          ],
          if (widget.extras.isNotEmpty) ...[
            const SettingsSection('ON THIS PHONE'),
            SettingsGroup(children: widget.extras),
            const SettingsSection('OTHER APPS'),
          ],
          ..._otherApps(palette),
        ];
        final rows = _unavailable || _loading || _error != null ? const <Toolkit>[] : _toolkits;
        // Built lazily: the other apps can be hundreds
        return ListView.builder(
          padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 24),
          itemCount: head.length + rows.length,
          itemBuilder: (_, i) {
            if (i < head.length) return head[i];
            final toolkit = rows[i - head.length];
            return Padding(
              key: ValueKey(toolkit.slug),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _ToolkitRow(
                toolkit: toolkit,
                pending: _pendingSlug == toolkit.slug,
                onConnect: () => _connect(toolkit),
                onDisconnect: () => _confirmDisconnect(toolkit),
              ),
            );
          },
        );
      }),
    );
  }

  List<Widget> _otherApps(EchoPalette palette) {
    Widget message(Widget child) => Padding(
          padding: const EdgeInsets.fromLTRB(32, 32, 32, 0),
          child: Center(child: child),
        );
    if (_unavailable) {
      return [
        message(Text(
          "Integrations aren't set up on the server yet. Add "
          'COMPOSIO_API_KEY to the backend .env and restart it.',
          textAlign: TextAlign.center,
          style: TextStyle(color: palette.text2),
        )),
      ];
    }
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: TextField(
          controller: _searchController,
          onChanged: _onQueryChanged,
          onSubmitted: (_) {
            _debounce?.cancel();
            _load();
          },
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search other apps',
            prefixIcon: Icon(Icons.search_rounded),
          ),
        ),
      ),
      if (_loading)
        message(const CircularProgressIndicator())
      else if (_error != null)
        message(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.text2),
            ),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ))
    ];
  }
}

class _ToolkitRow extends StatelessWidget {
  const _ToolkitRow({
    required this.toolkit,
    required this.pending,
    required this.onConnect,
    required this.onDisconnect,
  });

  final Toolkit toolkit;
  final bool pending;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final Widget trailing;
    if (pending) {
      trailing = const Padding(
        padding: EdgeInsets.only(right: 8),
        child: SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else if (toolkit.connected) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_rounded, size: 18, color: palette.green),
          const SizedBox(width: 4),
          Text('Connected', style: TextStyle(color: palette.green)),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (_) => onDisconnect(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'disconnect', child: Text('Disconnect')),
            ],
          ),
        ],
      );
    } else {
      trailing = Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilledButton(
          onPressed: onConnect,
          child: const Text('Connect'),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(AppTheme.panelRadius),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  toolkit.name,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                ),
                if (toolkit.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    toolkit.description,
                    style: TextStyle(fontSize: 12, color: palette.text2),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }
}
