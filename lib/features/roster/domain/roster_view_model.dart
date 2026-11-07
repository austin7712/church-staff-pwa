import '../../../core/types/service_type.dart';
import 'entities/service_roster.dart';
import 'role_names.dart';

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
  return rosterNameMatchesUser(trimmed, userName);
}

/// 服事表上的名字是不是這位同工。服事表常只寫名字（「Austin」），帳號
/// 上是全名（「Austin Lin」），所以名字等於全名的第一個字也算。
bool rosterNameMatchesUser(String rosterName, String? userName) {
  final n = rosterName.trim().toLowerCase();
  final full = userName?.trim().toLowerCase() ?? '';
  if (n.isEmpty || full.isEmpty) return false;
  if (n == full) return true;
  final first = full.split(RegExp(r'\s+')).first;
  return !n.contains(' ') && first.length > 1 && n == first;
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

/// 收起來的卡片上要顯示的重點：講員與敬拜。
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
  final worshipRole = roster.duties
      .map((d) => d.role)
      .firstWhere((r) => r.startsWith('敬拜'), orElse: () => '');
  final worship = worshipRole.isEmpty ? const <String>[] : peopleOf(worshipRole);
  return [
    if (speakers.isNotEmpty) '講員 ${speakers.join('・')}',
    if (worship.isNotEmpty) '$worshipRole ${worship.join('、')}',
  ].join('　｜　');
}

