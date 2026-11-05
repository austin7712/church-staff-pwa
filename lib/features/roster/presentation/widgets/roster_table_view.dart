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
  });

  final List<ServiceRoster> rosters;
  final String? userId;
  final String? userName;
  final ScrollController? controller;

  static const _divider = Color(0xFFE3E7ED);
  static const _dayDivider = Color(0xFFC9D1DB);

  @override
  Widget build(BuildContext context) {
    final model = buildRosterTable(rosters, userId: userId, userName: userName);
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
            for (final cell in row.cells)
              Padding(
                padding: vPad,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [for (final p in cell) _NameTag(cell: p)],
                ),
              ),
          ],
        ),
      );
    }

    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      children: [
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
        if (model.hasLanes)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text(
              '每週分「台」「華」兩行：講員各自對應，其他服事都是華語同工；'
              '聯合崇拜只有一場，合併成一行（「合」）。',
              style: TextStyle(fontSize: 12, color: muted, height: 1.5),
            ),
          ),
      ],
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
  const _NameTag({required this.cell});

  final RosterTableCell cell;

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
