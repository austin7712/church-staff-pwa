import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:church_staff_pwa/core/time/church_time.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import '../../../../core/utils/error_messages.dart';
import '../../../auth/presentation/providers/group_settings_provider.dart';
import '../../../../core/widgets/empty_state.dart';
import '../../domain/entities/service_roster.dart';
import '../../domain/roster_schedule.dart';
import '../../domain/roster_auto_assign.dart';
import '../../domain/roster_view_model.dart';
import '../../domain/name_check.dart';
import '../../../auth/presentation/providers/user_admin_provider.dart';
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
  /// 有設定服事項目的聚會才排（沒有項目的分頁排不了東西）。
  late final List<ServiceType> _types = () {
    final templates = context.read<RosterProvider>().templates;
    List<String> rolesOf(ServiceType t) => templates[t] ?? const <String>[];
    // 服事項目已經全部包含在另一個聚會裡的（兒童主日、幼兒主日已併進主日），
    // 排那一個就好，不另外列出來，免得同一格排兩次。
    bool coveredByOther(ServiceType t) => widget.allowedTypes.any(
      (o) =>
          o != t &&
          rolesOf(o).length > rolesOf(t).length &&
          rolesOf(t).every(rolesOf(o).contains),
    );
    final withRoles = [
      for (final t in widget.allowedTypes)
        if (rolesOf(t).isNotEmpty && !coveredByOther(t)) t,
    ];
    return withRoles.isEmpty ? widget.allowedTypes : withRoles;
  }();
  late ServiceType _type = _types.first;
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

  /// 一鍵安排與同工名單都需要的資料：歷史（這段期間之前一年）、每人次數、
  /// 要排的服事項目、同工名單（沒整理過的項目用今年做過的人當預設）。
  Future<
    ({
      List<ServiceRoster> history,
      Map<String, Map<String, int>> counts,
      List<String> roles,
      StaffPool pool,
    })
  >
  _loadPool(RosterProvider provider, List<ServiceRoster> rosters) async {
    final groups = allSmallGroups(context.read<GroupSettingsProvider>());
    final (from, _) = _period.range(_year);
    final history = (await provider.loadRostersInRange(
      from.subtract(const Duration(days: 365)),
      from.subtract(const Duration(days: 1)),
    )).where((r) => r.type == _type).toList();
    final counts = roleHistoryCounts([...history, ...rosters]);
    final roles = [
      for (final role in provider.templates[_type] ?? const <String>[])
        if (role != kTwSpeakerRole && role != kMwSpeakerRole) role,
    ];
    final saved = await provider.loadStaffPool(_type);
    final pool = saved.withDefaults(counts, roles);
    // 愛餐整理這類以小組為單位的：預設是小組管理裡的全部小組，順序就是輪流順序。
    return (
      history: history,
      counts: counts,
      roles: roles,
      pool: StaffPool({
        for (final MapEntry(key: role, value: people) in pool.roles.entries)
          role: isGroupRole(role) && saved.roles[role] == null
              ? groups
              : people,
      }, saved.families, saved.ratios),
    );
  }

  Future<void> _editPool() async {
    final rosters = _rosters;
    if (rosters == null || _assigning) return;
    final provider = context.read<RosterProvider>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _assigning = true);
    try {
      final data = await _loadPool(provider, rosters);
      if (!mounted) return;
      // 名字檢查要用：App 帳號的名字（讀不到也沒關係，只是少一種比對）。
      var userNames = const <String>[];
      try {
        userNames = [
          for (final u in await context.read<UserAdminProvider>().getUsers())
            u.name,
        ];
      } catch (_) {}
      if (!mounted) return;
      final edited = await showDialog<StaffPool>(
        context: context,
        builder: (_) => _PoolEditorDialog(
          serviceName: _type.serviceName,
          roles: data.roles,
          counts: data.counts,
          pool: data.pool,
          userNames: userNames,
        ),
      );
      if (edited == null) return;
      await provider.saveStaffPool(_type, edited);
      messenger.showSnackBar(const SnackBar(content: Text('同工名單已儲存')));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('儲存失敗：${mapErrorToUserMessage(e)}')),
      );
    } finally {
      if (mounted) setState(() => _assigning = false);
    }
  }

  Future<void> _autoAssign() async {
    final rosters = _rosters;
    if (rosters == null || _assigning) return;
    final provider = context.read<RosterProvider>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _assigning = true);
    try {
      final data = await _loadPool(provider, rosters);
      if (!mounted) return;
      final history = data.history;
      final eligible = data.pool.eligible;
      final groupRoles = {
        for (final MapEntry(key: role, value: groups)
            in data.pool.roles.entries)
          if (isGroupRole(role) && groups.isNotEmpty) role: groups,
      };
      if (groupRoles.isEmpty &&
          eligible.values.every((people) => people.isEmpty)) {
        messenger.showSnackBar(
          const SnackBar(content: Text('同工名單是空的：先按「同工名單」填好每一項可以排的人')),
        );
        return;
      }

      final result = autoAssign(
        targets: rosters,
        history: history,
        eligible: eligible,
        sameDayOthers: _others,
        groupRoles: groupRoles,
        templateRoles: data.roles,
        // 幼兒主日的老師一次連兩週。
        consecutiveWeeks: const {'幼兒主日': 2},
        // 兒童主日老師一個月換一次。
        monthlyRoles: const {'兒童主日'},
        // 幼兒主日老師和「幼兒助教」是兩個服事項目，各排一位（同一天不會
        // 是同一人）。助教跟其他項目一樣照天數公平分配。
        families: data.pool.families,
        ratios: data.pool.ratios,
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

  /// 把這段期間排好的人全部改回「待定」（講員不動），可以復原。
  Future<void> _clearAll() async {
    final rosters = _rosters;
    if (rosters == null || _assigning) return;
    final provider = context.read<RosterProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final cleared = clearAssignments(rosters);
    if (cleared.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('這段期間沒有排好的人')));
      return;
    }
    final label = '$_year 年${_period.label}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('一鍵清空'),
        content: Text(
          '要把 $label 的 ${cleared.length} 週排好的人全部改回「待定」嗎？\n\n'
          '講員和特殊事件不會動。清空後 10 秒內可以按「復原」。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _assigning = true);
    final originals = {for (final r in rosters) r.id: r};
    final before = [for (final r in cleared) originals[r.id]!];
    try {
      await provider.updateRosters(cleared);
      if (!mounted) return;
      await _load();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 10),
          content: Text('已清空 ${cleared.length} 週'),
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
        SnackBar(content: Text('清空失敗：${mapErrorToUserMessage(e)}')),
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
        if (_types.length == 1)
          Text(
            '總覽（全部服事項目）',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        if (_types.length > 1)
          DropdownButton<ServiceType>(
            value: _type,
            onChanged: (value) {
              if (value == null) return;
              setState(() => _type = value);
              _load();
            },
            items: [
              for (final type in _types)
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
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Text(
                      '先整理「同工名單」（每一項可以排誰，愛餐整理是小組），再按「一鍵安排」把所有服事的空格一起公平地填上（講員不排）。會先預覽，確認後才寫入。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _assigning ? null : _editPool,
                    icon: const Icon(Icons.groups_outlined),
                    label: const Text('同工名單'),
                  ),
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
                  OutlinedButton.icon(
                    onPressed: _assigning ? null : _clearAll,
                    icon: const Icon(Icons.cleaning_services_outlined),
                    label: const Text('一鍵清空'),
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

/// 「同工名單」：每一項服事可以排哪些人。一開始是今年做過的人；安排者可以
/// 加新同工、拿掉不再服事的人。一鍵安排只從這份名單挑。
class _PoolEditorDialog extends StatefulWidget {
  const _PoolEditorDialog({
    required this.serviceName,
    required this.roles,
    required this.counts,
    required this.pool,
    this.userNames = const [],
  });

  final String serviceName;
  final List<String> roles;
  final Map<String, Map<String, int>> counts;
  final StaffPool pool;
  final List<String> userNames;

  @override
  State<_PoolEditorDialog> createState() => _PoolEditorDialogState();
}

class _PoolEditorDialogState extends State<_PoolEditorDialog> {
  late final Map<String, List<String>> _pool = {
    for (final role in widget.roles)
      role: [...?widget.pool.roles[role]],
  };
  late final Map<String, Map<String, double>> _ratios = {
    for (final MapEntry(key: role, value: byPerson)
        in widget.pool.ratios.entries)
      role: {...byPerson},
  };

  static const _ratioSteps = [1.0, 0.75, 0.5, 0.25, 0.1, 0.05, 0.0];

  /// 點一下名字換下一個比例：100% → 75% → 50% → 25% → 10% → 5% → 0% → 100%。
  /// 0%＝留在名單上，但一鍵安排不排他（只能手動排）。
  void _cycleRatio(String role, String name) {
    final current = _ratios[role]?[name] ?? 1.0;
    final i = _ratioSteps.indexWhere((r) => (r - current).abs() < 0.01);
    final next = _ratioSteps[(i + 1) % _ratioSteps.length];
    setState(() {
      final byPerson = _ratios.putIfAbsent(role, () => {});
      if (next == 1.0) {
        byPerson.remove(name);
      } else {
        byPerson[name] = next;
      }
    });
  }

  /// 把 [others] 都改成 [target]（同工名單、家人、服事比例一起改）。
  void _unify(String target, List<String> others) {
    setState(() {
      for (final role in _pool.keys) {
        final list = _pool[role]!;
        final merged = <String>[];
        for (final n in list) {
          final m = others.contains(n) ? target : n;
          if (!merged.contains(m)) merged.add(m);
        }
        _pool[role] = merged;
      }
      for (var i = 0; i < _families.length; i++) {
        _families[i] = [
          for (final n in _families[i]) others.contains(n) ? target : n,
        ];
      }
      for (final byPerson in _ratios.values) {
        for (final o in others) {
          final r = byPerson.remove(o);
          if (r != null) byPerson.putIfAbsent(target, () => r);
        }
      }
    });
  }

  Widget _nameCheck(BuildContext context) {
    final rosterCounts = <String, int>{};
    for (final byPerson in widget.counts.values) {
      for (final e in byPerson.entries) {
        rosterCounts[e.key] = (rosterCounts[e.key] ?? 0) + e.value;
      }
    }
    final result = checkNames(
      poolNames: [
        for (final MapEntry(key: role, value: names) in _pool.entries)
          if (!isGroupRole(role)) ...names,
        for (final f in _families) ...f,
      ],
      rosterCounts: rosterCounts,
      userNames: widget.userNames,
    );
    final style = Theme.of(context).textTheme.bodySmall;
    if (result.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text('✅ 名字檢查：沒有發現寫法不一致的名字。', style: style),
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE9C84A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '⚠️ 名字檢查',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            '同一個人寫法不一樣，系統會當成兩個人：天數分開算、同一天重複排也'
            '檢查不出來、LINE 提醒對不上。',
            style: style,
          ),
          for (final g in result.similar) ...[
            const SizedBox(height: 8),
            Text('可能是同一個人：${g.names.join('／')}', style: style),
            Wrap(
              spacing: 6,
              children: [
                for (final target in g.names)
                  OutlinedButton(
                    onPressed: () => _unify(target, [
                      for (final n in g.names)
                        if (n != target) n,
                    ]),
                    child: Text('名單統一成「$target」'),
                  ),
              ],
            ),
          ],
          if (result.unknown.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '不在任何服事表、也不是 App 帳號：${result.unknown.join('、')}'
              '（新同工就不用管；如果是打錯字請改正）',
              style: style,
            ),
          ],
          const SizedBox(height: 6),
          Text(
            '「統一」只改同工名單；已經排好的服事表上的舊寫法，請在表格裡點那一格改。',
            style: style?.copyWith(color: Colors.grey[700]),
          ),
        ],
      ),
    );
  }

  String _ratioLabel(String role, String name) {
    final r = _ratios[role]?[name] ?? 1.0;
    if (r == 1.0) return '';
    return r == 0 ? ' 0%（不自動排）' : ' ${(r * 100).round()}%';
  }
  late final Map<String, TextEditingController> _inputs = {
    for (final role in widget.roles) role: TextEditingController(),
  };
  late final List<List<String>> _families = [
    for (final f in widget.pool.families) [...f],
  ];
  final _familyInput = TextEditingController();

  void _addFamily() {
    final members = _familyInput.text
        .split(RegExp(r'[、,，&＆/／+＋]'))
        .map((m) => m.trim())
        .where((m) => m.isNotEmpty)
        .toSet()
        .toList();
    if (members.length < 2) return;
    setState(() {
      _families.add(members);
      _familyInput.clear();
    });
  }

  @override
  void dispose() {
    for (final c in _inputs.values) {
      c.dispose();
    }
    _familyInput.dispose();
    super.dispose();
  }

  void _add(String role) {
    final name = _inputs[role]!.text.trim();
    if (name.isEmpty) return;
    setState(() {
      if (!_pool[role]!.contains(name)) _pool[role]!.add(name);
      _inputs[role]!.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('同工名單：${widget.serviceName}'),
      content: SizedBox(
        width: 620,
        child: ListView(
          shrinkWrap: true,
          children: [
            const Text(
              '一鍵安排只會從這裡的名單挑人，不會跨到別的服事。可以加新同工、按 ✕ 拿掉不再服事的人。'
              '括號裡是今年做過幾次。點一下名字可以調整服事比例（例如 50% 就是大約只排別人的一半）。名字要跟服事表上的寫法一樣。',
              style: TextStyle(fontSize: 13),
            ),
            _nameCheck(context),
            const SizedBox(height: 16),
            Text(
              '家人（一起出席、一起缺席，盡量排同一天）',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final f in _families)
                  InputChip(
                    label: Text(f.join(' ＆ ')),
                    onDeleted: () => setState(() => _families.remove(f)),
                    deleteButtonTooltipMessage: '拿掉',
                  ),
                if (_families.isEmpty)
                  Text(
                    '還沒有',
                    style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                  ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _familyInput,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '新增一家人，例如「Kevin、Grace」後按 Enter',
                    ),
                    onSubmitted: (_) => _addFamily(),
                  ),
                ),
                IconButton(
                  tooltip: '新增',
                  icon: const Icon(Icons.family_restroom_outlined),
                  onPressed: _addFamily,
                ),
              ],
            ),
            for (final role in widget.roles) ...[
              const SizedBox(height: 16),
              Text(
                isGroupRole(role) ? '$role（小組，一個月一組，照這個順序輪）' : role,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final name in _pool[role]!)
                    InputChip(
                      label: Text(
                        isGroupRole(role)
                            ? name
                            : '$name（${widget.counts[role]?[name] ?? 0}）'
                                  '${_ratioLabel(role, name)}',
                      ),
                      selected: (_ratios[role]?[name] ?? 1.0) < 1.0,
                      showCheckmark: false,
                      tooltip: '點一下調整服事比例（100% → 75% → 50% → 25% → 10% → 5% → 0%；0% 是不自動排）',
                      onPressed: isGroupRole(role)
                          ? null
                          : () => _cycleRatio(role, name),
                      onDeleted: () =>
                          setState(() => _pool[role]!.remove(name)),
                      deleteButtonTooltipMessage: '從名單拿掉',
                    ),
                  if (_pool[role]!.isEmpty)
                    Text(
                      '還沒有人',
                      style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputs[role],
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: isGroupRole(role)
                            ? '新增小組（輸入小組名稱後按 Enter）'
                            : '新增同工（輸入名字後按 Enter）',
                      ),
                      onSubmitted: (_) => _add(role),
                    ),
                  ),
                  IconButton(
                    tooltip: '新增',
                    icon: const Icon(Icons.person_add_alt_1_outlined),
                    onPressed: () => _add(role),
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
          onPressed: () =>
              Navigator.pop(context, StaffPool(_pool, _families, _ratios)),
          child: const Text('儲存名單'),
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
