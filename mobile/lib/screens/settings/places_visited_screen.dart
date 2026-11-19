import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/place.dart';
import '../../services/api/places_api.dart';
import '../../services/device/phone_words.dart';
import '../../services/phone/places_visited.dart';
import '../../services/phone/visit_sources.dart';
import '../../theme/app_theme.dart';
import '../../utils/formatting.dart';
import 'settings_components.dart';

/// Profile → Places visited: off by default. Turning it on explains what is kept before
/// the phone asks for "Always"; on, the visits are listed by day, each deletable, a day
/// or all at once. Turning it off stops at once and offers to delete what was kept.
final class PlacesVisitedScreen extends StatefulWidget {
  const PlacesVisitedScreen({
    required this.places,
    required this.api,
    this.openSettings,
    this.clock = DateTime.now,
    super.key,
  });

  final PlacesVisitedService places;
  final PlacesApi api;

  /// Opens Echo's page in iOS or Android settings (injected in tests).
  final Future<void> Function()? openSettings;
  final DateTime Function() clock;

  @override
  State<PlacesVisitedScreen> createState() => _PlacesVisitedScreenState();
}

final class _PlacesVisitedScreenState extends State<PlacesVisitedScreen> {
  VisitAccess? _access;
  final _visits = <PlaceVisit>[];
  bool _more = false;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool older = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final access = await widget.places.access();
      final page = await widget.api.listVisits(
        before: older && _visits.isNotEmpty ? _visits.last.arrivedAt : null,
      );
      if (!mounted) return;
      setState(() {
        _access = access;
        if (!older) _visits.clear();
        _visits.addAll(page.visits);
        _more = page.more;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Echo could not load the places. Check the connection and try again.';
      });
    }
  }

  Future<void> _openSettings() async {
    final open = widget.openSettings;
    if (open != null) return open();
    if (PhoneWords.isIPhone) {
      await launchUrl(Uri.parse('app-settings:'));
    } else {
      // EchoEngine.kt: Echo's App info page
      await const MethodChannel('echo/device').invokeMethod<void>('openAppSettings');
    }
  }

  Future<void> _turnOn() async {
    final access = await Navigator.push<VisitAccess>(
      context,
      MaterialPageRoute(builder: (_) => _OptInScreen(places: widget.places)),
    );
    if (access == null || !mounted) return;
    setState(() => _access = access);
  }

  Future<void> _turnOff() async {
    setState(() => _busy = true);
    await widget.places.turnOff();
    if (!mounted) return;
    setState(() => _busy = false);
    if (_visits.isEmpty) return;
    final delete = await _confirm(
      title: 'Delete the places Echo kept?',
      body: 'Echo has stopped noting places. The visits it kept stay for 90 days '
          'unless you delete them now.',
      action: 'Delete all',
      cancel: 'Keep them',
    );
    if (delete) await _deleteAll(confirmed: true);
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
    String cancel = 'Cancel',
  }) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(cancel)),
          FilledButton(
            key: const Key('places-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  Future<void> _deleted(Future<void> Function() delete, bool Function(PlaceVisit) gone) async {
    try {
      await delete();
      if (mounted) setState(() => _visits.removeWhere(gone));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Echo could not delete it. Try again.')));
    }
  }

  Future<void> _deleteVisit(PlaceVisit visit) async {
    final ok = await _confirm(
      title: 'Delete this visit?',
      body: '${visit.label}, ${_span(visit)}.',
      action: 'Delete',
    );
    if (ok) await _deleted(() => widget.api.deleteVisit(visit.id), (v) => v.id == visit.id);
  }

  Future<void> _deleteDay(DateTime day) async {
    final ok = await _confirm(
      title: 'Delete this day?',
      body: 'The places of ${dayLabel(day, widget.clock())} are deleted.',
      action: 'Delete day',
    );
    if (ok) {
      await _deleted(() => widget.api.deleteVisitDay(day), (v) => dayOf(v.arrivedAt) == day);
    }
  }

  Future<void> _deleteAll({bool confirmed = false}) async {
    final ok = confirmed ||
        await _confirm(
          title: 'Delete all places?',
          body: 'Every visit Echo kept is deleted. This cannot be undone.',
          action: 'Delete all',
        );
    if (ok) await _deleted(widget.api.deleteAllVisits, (_) => true);
  }

  String _span(PlaceVisit visit) {
    final left = visit.leftAt;
    return left == null
        ? 'since ${formatTime(visit.arrivedAt)}'
        : '${formatTime(visit.arrivedAt)}–${formatTime(left)}';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.places.on,
      builder: (context, on, _) => SettingsPageScaffold(
        title: 'Places visited',
        children: [
          SettingsMessage(
            on
                ? 'Echo notes where you stay 10 minutes or more, so it can tell you where '
                    'you were and where a conversation happened. Kept for 90 days.'
                : 'Off. When on, Echo notes where you stay 10 minutes or more, so it can '
                    'tell you where you were and where a conversation happened.',
          ),
          const SizedBox(height: 12),
          SettingsRow(
            icon: CupertinoIcons.location,
            title: 'Places visited',
            subtitle: on ? 'On · kept for 90 days' : 'Off',
            trailing: Switch(
              key: const Key('places-switch'),
              value: on,
              onChanged: _busy
                  ? null
                  : (value) => unawaited(value ? _turnOn() : _turnOff()),
            ),
          ),
          if (on && _access != null && _access != VisitAccess.always) ...[
            SettingsMessage(
              'Echo cannot notice visits: allow its location "Always" in '
              '${PhoneWords.systemSettings}.',
              error: true,
              key: const Key('places-needs-always'),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: OutlinedButton(
                onPressed: () => unawaited(_openSettings()),
                child: Text('Open ${PhoneWords.systemSettings}'),
              ),
            ),
          ],
          ..._list(context),
        ],
      ),
    );
  }

  List<Widget> _list(BuildContext context) {
    if (_loading && _visits.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_error != null) {
      return [
        SettingsMessage(_error!, error: true),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: OutlinedButton(onPressed: () => unawaited(_load()), child: const Text('Retry')),
        ),
      ];
    }
    if (_visits.isEmpty) {
      return widget.places.isOn
          ? [const SettingsMessage('No places yet. Visits appear here after you stay '
              'somewhere 10 minutes or more.')]
          : const [];
    }
    final now = widget.clock();
    final days = <DateTime, List<PlaceVisit>>{};
    for (final visit in _visits) {
      days.putIfAbsent(dayOf(visit.arrivedAt), () => []).add(visit);
    }
    return [
      for (final MapEntry(key: day, value: visits) in days.entries) ...[
        _DayHeader(
          label: dayLabel(day, now).toUpperCase(),
          onDelete: () => unawaited(_deleteDay(day)),
        ),
        for (final visit in visits.reversed)
          SettingsRow(
            key: Key('visit-${visit.id}'),
            icon: CupertinoIcons.location,
            title: visit.label,
            subtitle: [
              _span(visit),
              if (visit.name != null && visit.address != null) visit.address!,
              for (final conversation in visit.conversations)
                if (conversation.title != null) conversation.title!,
            ].join(' · '),
            trailing: IconButton(
              key: Key('visit-delete-${visit.id}'),
              tooltip: 'Delete this visit',
              icon: const Icon(CupertinoIcons.trash),
              onPressed: () => unawaited(_deleteVisit(visit)),
            ),
          ),
      ],
      if (_more)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: OutlinedButton(
            onPressed: _loading ? null : () => unawaited(_load(older: true)),
            child: const Text('Show older places'),
          ),
        ),
      SettingsRow(
        key: const Key('places-delete-all'),
        icon: CupertinoIcons.trash,
        title: 'Delete all places',
        destructive: true,
        onTap: () => unawaited(_deleteAll()),
      ),
    ];
  }
}

