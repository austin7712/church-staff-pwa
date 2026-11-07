import 'package:church_staff_pwa/core/time/church_time.dart';

import 'entities/service_roster.dart';
import 'role_names.dart';
import 'roster_view_model.dart';
import 'staff_directory.dart';

const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

/// 匯出成試算表的內容：第一列是標題，之後每個聚會日一列。
///
/// 同一天的各個聚會（主日崇拜、兒童主日、愛餐整理…）合併成一列，跟 App
/// 的「總覽」一樣；欄位照「服事項目設定」的順序，沒設定到的項目接在後面。
/// 一格兩人以上用「、」分開。沒排人的格子留白（不寫「待定」）。
List<List<String>> rosterExportRows(
  List<ServiceRoster> rosters, {
  List<String> roleOrder = const [],
}) {
  final byDate = <String, List<ServiceRoster>>{};
  for (final r in rosters) {
    (byDate[ChurchTime.dateKey(r.date)] ??= []).add(r);
  }
  final dates = byDate.keys.toList()..sort();

  final roles = <String>[];
  for (final r in rosters) {
    for (final d in r.duties) {
      final role = canonicalRole(d.role);
      if (!roles.contains(role)) roles.add(role);
    }
  }
  for (final role in roleOrder.map(canonicalRole)) {
    if (!roles.contains(role)) roles.add(role);
  }
  sortRolesByOrder(roles, roleOrder.map(canonicalRole).toList());

  final rows = <List<String>>[
    ['日期', '星期', '特別活動', ...roles],
  ];
  for (final key in dates) {
    final day = byDate[key]!;
    final date = ChurchTime.parseDate(key);
    final events = <String>[
      for (final r in day)
        for (final e in r.specialEvents)
          if (e.trim().isNotEmpty) e.trim(),
    ].toSet().join('、');
    final cells = <String>[];
    for (final role in roles) {
      final people = <String>[
        for (final r in day)
          for (final d in r.duties)
            if (canonicalRole(d.role) == role)
              for (final p in d.people)
                if (p.trim().isNotEmpty && p.trim() != placeholderPerson)
                  p.trim(),
      ].toSet().toList();
      cells.add(people.join('、'));
    }
    rows.add([
      '${date.year}/${date.month}/${date.day}',
      _weekdays[date.weekday - 1],
      events,
      ...cells,
    ]);
  }
  return rows;
}

/// 欄寬（大約字元數）：日期、星期固定，其他看最長的內容，中文算兩格。
List<double> rosterExportWidths(List<List<String>> rows) {
  if (rows.isEmpty) return const [];
  double width(String s) =>
      s.runes.fold<double>(0, (w, c) => w + (c > 0x2E80 ? 2.1 : 1.1));
  return [
    for (var c = 0; c < rows.first.length; c++)
      [
        for (final row in rows)
          if (c < row.length) width(row[c]),
      ].fold<double>(6, (a, b) => b > a ? b : a).clamp(6, 40) + 2,
  ];
}
