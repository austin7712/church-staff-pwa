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

/// 以小組為單位的服事（愛餐整理）：格子裡寫的是小組名稱，不是個人；
/// 一個月由同一組負責，各組輪流。
bool isGroupRole(String role) => role.trim().startsWith('愛餐');

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
    this.isConflict = false,
  });

  final String text;
  final bool isMe;
  final bool isPlaceholder;

  /// 同一天被排到兩項以上的服事（給安排的人看的提醒，不是錯誤）。
  final bool isConflict;
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
///
/// [alwaysShowRoles]（編輯用）：這些服事項目沒人排也要有一欄，才有地方點。
/// [editing] 為 true 時，講員以外的欄位整格放在「華」行（佔位字也是），
/// 點哪一行都是改同一項服事。
RosterTableModel buildRosterTable(
  List<ServiceRoster> rosters, {
  String? userId,
  String? userName,
  List<String> alwaysShowRoles = const [],
  bool editing = false,
  List<String> roleOrder = const [],
}) {
  bool isSpeaker(String role) =>
      role == kTwSpeakerRole || role == kMwSpeakerRole;
  final hasLanes =
      alwaysShowRoles.any(isSpeaker) ||
      rosters.any(
        (r) => r.duties.any((d) => isSpeaker(d.role) && d.people.isNotEmpty),
      );

  final otherRoles = <String>[
    for (final role in alwaysShowRoles)
      if (!isSpeaker(role)) role,
  ];
  for (final r in rosters) {
    for (final d in r.duties) {
      if (d.people.isEmpty) continue;
      if (d.role == kTwSpeakerRole || d.role == kMwSpeakerRole) continue;
      if (!otherRoles.contains(d.role)) otherRoles.add(d.role);
    }
  }

  sortRolesByOrder(otherRoles, roleOrder);

  final columns = <RosterTableColumn>[
    if (hasLanes)
      const RosterTableColumn(
        header: '講員',
        roles: [kTwSpeakerRole, kMwSpeakerRole],
      ),
    for (final role in otherRoles)
      RosterTableColumn(header: shortRoleHeader(role), roles: [role]),
  ];

  RosterTableCell cell(
    RosterEntry duty,
    String person,
    Set<String> conflicts,
  ) => RosterTableCell(
    text: shortPersonName(person),
    isMe: isPersonMe(duty, person, userId: userId, userName: userName),
    isPlaceholder: isPlaceholderPerson(person),
    isConflict: conflicts.contains(person.trim()),
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
          out.add(cell(duty, person, doubleBookedPeople(roster)));
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
            editing
                ? (_) => !taiwanese
                : (p) => taiwanese
                      ? isPlaceholderPerson(p)
                      : !isPlaceholderPerson(p),
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

/// 同一天被排到兩項以上服事的人（同一項裡重複寫兩次不算）。佔位字不算。
Set<String> doubleBookedPeople(ServiceRoster roster) {
  final seen = <String>{};
  final twice = <String>{};
  for (final duty in roster.duties) {
    for (final person in duty.people.map((p) => p.trim()).toSet()) {
      if (person.isEmpty || isPlaceholderPerson(person)) continue;
      if (!seen.add(person)) twice.add(person);
    }
  }
  return twice;
}

/// 點表格的某一格時，要改的是哪一項服事。
///
/// 講員欄：「台」行改台語講員、「華」行改華語講員；聯合崇拜那一行改已經
/// 排了的那一位（都沒排時預設台語講員）。其他欄就是該欄的服事項目。
String roleForCell(RosterTableRow row, RosterTableColumn column) {
  if (column.roles.length == 1) return column.roles.single;
  switch (row.lane) {
    case '台':
      return kTwSpeakerRole;
    case '華':
      return kMwSpeakerRole;
    default:
      final hasMw = row.roster.duties.any(
        (d) => d.role == kMwSpeakerRole && d.people.isNotEmpty,
      );
      final hasTw = row.roster.duties.any(
        (d) => d.role == kTwSpeakerRole && d.people.isNotEmpty,
      );
      return hasMw && !hasTw ? kMwSpeakerRole : kTwSpeakerRole;
  }
}

/// 這段期間每個人排了幾次（一天排兩項算兩次）。由多到少，同次數依名字排。
List<MapEntry<String, int>> serviceCounts(List<ServiceRoster> rosters) {
  final counts = <String, int>{};
  for (final roster in rosters) {
    for (final duty in roster.duties) {
      for (final person in duty.people.map((p) => p.trim()).toSet()) {
        if (person.isEmpty || isPlaceholderPerson(person)) continue;
        counts[person] = (counts[person] ?? 0) + 1;
      }
    }
  }
  final list = counts.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  return list;
}

/// 照「服事項目設定」的順序排（[order]）。不在設定裡的放最後，保持原本先後。
void sortRolesByOrder(List<String> roles, List<String> order) {
  if (order.isEmpty) return;
  final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
  final original = {for (var i = 0; i < roles.length; i++) roles[i]: i};
  roles.sort((a, b) {
    final ra = rank[a] ?? order.length;
    final rb = rank[b] ?? order.length;
    return ra != rb ? ra.compareTo(rb) : original[a]!.compareTo(original[b]!);
  });
}

/// 卡片上的服事項目也照「服事項目設定」的順序。
List<RosterEntry> dutiesInOrder(List<RosterEntry> duties, List<String> order) {
  if (order.isEmpty) return duties;
  final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
  final indexed = duties.asMap().entries.toList()
    ..sort((a, b) {
      final ra = rank[a.value.role] ?? order.length;
      final rb = rank[b.value.role] ?? order.length;
      return ra != rb ? ra.compareTo(rb) : a.key.compareTo(b.key);
    });
  return [for (final e in indexed) e.value];
}
