import 'package:flutter/material.dart';

import '../../domain/entities/service_roster.dart';
import '../../domain/roster_view_model.dart';
import 'roster_view_colors.dart';

/// 服事表的「表格」檢視：像紙本服事表一樣整季攤開。
///
/// 手機寬度也要一頁看完、不用左右滑：欄標題縮成兩個字、名字一人一行、
/// 整段期間沒人排的欄位不出現（排法見 [buildRosterTable]）。
class RosterTableView extends StatelessWidget {
  const RosterTableView({
    super.key,
    required this.rosters,
    this.userId,
    this.userName,
    this.controller,
    this.onCellTap,
    this.alwaysShowRoles = const [],
    this.showCounts = false,
    this.roleOrder = const [],
    this.embedded = false,
  });

  /// 放在別的清單裡（總覽一頁疊好幾張表）時不自己捲動。
  final bool embedded;

  final List<ServiceRoster> rosters;
  final String? userId;
  final String? userName;
  final ScrollController? controller;

  /// 給了就是「編輯表格」：每一格都可以點，空格顯示「＋」，同一天重複排到
  /// 的人標紅。由編輯模式提供（選人視窗在那邊）。
  final void Function(RosterTableRow row, RosterTableColumn column)? onCellTap;

  /// 編輯時沒人排也要顯示的服事項目（服事項目設定裡的清單）。
  final List<String> alwaysShowRoles;

  /// 表格下方列出這段期間每個人排了幾次。
  final bool showCounts;

  /// 欄位順序（服事項目設定的順序）。
  final List<String> roleOrder;

  bool get _editing => onCellTap != null;

  static const _divider = Color(0xFFE3E7ED);
  static const _dayDivider = Color(0xFFC9D1DB);

  @override
  Widget build(BuildContext context) {
    final model = buildRosterTable(
      rosters,
      userId: userId,
      userName: userName,
      alwaysShowRoles: alwaysShowRoles,
      editing: _editing,
      roleOrder: roleOrder.isEmpty ? alwaysShowRoles : roleOrder,
    );
    final muted = Colors.grey[700]!;

    final widths = <int, TableColumnWidth>{
      0: const FixedColumnWidth(42),
      if (model.hasLanes) 1: const FixedColumnWidth(18),
    };
    final firstRoleCol = model.hasLanes ? 2 : 1;
    for (var i = 0; i < model.columns.length; i++) {
      widths[firstRoleCol + i] = const FlexColumnWidth();
    }

    Widget header(String text) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: muted,
        ),
      ),
    );

    final rows = <TableRow>[
      TableRow(
        decoration: const BoxDecoration(
          color: Color(0xFFF4F6F9),
          border: Border(bottom: BorderSide(color: _divider)),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: header('日期'),
          ),
          if (model.hasLanes) const SizedBox.shrink(),
          for (final c in model.columns) header(c.header),
        ],
      ),
    ];

    for (final row in model.rows) {
      final combined = isCombinedService(row.roster);
      final bg = combined ? kRosterCombinedFill : Colors.white;
      final bottom = row.isLastOfDay
          ? const BorderSide(color: _dayDivider)
          : const BorderSide(color: _divider, width: 0.5);
      final vPad = EdgeInsets.fromLTRB(
        2,
        row.isFirstOfDay ? 6 : 3,
        2,
        row.isLastOfDay ? 6 : 3,
      );

      rows.add(
        TableRow(
          decoration: BoxDecoration(
            color: bg,
            border: Border(bottom: bottom),
          ),
          children: [
            Padding(
              padding: vPad.copyWith(left: 6),
              child: row.isFirstOfDay
                  ? _DateCell(roster: row.roster, combined: combined)
                  : const SizedBox.shrink(),
            ),
            if (model.hasLanes)
              Padding(
                padding: vPad,
                child: Text(
                  row.lane ?? '',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: switch (row.lane) {
                      '台' => kRosterLaneTw,
                      '合' => kRosterCombinedText,
                      _ => kRosterLaneMw,
                    },
                  ),
                ),
              ),
            for (var c = 0; c < row.cells.length; c++)
              _cellWidget(
                context,
                row: row,
                column: model.columns[c],
                cell: row.cells[c],
                padding: vPad,
              ),
          ],
        ),
      );
    }

    final children = <Widget>[
        Card(
          margin: EdgeInsets.zero,
          elevation: 1,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: _divider),
          ),
          child: Table(
            columnWidths: widths,
            defaultVerticalAlignment: TableCellVerticalAlignment.top,
            children: rows,
          ),
        ),
        if (_editing)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text(
              '點任何一格就能修改。紅框＝同一天排了兩項以上（只是提醒，不會擋）。',
              style: TextStyle(fontSize: 12, color: muted, height: 1.5),
            ),
          ),
        if (model.hasLanes)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text(
              '每週分「台」「華」兩行：講員各自對應，其他服事都是華語同工；'
              '聯合崇拜只有一場，合併成一行（「合」）。',
              style: TextStyle(fontSize: 12, color: muted, height: 1.5),
            ),
          ),
        if (showCounts) _CountsCard(rosters: rosters),
    ];
    if (embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      children: children,
    );
  }

  Widget _cellWidget(
    BuildContext context, {
    required RosterTableRow row,
    required RosterTableColumn column,
    required List<RosterTableCell> cell,
    required EdgeInsets padding,
  }) {
    final content = Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final p in cell) _NameTag(cell: p, showConflict: _editing),
          // 空格給一個「＋」，看得出來可以點。「台」行講員以外的格子是空的
          // 但點了改的是同一項服事（放在「華」行），就不放「＋」以免重複。
          if (_editing &&
              cell.isEmpty &&
              (column.roles.length == 2 || row.lane != '台'))
            Text(
              '＋',
              style: TextStyle(fontSize: 14, color: Colors.grey[500]),
            ),
        ],
      ),
    );
    if (!_editing) return content;
    return InkWell(
      onTap: () => onCellTap!(row, column),
      child: ConstrainedBox(
        // 空格也要夠高才好點。
        constraints: const BoxConstraints(minHeight: 32),
        child: content,
      ),
    );
  }
}

