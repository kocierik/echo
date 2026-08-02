import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key});

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  final _api = ApiService();
  List<Map<String, dynamic>> _rules = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rules = await _api.getRules();
    setState(() {
      _rules = rules;
      _loading = false;
    });
  }

  Future<void> _toggleRule(String id, bool enabled) async {
    HapticFeedback.mediumImpact();
    await _api.updateRule(id, enabled: !enabled);
    _load();
  }

  Future<void> _deleteRule(String id) async {
    HapticFeedback.heavyImpact();
    await _api.deleteRule(id);
    _load();
  }

  void _openCreateSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CreateRuleSheet(
        api: _api,
        onCreated: () { Navigator.pop(context); _load(); },
      ),
    );
  }

  String _conditionsSummary(Map<String, dynamic> conditions) {
    if (conditions.isEmpty) return 'Always';
    final parts = <String>[];
    conditions.forEach((key, value) {
      if (key == 'entity_type') {
        parts.add(value.toString().toUpperCase());
      } else if (key == 'metadata.priority') {
        parts.add('priority: $value');
      } else if (key.contains('contains')) {
        parts.add('contains "$value"');
      } else {
        parts.add('$key=$value');
      }
    });
    return parts.join(' + ');
  }

  String _actionsSummary(List actions) {
    return actions.map((a) => (a['type'] ?? '').toString().toUpperCase()).join(', ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Automation Rules'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded, size: 24),
            onPressed: _openCreateSheet,
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
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _rules.isEmpty
                ? _EmptyState(onAdd: _openCreateSheet)
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _rules.length,
                    itemBuilder: (_, i) {
                      final rule = _rules[i];
                      final enabled = rule['enabled'] == true;
                      final conditions = Map<String, dynamic>.from(rule['conditions'] ?? {});
                      final actions = List.from(rule['actions'] ?? []);
                      final triggerCount = rule['trigger_count'] ?? 0;

                      return Dismissible(
                        key: Key(rule['id']),
                        direction: DismissDirection.endToStart,
                        onDismissed: (_) => _deleteRule(rule['id']),
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          decoration: BoxDecoration(
                            color: AppColors.error.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(Icons.delete_rounded, color: AppColors.error),
                        ),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppColors.bgElevated,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: enabled ? AppColors.accent.withValues(alpha: 0.3) : AppColors.border,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      rule['name'] ?? 'Untitled',
                                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.foreground),
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () => _toggleRule(rule['id'], enabled),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: enabled ? AppColors.success.withValues(alpha: 0.1) : AppColors.surface,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        enabled ? 'ON' : 'OFF',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: enabled ? AppColors.success : AppColors.foregroundMuted,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              // IF row
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppColors.accent.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text('IF', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.accent)),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _conditionsSummary(conditions),
                                      style: const TextStyle(fontSize: 12, color: AppColors.foregroundMuted),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              // THEN row
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppColors.success.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text('THEN', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.success)),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _actionsSummary(actions),
                                      style: const TextStyle(fontSize: 12, color: AppColors.foregroundMuted),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              if (triggerCount > 0) ...[
                                const SizedBox(height: 8),
                                Text(
                                  'Triggered $triggerCount time${triggerCount > 1 ? "s" : ""}',
                                  style: const TextStyle(fontSize: 11, color: AppColors.foregroundMuted),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome_rounded, size: 48, color: AppColors.accent.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            const Text(
              'No rules yet',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: AppColors.foreground),
            ),
            const SizedBox(height: 8),
            const Text(
              'Create rules to automate actions when\nspecific things are mentioned in conversations',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.foregroundMuted, height: 1.4),
            ),
            const SizedBox(height: 24),
            GestureDetector(
              onTap: onAdd,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text('Create Rule', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreateRuleSheet extends StatefulWidget {
  final ApiService api;
  final VoidCallback onCreated;

  const _CreateRuleSheet({required this.api, required this.onCreated});

  @override
  State<_CreateRuleSheet> createState() => _CreateRuleSheetState();
}

class _CreateRuleSheetState extends State<_CreateRuleSheet> {
  List<Map<String, dynamic>> _templates = [];
  bool _loading = true;
  bool _showCustom = false;

  final _nameController = TextEditingController();
  String _entityType = 'task';
  String _actionType = 'webhook';
  final _actionValueController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadTemplates();
  }

  Future<void> _loadTemplates() async {
    final templates = await widget.api.getRuleTemplates();
    setState(() { _templates = templates; _loading = false; });
  }

  Future<void> _createFromTemplate(Map<String, dynamic> template) async {
    await widget.api.createRule({
      'name': template['name'],
      'description': template['description'],
      'conditions': template['conditions'],
      'actions': template['actions'],
    });
    widget.onCreated();
  }

  Future<void> _createCustom() async {
    if (_nameController.text.trim().isEmpty) return;

    final conditions = <String, dynamic>{'entity_type': _entityType};
    final actions = <Map<String, dynamic>>[];

    if (_actionType == 'webhook') {
      actions.add({'type': 'webhook', 'url': _actionValueController.text.trim()});
    } else if (_actionType == 'telegram') {
      actions.add({'type': 'telegram', 'bot_token': '', 'chat_id': _actionValueController.text.trim()});
    } else if (_actionType == 'tag') {
      actions.add({'type': 'tag', 'tag': _actionValueController.text.trim()});
    } else {
      actions.add({'type': _actionType});
    }

    await widget.api.createRule({
      'name': _nameController.text.trim(),
      'conditions': conditions,
      'actions': actions,
    });
    widget.onCreated();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.9,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scrollController) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Text('New Rule', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.foreground)),
                const Spacer(),
                GestureDetector(
                  onTap: () => setState(() => _showCustom = !_showCustom),
                  child: Text(
                    _showCustom ? 'Templates' : 'Custom',
                    style: const TextStyle(fontSize: 13, color: AppColors.accent),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              child: _showCustom ? _buildCustomForm() : _buildTemplates(scrollController),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTemplates(ScrollController controller) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    return ListView.builder(
      controller: controller,
      itemCount: _templates.length,
      itemBuilder: (_, i) {
        final t = _templates[i];
        return GestureDetector(
          onTap: () => _createFromTemplate(t),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t['name'] ?? '', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.foreground)),
                const SizedBox(height: 4),
                Text(t['description'] ?? '', style: const TextStyle(fontSize: 12, color: AppColors.foregroundMuted)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCustomForm() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(hintText: 'Rule name'),
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 16),
          const Text('When entity type is:', style: TextStyle(fontSize: 12, color: AppColors.foregroundMuted)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: ['task', 'event', 'idea', 'person', 'note'].map((type) {
              final selected = _entityType == type;
              return GestureDetector(
                onTap: () => setState(() => _entityType = type),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.accent.withValues(alpha: 0.15) : AppColors.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: selected ? AppColors.accent : AppColors.border),
                  ),
                  child: Text(type, style: TextStyle(fontSize: 12, color: selected ? AppColors.accent : AppColors.foregroundMuted)),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          const Text('Then do:', style: TextStyle(fontSize: 12, color: AppColors.foregroundMuted)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: ['webhook', 'telegram', 'tag', 'google_calendar', 'todoist'].map((type) {
              final selected = _actionType == type;
              return GestureDetector(
                onTap: () => setState(() => _actionType = type),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.success.withValues(alpha: 0.15) : AppColors.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: selected ? AppColors.success : AppColors.border),
                  ),
                  child: Text(type, style: TextStyle(fontSize: 12, color: selected ? AppColors.success : AppColors.foregroundMuted)),
                ),
              );
            }).toList(),
          ),
          if (_actionType == 'webhook' || _actionType == 'telegram' || _actionType == 'tag') ...[
            const SizedBox(height: 16),
            TextField(
              controller: _actionValueController,
              decoration: InputDecoration(
                hintText: _actionType == 'webhook' ? 'https://your-server.com/hook'
                    : _actionType == 'telegram' ? 'Chat ID'
                    : 'Tag name',
              ),
              style: const TextStyle(fontSize: 14),
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: GestureDetector(
              onTap: _createCustom,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text('Create Rule', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