/// "SATURDAY …" and its "Delete day".
final class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label, required this.onDelete});

  final String label;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: palette.text2,
                    fontSize: 12,
                  ),
            ),
          ),
          TextButton(onPressed: onDelete, child: const Text('Delete day')),
        ],
      ),
    );
  }
}

/// What turning it on means, before the phone asks for "Always".
final class _OptInScreen extends StatefulWidget {
  const _OptInScreen({required this.places});

  final PlacesVisitedService places;

  @override
  State<_OptInScreen> createState() => _OptInScreenState();
}

final class _OptInScreenState extends State<_OptInScreen> {
  bool _asking = false;
  VisitAccess? _refused;

  Future<void> _continue() async {
    setState(() => _asking = true);
    final access = await widget.places.turnOn();
    if (!mounted) return;
    if (access == VisitAccess.always) {
      Navigator.pop(context, access);
      return;
    }
    setState(() {
      _asking = false;
      _refused = access;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final always = PhoneWords.isIPhone ? '"Always"' : '"Allow all the time"';
    final points = [
      (
        CupertinoIcons.location,
        'Echo notes where you stay 10 minutes or more: when you arrived, when you left, '
            'the address and, when the ${PhoneWords.phone} knows it, the name of the place.',
      ),
      (
        CupertinoIcons.arrow_branch,
        'Only the stays: no routes, and no positions in between.',
      ),
      (
        CupertinoIcons.clock,
        'Kept for 90 days, then deleted. Delete a visit, a day or all of them here, '
            'at any time.',
      ),
      (
        CupertinoIcons.lock,
        'Never shared with other people, or with the assistants you connect to your '
            'memory.',
      ),
      (
        CupertinoIcons.battery_full,
        'Your ${PhoneWords.phone} will ask to use your location $always: Echo needs it '
            'to notice a visit while the ${PhoneWords.phone} is in your pocket. It uses the '
            'low-power location of the ${PhoneWords.phone}, not continuous GPS.',
      ),
    ];
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(title: const Text('Places visited')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text('Remember the places you visit?', style: textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Then Echo can answer "where were we on Saturday?" and show where each '
            'conversation happened.',
            style: textTheme.bodyMedium?.copyWith(color: palette.text2),
          ),
          const SizedBox(height: 20),
          for (final (icon, text) in points)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 22, color: palette.accent),
                  const SizedBox(width: 14),
                  Expanded(child: Text(text, style: textTheme.bodyMedium)),
                ],
              ),
            ),
        ],
      ),
      // Always on screen, however long the explanation
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_refused != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _refused == VisitAccess.off
                        ? 'Location is off on this ${PhoneWords.phone}. Turn it on in '
                            '${PhoneWords.systemSettings}, then try again.'
                        : 'Places visited stays off: Echo needs your location $always. '
                            'You can allow it in ${PhoneWords.systemSettings}.',
                    key: const Key('places-refused'),
                    style: textTheme.bodySmall?.copyWith(color: palette.red),
                  ),
                ),
              FilledButton(
                key: const Key('places-continue'),
                onPressed: _asking ? null : () => unawaited(_continue()),
                child: const Text('Continue'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Not now'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
