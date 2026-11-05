import 'entities/service_roster.dart';

/// 服事表「檢視模式」用到的純邏輯：誰是我、哪些是佔位字、表格怎麼排。
///
/// 刻意不碰 Flutter，才能用單元測試釘住規則（卡片、表格、首頁三處要一致）。

/// 台語堂負責時，服事表上不寫人名，只寫「台語」。
const String kTaiwanesePlaceholder = '台語';

/// 還沒排定的人。
const String kTbdPlaceholder = '待定';

const String kTwSpeakerRole = '台語講員';
const String kMwSpeakerRole = '華語講員';

/// 不是人名、而是佔位用的字（「台語」「待定」）。
bool isPlaceholderPerson(String name) {
  final n = name.trim();
  return n == kTaiwanesePlaceholder || n == kTbdPlaceholder;
}

/// 畫面上顯示的名字：「台語」講清楚是台語堂負責，其他照舊。
String displayPersonName(String name) =>
    name.trim() == kTaiwanesePlaceholder ? '台語堂負責' : name;

/// 表格欄位窄，「台語堂負責」放不下，只寫「台語堂」。
String shortPersonName(String name) =>
    name.trim() == kTaiwanesePlaceholder ? '台語堂' : name;

/// 這一個名字是不是排到這位同工。
///
/// 與首頁「我的服事」同一套規則：uid 對得上就算（改名之後照樣認得），
/// 對不上再退回比對名字（大小寫不拘）。
bool isPersonMe(
  RosterEntry duty,
  String person, {
  String? userId,
  String? userName,
}) {
  final trimmed = person.trim();
  if (trimmed.isEmpty || isPlaceholderPerson(trimmed)) return false;
  final id = userId?.trim() ?? '';
  final linked = duty.personIdsByName[trimmed]?.trim() ?? '';
  if (id.isNotEmpty && linked == id) return true;
  final name = userName?.trim().toLowerCase() ?? '';
  return name.isNotEmpty && trimmed.toLowerCase() == name;
}

/// 這一天排到這位同工的服事項目，照服事表上的順序。
List<String> rolesForUser(
  ServiceRoster roster, {
  String? userId,
  String? userName,
}) {
  return [
    for (final duty in roster.duties)
      if (duty.people.any(
        (p) => isPersonMe(duty, p, userId: userId, userName: userName),
      ))
        duty.role,
  ];
}

/// 這一天排到這位同工的名字（通常一個；同一人綁了不同寫法時可能多個）。
Set<String> namesForUser(
  ServiceRoster roster, {
  String? userId,
  String? userName,
}) {
  return {
    for (final duty in roster.duties)
      for (final p in duty.people)
        if (isPersonMe(duty, p, userId: userId, userName: userName)) p,
  };
}

/// 聯合崇拜（台語堂與華語堂一起）。用特殊事件的名稱判斷。
bool isCombinedService(ServiceRoster roster) =>
    roster.specialEvents.any((e) => e.contains('聯合'));

/// 收起來的卡片上要顯示的重點：講員與敬拜主領。
String rosterSummary(ServiceRoster roster) {
  List<String> peopleOf(String role) => [
    for (final d in roster.duties)
      if (d.role == role)
        for (final p in d.people)
          if (!isPlaceholderPerson(p)) p,
  ];
  final speakers = <String>{
    ...peopleOf(kTwSpeakerRole),
    ...peopleOf(kMwSpeakerRole),
  };
  final worship = peopleOf('敬拜主領');
  return [
    if (speakers.isNotEmpty) '講員 ${speakers.join('・')}',
    if (worship.isNotEmpty) '敬拜 ${worship.join('、')}',
  ].join('　｜　');
}

/// 表格欄標題：欄位窄，長的服事名稱縮成兩個字。
String shortRoleHeader(String role) {
  const known = {
    '敬拜主領': '敬拜',
    '奉獻點算': '奉獻',
    '愛餐整潔': '愛餐',
  };
  final hit = known[role];
  if (hit != null) return hit;
  return role.length > 2 ? role.substring(0, 2) : role;
}

class RosterTableColumn {
  const RosterTableColumn({required this.header, required this.roles});

  final String header;

  /// 這一欄收哪些服事項目。「講員」一欄收台語講員與華語講員。
  final List<String> roles;
}

class RosterTableCell {
  const RosterTableCell({
    required this.text,
    required this.isMe,
    required this.isPlaceholder,
  });

  final String text;
  final bool isMe;
  final bool isPlaceholder;
}

