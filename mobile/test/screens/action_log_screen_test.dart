import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/screens/action_log_screen.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakeApi extends ApiService {
  _FakeApi(this.entries);

  final List<ActionLogEntry> entries;

  @override
  Future<List<ActionLogEntry>> getActionLog({int limit = 50}) async => entries;

  @override
  void dispose() {}
}

ActionLogEntry _entry(String tool, {String? error, String outcome = 'ok'}) =>
    ActionLogEntry(
      tool: tool,
      toolkit: 'gmail',
      argumentsSummary: 'args of $tool',
      outcome: outcome,
      error: error,
      createdAt: DateTime.utc(2026, 10, 13, 10),
    );

Future<void> _pump(WidgetTester tester, List<ActionLogEntry> entries) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.light,
    home: ActionLogScreen(api: _FakeApi(entries)),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists entries newest first with errors in red', (tester) async {
    await _pump(tester, [
      _entry('GMAIL_SEND_EMAIL', error: 'boom', outcome: 'failed'),
      _entry('SLACK_POST'),
    ]);

    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('args of GMAIL_SEND_EMAIL'), findsOneWidget);
    expect(find.text('args of SLACK_POST'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('GMAIL_SEND_EMAIL')).dy,
      lessThan(tester.getTopLeft(find.text('SLACK_POST')).dy),
    );
    final errorText = tester.widget<Text>(find.text('boom'));
    expect(errorText.style?.color, EchoPalette.light.red);
  });

  testWidgets('shows an empty state', (tester) async {
    await _pump(tester, const []);

    expect(find.text('No actions yet.'), findsOneWidget);
  });
}
