import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:church_staff_pwa/core/time/church_time.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import '../../../../core/utils/error_messages.dart';
import '../../../../core/widgets/empty_state.dart';
import '../../domain/entities/service_roster.dart';
import '../../domain/roster_schedule.dart';
import '../../domain/roster_auto_assign.dart';
import '../../domain/roster_view_model.dart';
import '../providers/roster_provider.dart';
import '../widgets/roster_card.dart';

/// 排班的期間。
enum ArrangerPeriod {
  year('全年'),
  firstHalf('上半年'),
  secondHalf('下半年'),
  q1('第一季'),
  q2('第二季'),
  q3('第三季'),
  q4('第四季');

  const ArrangerPeriod(this.label);
  final String label;

  /// [year] 這一年裡的起訖日（含）。
  (DateTime, DateTime) range(int year) {
    final (startMonth, months) = switch (this) {
      ArrangerPeriod.year => (1, 12),
      ArrangerPeriod.firstHalf => (1, 6),
      ArrangerPeriod.secondHalf => (7, 6),
      ArrangerPeriod.q1 => (1, 3),
      ArrangerPeriod.q2 => (4, 3),
      ArrangerPeriod.q3 => (7, 3),
      ArrangerPeriod.q4 => (10, 3),
    };
    return (
      DateTime.utc(year, startMonth, 1),
      DateTime.utc(year, startMonth + months, 0),
    );
  }
}

/// 排班模式：給排服事表的同工，一次排一整季、半年或一整年（例如 2027）。
///
/// 跟一般服事表用同一份資料，只是不受「本季」限制：可以先建立整段期間的
/// 空白週次，再用表格一格一格填人。以電腦大螢幕為主。
class RosterArrangerScreen extends StatefulWidget {
  const RosterArrangerScreen({super.key, required this.allowedTypes});

  /// 這位同工可以編輯的聚會。
  final List<ServiceType> allowedTypes;

  @override
  State<RosterArrangerScreen> createState() => _RosterArrangerScreenState();
}

class _RosterArrangerScreenState extends State<RosterArrangerScreen> {
  late ServiceType _type = widget.allowedTypes.first;
  late int _year = _defaultYear();
  ArrangerPeriod _period = ArrangerPeriod.year;

  List<ServiceRoster>? _rosters;

  /// 同一段期間其他聚會的服事表（一鍵安排時避免同一天排到同一個人）。
  List<ServiceRoster> _others = const [];
  String? _error;
  bool _creating = false;
  bool _assigning = false;

