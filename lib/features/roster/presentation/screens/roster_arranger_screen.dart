import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:church_staff_pwa/core/time/church_time.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import '../../../../core/utils/error_messages.dart';
import '../../../../core/widgets/empty_state.dart';
import '../../domain/entities/service_roster.dart';
import '../../domain/roster_schedule.dart';
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
  String? _error;
  bool _creating = false;

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
      setState(() => _rosters = all.where((r) => r.type == _type).toList());
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