/// 每個人這段期間排了幾次，幫安排的人平均分配。
class _CountsCard extends StatelessWidget {
  const _CountsCard({required this.rosters});

  final List<ServiceRoster> rosters;

  @override
  Widget build(BuildContext context) {
    final counts = serviceCounts(rosters);
    if (counts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: RosterTableView._divider),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '服事次數（這段期間）',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final entry in counts)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: kRosterPlaceholderFill,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${entry.key} ${entry.value}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DateCell extends StatelessWidget {
  const _DateCell({required this.roster, required this.combined});

  final ServiceRoster roster;
  final bool combined;

  @override
  Widget build(BuildContext context) {
    final special = combined
        ? '聯合'
        : roster.specialEvents.isEmpty
        ? null
        : roster.specialEvents.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${roster.date.month}/${roster.date.day}',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
        ),
        if (special != null)
          Text(
            special,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: combined ? kRosterCombinedText : const Color(0xFF4A2F7A),
            ),
          ),
      ],
    );
  }
}

class _NameTag extends StatelessWidget {
  const _NameTag({required this.cell, this.showConflict = false});

  final RosterTableCell cell;
  final bool showConflict;

  @override
  Widget build(BuildContext context) {
    final Color? fill;
    final Color text;
    final FontWeight weight;
    Border? border;
    if (cell.isMe) {
      fill = kRosterMeFill;
      text = kRosterMeText;
      weight = FontWeight.bold;
      border = Border.all(color: kRosterMeBorder, width: 1.5);
    } else if (cell.isPlaceholder) {
      fill = kRosterPlaceholderFill;
      text = kRosterPlaceholderText;
      weight = FontWeight.normal;
    } else {
      fill = null;
      text = const Color(0xFF1B2430);
      weight = FontWeight.normal;
    }
    if (showConflict && cell.isConflict) {
      border = Border.all(color: kRosterConflict, width: 1.5);
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(4),
        border: border,
      ),
      child: Text(
        cell.text,
        softWrap: true,
        style: TextStyle(
          fontSize: 12,
          height: 1.3,
          letterSpacing: -0.1,
          color: text,
          fontWeight: weight,
        ),
      ),
    );
  }
}