  /// 第四季就預設排明年：那時候要排的通常是下一年度的表。
  static int _defaultYear() {
    final now = ChurchTime.now();
    return now.month >= 10 ? now.year + 1 : now.year;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _rosters = null;
      _error = null;
    });
    final (from, to) = _period.range(_year);
    try {
      final all = await context.read<RosterProvider>().loadRostersInRange(
        from,
        to,
      );
      if (!mounted) return;
      setState(() {
        _rosters = all.where((r) => r.type == _type).toList();
        _others = all.where((r) => r.type != _type).toList();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = mapErrorToUserMessage(e));
    }
  }

  int _missingCount(List<ServiceRoster> rosters) {
    final (from, to) = _period.range(_year);
    final templates = context.read<RosterProvider>().templates;
    return planRostersInRange(
      from: from,
      to: to,
      types: [_type],
      templates: templates,
      existing: rosters,
    ).length;
  }

  Future<void> _createBlankWeeks(int count) async {
    final label = '$_year 年${_period.label}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('建立空白週次'),
        content: Text(
          '要為「${_type.label}」建立 $label 的 $count 個空白週次嗎？\n\n'
          '會照「服事項目設定」放好每一項服事，人先填「待定」。已經有的週次不會被改動。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('建立'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _creating = true);
    final messenger = ScaffoldMessenger.of(context);
    final (from, to) = _period.range(_year);
    try {
      final created = await context
          .read<RosterProvider>()
          .createRostersInRange([_type], from, to);
      messenger.showSnackBar(
        SnackBar(content: Text('已建立 $created 個空白週次')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('建立失敗：${mapErrorToUserMessage(e)}')),
      );
    } finally {
      if (mounted) setState(() => _creating = false);
    }
    if (mounted) await _load();
  }

  Future<void> _autoAssign() async {
    final rosters = _rosters;
    if (rosters == null || _assigning) return;
    final provider = context.read<RosterProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final (from, _) = _period.range(_year);
    setState(() => _assigning = true);
    try {
      // 歷史：這段期間之前的一年，同一個聚會。
      final history = (await provider.loadRostersInRange(
        from.subtract(const Duration(days: 365)),
        from.subtract(const Duration(days: 1)),
      )).where((r) => r.type == _type).toList();
      if (!mounted) return;

      final counts = roleHistoryCounts([...history, ...rosters]);
      final roles = [
        for (final role in provider.templates[_type] ?? const <String>[])
          if (role != kTwSpeakerRole &&
              role != kMwSpeakerRole &&
              (counts[role]?.isNotEmpty ?? false))
            role,
      ];
      if (roles.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('沒有歷史資料可以參考，無法一鍵安排')),
        );
        return;
      }

      final eligible = await showDialog<Map<String, Set<String>>>(
        context: context,
        builder: (_) => _EligibilityDialog(
          roles: roles,
          counts: counts,
          initial: defaultEligible(counts),
        ),
      );
      if (eligible == null || !mounted) return;

      final result = autoAssign(
        targets: rosters,
        history: history,
        eligible: eligible,
        sameDayOthers: _others,
      );
      if (result.updated.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('沒有需要安排的空格')),
        );
        return;
      }

      final apply = await showDialog<bool>(
        context: context,
        builder: (_) => _PreviewDialog(result: result),
      );
      if (apply != true || !mounted) return;

      final originals = {for (final r in rosters) r.id: r};
      final before = [
        for (final r in result.updated)
          if (originals[r.id] != null) originals[r.id]!,
      ];
      await provider.updateRosters(result.updated);
      if (!mounted) return;
      await _load();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 10),
          content: Text('已安排 ${result.assignments.length} 格'),
          action: SnackBarAction(
            label: '復原',
            onPressed: () async {
              await provider.updateRosters(before);
              if (mounted) await _load();
            },
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('一鍵安排失敗：${mapErrorToUserMessage(e)}')),
      );
    } finally {
      if (mounted) setState(() => _assigning = false);
    }
  }

  void _onSaved(ServiceRoster updated) {
    final rosters = _rosters;
    if (rosters == null) return;
    setState(() {
      _rosters = [
        for (final r in rosters) r.id == updated.id ? updated : r,
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final thisYear = ChurchTime.now().year;
    final years = [for (var y = thisYear - 1; y <= thisYear + 2; y++) y];

    final controls = Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (widget.allowedTypes.length > 1)
          DropdownButton<ServiceType>(
            value: _type,
            onChanged: (value) {
              if (value == null) return;
              setState(() => _type = value);
              _load();
            },
            items: [
              for (final type in widget.allowedTypes)
                DropdownMenuItem(value: type, child: Text(type.serviceName)),
            ],
          ),
        DropdownButton<int>(
          value: _year,
          onChanged: (value) {
            if (value == null) return;
            setState(() => _year = value);
            _load();
          },
          items: [
            for (final y in years)
              DropdownMenuItem(value: y, child: Text('$y 年')),
          ],
        ),
        DropdownButton<ArrangerPeriod>(
          value: _period,
          onChanged: (value) {
            if (value == null) return;
            setState(() => _period = value);
            _load();
          },
          items: [
            for (final p in ArrangerPeriod.values)
              DropdownMenuItem(value: p, child: Text(p.label)),
          ],
        ),
      ],
    );

    final rosters = _rosters;
    final Widget body;
    if (_error != null) {
      body = EmptyState(
        icon: Icons.error_outline,
        message: _error!,
        action: FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: const Text('重試'),
        ),
      );
    } else if (rosters == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      final missing = _missingCount(rosters);
      final createButton = FilledButton.icon(
        onPressed: _creating ? null : () => _createBlankWeeks(missing),
        icon: _creating
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add_box_outlined),
        label: Text('建立 $missing 個空白週次'),
      );
      if (rosters.isEmpty) {
        body = EmptyState(
          icon: Icons.calendar_month_outlined,
          message: '$_year 年${_period.label}還沒有服事表',
          hint: missing > 0
              ? '先建立空白週次，再點表格的格子填人'
              : '這段期間沒有「${_type.serviceName}」的聚會日',
          action: missing > 0 ? createButton : null,
        );
      } else {
        body = Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '一鍵安排：依今年的歷史，把空格公平地填上做過這項服事的人（講員不排）。先預覽，確認後才寫入。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: _assigning ? null : _autoAssign,
                    icon: _assigning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_fix_high_outlined),
                    label: const Text('一鍵安排'),
                  ),
                ],
              ),
            ),
            if (missing > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '這段期間還有 $missing 週沒有服事表',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    createButton,
                  ],
                ),
              ),
            Expanded(
              child: RosterEditTable(
                type: _type,
                rosters: rosters,
                onSaved: _onSaved,
              ),
            ),
          ],
        );
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('排班模式'), centerTitle: true),
      body: Center(
        child: ConstrainedBox(
          // 電腦上不要拉到整個螢幕寬：表格太寬反而難對欄位。
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(alignment: Alignment.centerLeft, child: controls),
              ),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一鍵安排第一步：每一項服事可以排哪些人。預設勾選做過 2 次以上的人；
/// 安排者可以再勾（例如請產假剛回來、今年做得少的同工）或取消。
class _EligibilityDialog extends StatefulWidget {
  const _EligibilityDialog({
    required this.roles,
    required this.counts,
    required this.initial,
  });

  final List<String> roles;
  final Map<String, Map<String, int>> counts;
  final Map<String, Set<String>> initial;

  @override
  State<_EligibilityDialog> createState() => _EligibilityDialogState();
}

class _EligibilityDialogState extends State<_EligibilityDialog> {
  late final Map<String, Set<String>> _selected = {
    for (final role in widget.roles)
      role: {...?widget.initial[role]},
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('誰可以排？'),
      content: SizedBox(
        width: 560,
        child: ListView(
          shrinkWrap: true,
          children: [
            const Text(
              '每一項只會從勾選的人裡挑。預設勾選今年做過 2 次以上的人；數字是今年做過幾次。',
              style: TextStyle(fontSize: 13),
            ),
            for (final role in widget.roles) ...[
              const SizedBox(height: 14),
              Text(role, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final entry in (widget.counts[role]!.entries.toList()
                    ..sort((a, b) => b.value.compareTo(a.value))))
                    FilterChip(
                      label: Text('${entry.key} ${entry.value}'),
                      selected: _selected[role]!.contains(entry.key),
                      onSelected: (on) => setState(() {
                        if (on) {
                          _selected[role]!.add(entry.key);
                        } else {
                          _selected[role]!.remove(entry.key);
                        }
                      }),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected),
          child: const Text('下一步：預覽'),
        ),
      ],
    );
  }
}

/// 一鍵安排第二步：先看會怎麼排，確認後才寫入。
class _PreviewDialog extends StatelessWidget {
  const _PreviewDialog({required this.result});

  final AutoAssignResult result;

  @override
  Widget build(BuildContext context) {
    final byRoster = <String, List<AutoAssignment>>{};
    for (final a in result.assignments) {
      byRoster.putIfAbsent(a.roster.id, () => []).add(a);
    }
    final rosters = [
      for (final r in result.updated)
        if (byRoster.containsKey(r.id)) r,
    ];
    final counts = roleHistoryCounts(result.updated);
    return AlertDialog(
      title: Text('預覽：會填入 ${result.assignments.length} 格'),
      content: SizedBox(
        width: 620,
        child: ListView(
          shrinkWrap: true,
          children: [
            if (result.shortfalls.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '有 ${result.shortfalls.length} 格人不夠，只排到一部分或沒排到：'
                  '${result.shortfalls.map((a) => '${a.roster.date.month}/${a.roster.date.day} ${a.role}').join('、')}。'
                  '可以回上一步多勾幾個人，或之後手動補。',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            for (final r in rosters)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '${r.date.month}/${r.date.day}'
                  '${r.specialEvents.isEmpty ? '' : '（${r.specialEvents.join('・')}）'}　'
                  '${byRoster[r.id]!.map((a) => '${a.role}：${a.people.map(shortPersonName).join('、')}').join('　')}',
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
              ),
            const Divider(height: 24),
            const Text(
              '這段期間每人次數（含原本已排好的）',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            for (final MapEntry(key: role, value: byPerson) in counts.entries)
              if (result.assignments.any((a) => a.role == role))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '$role：${(byPerson.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).map((e) => '${e.key} ${e.value}').join('、')}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('套用'),
        ),
      ],
    );
  }
}