/// 表格欄標題：照服事項目設定的名稱，不自己縮寫。
String shortRoleHeader(String role) => role;

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
  Set<String>? onlyRoles,
  Set<String> exceptRoles = const {},
}) {
  bool isSpeaker(String role) =>
      role == kTwSpeakerRole || role == kMwSpeakerRole;
  bool allowed(String role) =>
      (onlyRoles == null || onlyRoles.contains(role)) &&
      !exceptRoles.contains(role);
  final hasLanes =
      alwaysShowRoles.any((r) => isSpeaker(r) && allowed(r)) ||
      rosters.any(
        (r) => r.duties.any(
          (d) => isSpeaker(d.role) && allowed(d.role) && d.people.isNotEmpty,
        ),
      );

  final otherRoles = <String>[
    for (final role in alwaysShowRoles)
      if (!isSpeaker(role) && allowed(role)) role,
  ];
  for (final r in rosters) {
    for (final d in r.duties) {
      if (d.people.isEmpty || !allowed(d.role)) continue;
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
  final rolesByPerson = <String, List<String>>{};
  for (final duty in roster.duties) {
    for (final person in duty.people.map((p) => p.trim()).toSet()) {
      if (person.isEmpty || isPlaceholderPerson(person)) continue;
      rolesByPerson.putIfAbsent(person, () => []).add(duty.role);
    }
  }
  return {
    for (final MapEntry(key: person, value: roles) in rolesByPerson.entries)
      if ([
        for (var i = 0; i < roles.length; i++)
          for (var j = i + 1; j < roles.length; j++)
            rolesCanShare(roles[i], roles[j]),
      ].contains(false))
        person,
  };
}

/// 同一天同一個人可以同時做的兩項服事（教會的規則）：
/// - 奉獻點算是聚會後另外做的，跟哪一項都不衝突。
/// - 聖餐長老與司會報告可以是同一位。
/// - 同一位講員台語、華語都講（兩堂各講一次）。
/// 其他項目同一天只能排一項。
bool rolesCanShare(String a, String b) {
  final x = canonicalRole(a);
  final y = canonicalRole(b);
  if (x == y) return false;
  if (x == '奉獻點算' || y == '奉獻點算') return true;
  final pair = {x, y};
  if (pair.containsAll(const ['聖餐長老', '司會報告'])) return true;
  if (pair.containsAll(const [kTwSpeakerRole, kMwSpeakerRole])) return true;
  return false;
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

/// 每個人服事的天數：同一天兼好幾項只算一天（不同聚會同一天也算一天）。
Map<String, int> serviceDays(List<ServiceRoster> rosters) {
  final days = <String, Set<String>>{};
  for (final roster in rosters) {
    final day = '${roster.date.year}-${roster.date.month}-${roster.date.day}';
    for (final duty in roster.duties) {
      for (final person in duty.people.map((p) => p.trim())) {
        if (person.isEmpty || isPlaceholderPerson(person)) continue;
        days.putIfAbsent(person, () => {}).add(day);
      }
    }
  }
  return {for (final e in days.entries) e.key: e.value.length};
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

/// 服事項目已經全部包含在另一個聚會裡的聚會（例如「兒童主日」的項目也在
/// 主日崇拜裡）：child → 包含它的聚會。這種聚會的分頁只是主日崇拜資料
/// 的一部分，不另外排。
Map<String, String> coveringServices(Map<String, List<String>> templates) {
  final result = <String, String>{};
  for (final MapEntry(key: child, value: roles) in templates.entries) {
    if (roles.isEmpty) continue;
    String? best;
    for (final MapEntry(key: other, value: otherRoles) in templates.entries) {
      if (other == child || otherRoles.length <= roles.length) continue;
      if (!roles.every(otherRoles.contains)) continue;
      if (best == null || otherRoles.length > templates[best]!.length) {
        best = other;
      }
    }
    if (best != null) result[child] = best;
  }
  return result;
}

/// 只留下某些服事項目（分頁只看兒童主日時用）。
List<ServiceRoster> rostersWithRoles(
  List<ServiceRoster> rosters, {
  Set<String>? only,
  Set<String> except = const {},
}) => [
  for (final r in rosters)
    r.copyWith(
      duties: [
        for (final d in r.duties)
          if ((only == null || only.contains(d.role)) &&
              !except.contains(d.role))
            d,
      ],
    ),
];

/// 服事表的一個分頁。
///
/// 主日崇拜已經包含兒童主日、幼兒主日、愛餐整理時：「總覽」就是主日崇拜的
/// 全部項目；「主日」只看崇拜本身的項目；「兒童主日」等分頁只看那幾項。
/// 資料都是同一份主日崇拜服事表，只是看的欄位不同。
class RosterTabSpec {
  const RosterTabSpec({
    required this.label,
    required this.types,
    this.isOverview = false,
    this.onlyRoles,
    this.exceptRoles = const {},
  });

  final String label;

  /// 這一頁讀哪些聚會的服事表（總覽可能好幾個，其他分頁一個）。
  final List<ServiceType> types;
  final bool isOverview;
  final Set<String>? onlyRoles;
  final Set<String> exceptRoles;

  ServiceType get type => types.first;
  bool get isFiltered => onlyRoles != null || exceptRoles.isNotEmpty;
}

List<RosterTabSpec> rosterTabs(
  List<ServiceType> visible,
  Map<ServiceType, List<String>> templates,
) {
  final cover = coveringServices({
    for (final t in visible) t.name: templates[t] ?? const <String>[],
  });
  final byName = {for (final t in visible) t.name: t};
  final roots = [
    for (final t in visible)
      if (cover[t.name] == null) t,
  ];
  final children = <ServiceType, List<ServiceType>>{
    for (final r in roots) r: [],
  };
  for (final MapEntry(key: child, value: parent) in cover.entries) {
    final p = byName[parent];
    final c = byName[child];
    if (p != null && c != null) children[p]?.add(c);
  }
  final anyChildren = children.values.any((c) => c.isNotEmpty);
  final showOverview = roots.length > 1 || anyChildren;
  return [
    if (showOverview)
      RosterTabSpec(label: '總覽', types: roots, isOverview: true),
    for (final root in roots) ...[
      RosterTabSpec(
        label: root.label,
        types: [root],
        exceptRoles: {
          for (final c in children[root]!) ...?templates[c],
        },
      ),
      for (final c in children[root]!)
        RosterTabSpec(
          label: c.label,
          types: [root],
          onlyRoles: {...?templates[c]},
        ),
    ],
  ];
}