/// 表格的「一行」。一般主日一天兩行（台、華），聯合崇拜一天一行（合）。
class RosterTableRow {
  const RosterTableRow({
    required this.roster,
    required this.lane,
    required this.isFirstOfDay,
    required this.isLastOfDay,
    required this.cells,
  });

  final ServiceRoster roster;

  /// '台'、'華'、'合'；沒有分台華的聚會（例如兒童主日）是 null。
  final String? lane;
  final bool isFirstOfDay;
  final bool isLastOfDay;

  /// 每一欄一串名字，順序與 [RosterTableModel.columns] 相同。
  final List<List<RosterTableCell>> cells;
}

class RosterTableModel {
  const RosterTableModel({
    required this.columns,
    required this.rows,
    required this.hasLanes,
  });

  final List<RosterTableColumn> columns;
  final List<RosterTableRow> rows;

  /// 有沒有「台／華」那一欄。
  final bool hasLanes;
}

/// 把幾週的服事表排成表格。
///
/// 規則（依教會的用法）：
/// - 有台語講員／華語講員的聚會，每天分「台」「華」兩行：講員各歸各的，
///   其他服事都是華語同工，放「華」行；寫著「台語」的佔位放「台」行。
/// - 聯合崇拜只有一場，合併成一行（「合」）。
/// - 整段期間都沒人排的服事項目不出現在表格上。
RosterTableModel buildRosterTable(
  List<ServiceRoster> rosters, {
  String? userId,
  String? userName,
}) {
  final hasLanes = rosters.any(
    (r) => r.duties.any(
      (d) =>
          (d.role == kTwSpeakerRole || d.role == kMwSpeakerRole) &&
          d.people.isNotEmpty,
    ),
  );

  final otherRoles = <String>[];
  for (final r in rosters) {
    for (final d in r.duties) {
      if (d.people.isEmpty) continue;
      if (d.role == kTwSpeakerRole || d.role == kMwSpeakerRole) continue;
      if (!otherRoles.contains(d.role)) otherRoles.add(d.role);
    }
  }

  final columns = <RosterTableColumn>[
    if (hasLanes)
      const RosterTableColumn(
        header: '講員',
        roles: [kTwSpeakerRole, kMwSpeakerRole],
      ),
    for (final role in otherRoles)
      RosterTableColumn(header: shortRoleHeader(role), roles: [role]),
  ];

  RosterTableCell cell(RosterEntry duty, String person) => RosterTableCell(
    text: shortPersonName(person),
    isMe: isPersonMe(duty, person, userId: userId, userName: userName),
    isPlaceholder: isPlaceholderPerson(person),
  );

  List<RosterTableCell> cellsFor(
    ServiceRoster roster,
    List<String> roles,
    bool Function(String person) keep,
  ) {
    final seen = <String>{};
    final out = <RosterTableCell>[];
    for (final role in roles) {
      for (final duty in roster.duties.where((d) => d.role == role)) {
        for (final person in duty.people) {
          if (!keep(person) || !seen.add(person)) continue;
          out.add(cell(duty, person));
        }
      }
    }
    return out;
  }

  final rows = <RosterTableRow>[];
  for (final roster in rosters) {
    if (!hasLanes || isCombinedService(roster)) {
      rows.add(
        RosterTableRow(
          roster: roster,
          lane: hasLanes ? '合' : null,
          isFirstOfDay: true,
          isLastOfDay: true,
          cells: [for (final c in columns) cellsFor(roster, c.roles, (_) => true)],
        ),
      );
      continue;
    }
    List<List<RosterTableCell>> laneCells({required bool taiwanese}) => [
      for (final c in columns)
        if (c.roles.length == 2)
          cellsFor(
            roster,
            [taiwanese ? kTwSpeakerRole : kMwSpeakerRole],
            (_) => true,
          )
        else
          cellsFor(
            roster,
            c.roles,
            (p) => taiwanese ? isPlaceholderPerson(p) : !isPlaceholderPerson(p),
          ),
    ];
    rows
      ..add(
        RosterTableRow(
          roster: roster,
          lane: '台',
          isFirstOfDay: true,
          isLastOfDay: false,
          cells: laneCells(taiwanese: true),
        ),
      )
      ..add(
        RosterTableRow(
          roster: roster,
          lane: '華',
          isFirstOfDay: false,
          isLastOfDay: true,
          cells: laneCells(taiwanese: false),
        ),
      );
  }

  return RosterTableModel(columns: columns, rows: rows, hasLanes: hasLanes);
}
