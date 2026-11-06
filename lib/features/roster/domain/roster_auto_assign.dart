import 'entities/service_roster.dart';
import 'role_names.dart';
import 'roster_view_model.dart';
import 'staff_directory.dart';

/// 「一鍵安排」：依照歷史服事表，把還沒排的格子公平地填上人。
///
/// 規則（排班同工訂的）：
/// - 只填空格（沒有人或只有「待定」）；已經排好的不動。講員不排。
/// - 不跨事工：一項服事只從 [eligible] 裡挑，預設是「這一項做過 2 次以上」
///   的人，安排者可以再勾選其他人（例如請產假剛回來的同工）。
/// - 公平：以這次排的期間為準，同一項服事裡大家從 0 開始輪，次數最少的先排；
///   次數一樣時，最久沒排到這一項的先排。
/// - 同一天不重複排同一個人（不同聚會也算）；盡量不連續兩週排同一項。
/// - 特殊週照歷史：聯合崇拜（台語主領）歷史上只排收奉，其他項是「台語」；
///   聖餐只在有「聖餐」的週排。歷史上一項在這種週通常排幾個人就排幾個。

/// 某人在某一項服事的歷史次數（不含佔位字）。role → person → 次數。
Map<String, Map<String, int>> roleHistoryCounts(
  Iterable<ServiceRoster> rosters,
) {
  final counts = <String, Map<String, int>>{};
  for (final roster in rosters) {
    for (final duty in roster.duties) {
      for (final person in duty.people.map((p) => p.trim()).toSet()) {
        if (person.isEmpty || isPlaceholderPerson(person)) continue;
        final byPerson = counts.putIfAbsent(duty.role, () => {});
        byPerson[person] = (byPerson[person] ?? 0) + 1;
      }
    }
  }
  return counts;
}

/// 預設可排的人：做過 [minTimes] 次以上。
Map<String, Set<String>> defaultEligible(
  Map<String, Map<String, int>> counts, {
  int minTimes = 2,
}) {
  return {
    for (final MapEntry(key: role, value: byPerson) in counts.entries)
      role: {
        for (final MapEntry(key: person, value: n) in byPerson.entries)
          if (n >= minTimes) person,
      },
  };
}

/// 一格要填什麼：幾個人，或直接寫「台語」。
class _Need {
  const _Need.people(this.count) : taiwanese = false;
  const _Need.taiwanese() : count = 0, taiwanese = true;

  final int count;
  final bool taiwanese;
}

/// 這一週屬於哪一種：一般、台語主領聯合、華語主領聯合。聖餐另外看。
String _weekKind(ServiceRoster roster) {
  for (final e in roster.specialEvents) {
    if (!e.contains('聯合')) continue;
    if (e.contains('台語')) return 'tw';
    if (e.contains('華語')) return 'mw';
    return 'combined';
  }
  return 'normal';
}

bool _hasCommunion(ServiceRoster roster) =>
    roster.specialEvents.any((e) => e.contains('聖餐'));

bool _isCommunionRole(String role) => role.contains('聖餐');

String _patternKey(ServiceRoster roster, String role) {
  final kind = _weekKind(roster);
  if (!_isCommunionRole(role)) return kind;
  return '$kind/${_hasCommunion(roster) ? 'c' : '-'}';
}

String _fallbackKey(ServiceRoster roster, String role) {
  if (!_isCommunionRole(role)) return 'normal';
  return 'normal/${_hasCommunion(roster) ? 'c' : '-'}';
}

class _PatternStats {
  int weeks = 0;
  int filled = 0;
  int taiwanese = 0;
  final Map<int, int> headcounts = {};

  _Need? decide() {
    if (weeks == 0) return null;
    if (filled * 2 >= weeks) {
      // 最常見的人數；一樣多時取多的那個（寧可多排一位）。
      var best = 1;
      var bestFreq = -1;
      headcounts.forEach((n, freq) {
        if (freq > bestFreq || (freq == bestFreq && n > best)) {
          best = n;
          bestFreq = freq;
        }
      });
      return _Need.people(best);
    }
    if (taiwanese * 2 >= weeks) return const _Need.taiwanese();
    return const _Need.people(0);
  }
}

Map<String, Map<String, _PatternStats>> _learnPatterns(
  Iterable<ServiceRoster> history,
) {
  final patterns = <String, Map<String, _PatternStats>>{};
  for (final roster in history) {
    for (final duty in roster.duties) {
      final key = _patternKey(roster, duty.role);
      final stats = patterns
          .putIfAbsent(duty.role, () => {})
          .putIfAbsent(key, _PatternStats.new);
      stats.weeks++;
      final real = duty.people
          .map((p) => p.trim())
          .where((p) => p.isNotEmpty && !isPlaceholderPerson(p))
          .toSet()
          .length;
      if (real > 0) {
        stats.filled++;
        stats.headcounts[real] = (stats.headcounts[real] ?? 0) + 1;
      } else if (duty.people.any((p) => p.trim() == kTaiwanesePlaceholder)) {
        stats.taiwanese++;
      }
    }
  }
  return patterns;
}

bool _needsFilling(RosterEntry duty) =>
    duty.people.every((p) => p.trim().isEmpty || p.trim() == placeholderPerson);

/// 一格的安排結果（給預覽畫面看）。
class AutoAssignment {
  const AutoAssignment({
    required this.roster,
    required this.role,
    required this.people,
  });

  final ServiceRoster roster;
  final String role;
  final List<String> people;
}

class AutoAssignResult {
  const AutoAssignResult({
    required this.updated,
    required this.assignments,
    required this.shortfalls,
  });

  /// 有改到的服事表（新版本）。
  final List<ServiceRoster> updated;
  final List<AutoAssignment> assignments;

  /// 人不夠、只排到一部分的格子。
  final List<AutoAssignment> shortfalls;
}

/// 一鍵安排。
///
/// [targets]：要排的這段期間（同一個聚會），照日期排好。
/// [history]：這段期間以前的服事表（同一個聚會），用來學「特殊週排幾個人」
/// 與「誰最近才排過」。
/// [sameDayOthers]：同一段期間其他聚會的服事表，避免同一天排到同一個人。
AutoAssignResult autoAssign({
  required List<ServiceRoster> targets,
  required List<ServiceRoster> history,
  required Map<String, Set<String>> eligible,
  List<ServiceRoster> sameDayOthers = const [],
  Set<String> skipRoles = const {kTwSpeakerRole, kMwSpeakerRole},
  Map<String, List<String>> groupRoles = const {},
  List<String> templateRoles = const [],
  Map<String, int> consecutiveWeeks = const {},
  List<List<String>> families = const [],
}) {
  // 夫妻、家人：一起出席一起缺席，盡量排在同一天。名字不分大小寫。
  final familyOf = <String, Set<String>>{};
  for (final f in families) {
    final members = {for (final m in f) m.trim().toLowerCase()}..remove('');
    for (final m in members) {
      familyOf.putIfAbsent(m, () => {}).addAll(members.difference({m}));
    }
  }
  // 這次期間每個人所有項目加起來的次數（次數相同時，總次數少的先排）。
  final planTotals = <String, int>{};
  // 要連續排幾週的項目（例如幼兒主日老師連兩週）：目前這一輪是誰、還剩幾週。
  final streak = <String, ({List<String> people, int left})>{};
  final patterns = _learnPatterns(history);
  final monthGroups = {
    for (final MapEntry(key: role, value: groups) in groupRoles.entries)
      if (groups.isNotEmpty)
        role: monthlyGroupRotation(
          targets: targets,
          history: history,
          role: role,
          groups: groups,
        ),
  };

  String dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  // 這次期間裡每項服事每個人的次數（從 0 開始，含已經排好的）。
  final planCounts = <String, Map<String, int>>{};
  // 每項服事每個人最後一次排到的日期（歷史＋這次）。
  final lastServed = <String, Map<String, DateTime>>{};
  // 每一天已經有服事的人，和他那天排了哪些項目。
  final busy = <String, Map<String, Set<String>>>{};

  void record(String role, String person, DateTime date, {bool count = true}) {
    if (count) {
      final byPerson = planCounts.putIfAbsent(role, () => {});
      byPerson[person] = (byPerson[person] ?? 0) + 1;
      planTotals[person] = (planTotals[person] ?? 0) + 1;
    }
    final last = lastServed.putIfAbsent(role, () => {});
    final prev = last[person];
    if (prev == null || date.isAfter(prev)) last[person] = date;
  }

  for (final roster in history) {
    for (final duty in roster.duties) {
      for (final p in duty.people) {
        final name = p.trim();
        if (name.isEmpty || isPlaceholderPerson(name)) continue;
        record(duty.role, name, roster.date, count: false);
      }
    }
  }
  for (final roster in [...targets, ...sameDayOthers]) {
    for (final duty in roster.duties) {
      for (final p in duty.people) {
        final name = p.trim();
        if (name.isEmpty || isPlaceholderPerson(name)) continue;
        busy
            .putIfAbsent(dayKey(roster.date), () => {})
            .putIfAbsent(name, () => {})
            .add(duty.role);
        if (targets.contains(roster)) record(duty.role, name, roster.date);
      }
    }
  }

  final updated = <ServiceRoster>[];
  final assignments = <AutoAssignment>[];
  final shortfalls = <AutoAssignment>[];

  final sorted = [...targets]..sort((a, b) => a.date.compareTo(b.date));
  final communion = communionWeeks(sorted);
  for (var roster in sorted) {
    final day = dayKey(roster.date);
    final dayBusy = busy.putIfAbsent(day, () => {});
    var changed = false;
    final duties = <RosterEntry>[];
    final month = _monthKey(roster.date);
    // 服事項目設定裡有、這一週卻還沒有的項目（建立空白週次之後才加的項目，
    // 例如幼兒主日）：補上「待定」再排。
    final missing = <String>[
      for (final role in {...templateRoles, ...monthGroups.keys})
        if (!skipRoles.contains(role) &&
            !roster.duties.any((d) => d.role == role))
          role,
    ];
    if (missing.isNotEmpty) {
      roster = roster.copyWith(
        duties: [
          ...roster.duties,
          for (final role in missing)
            RosterEntry(role: role, people: const [kTbdPlaceholder]),
        ],
      );
    }
    for (final duty in roster.duties) {
      final byMonth = monthGroups[duty.role];
      if (byMonth != null) {
        final group = byMonth[month];
        if (group == null || !_needsFilling(duty)) {
          duties.add(duty);
          continue;
        }
        duties.add(duty.copyWith(people: [group], personIdsByName: const {}));
        changed = true;
        assignments.add(
          AutoAssignment(roster: roster, role: duty.role, people: [group]),
        );
        continue;
      }
      if (skipRoles.contains(duty.role) || !_needsFilling(duty)) {
        final weeks = consecutiveWeeks[duty.role] ?? 1;
        if (weeks > 1 && !skipRoles.contains(duty.role)) {
          // 已經排好的週也算進這一輪。
          final people = [
            for (final p in duty.people)
              if (!isPlaceholderPerson(p.trim()) && p.trim().isNotEmpty)
                p.trim(),
          ];
          if (people.isNotEmpty) {
            final cur = streak[duty.role];
            final same =
                cur != null &&
                cur.left > 0 &&
                cur.people.length == people.length &&
                cur.people.every(people.contains);
            streak[duty.role] = same
                ? (people: people, left: cur.left - 1)
                : (people: people, left: weeks - 1);
          }
        }
        duties.add(duty);
        continue;
      }
      // 還沒標「聖餐」的空白週（例如整年的空白表）：每個月第一個主日當聖餐週。
      final view = communion.contains(roster.id) && !_hasCommunion(roster)
          ? roster.copyWith(specialEvents: [...roster.specialEvents, '聖餐'])
          : roster;
      final stats =
          patterns[duty.role]?[_patternKey(view, duty.role)] ??
          patterns[duty.role]?[_fallbackKey(view, duty.role)];
      // 沒有歷史可以學（新加的服事，例如兒童主日）：名單上有人就每週排一位；
      // 聖餐類只在聖餐週排。
      final hasPool = (eligible[duty.role] ?? const <String>{}).isNotEmpty;
      final need =
          stats?.decide() ??
          (hasPool &&
                  (!_isCommunionRole(duty.role) || _hasCommunion(view))
              ? const _Need.people(1)
              : null);
      if (need == null || (!need.taiwanese && need.count == 0)) {
        duties.add(duty);
        continue;
      }
      if (need.taiwanese) {
        final filled = duty.copyWith(
          people: const [kTaiwanesePlaceholder],
          personIdsByName: const {},
        );
        duties.add(filled);
        changed = true;
        continue;
      }

      final counts = planCounts[duty.role] ?? const <String, int>{};
      final last = lastServed[duty.role] ?? const <String, DateTime>{};
      final lastWeek = roster.date.subtract(const Duration(days: 7));
      bool familyHere(String p) =>
          (familyOf[p.toLowerCase()] ?? const <String>{}).any(
            (f) => dayBusy.keys.any((b) => b.toLowerCase() == f),
          );
      bool servedLastWeek(String p) {
        final d = last[p];
        return d != null && dayKey(d) == dayKey(lastWeek);
      }

      final candidates =
          (eligible[duty.role] ?? const <String>{})
              .where(
                (p) => (dayBusy[p] ?? const <String>{}).every(
                  (other) => rolesCanShare(other, duty.role),
                ),
              )
              .toList()
            ..sort((a, b) {
              // 同一項的次數＋所有項目的總次數一起看：兼很多項的人（例如
              // 同時在音控、司會、奉獻、兒童主日名單上）不會每一項都排到
              // 跟別人一樣多，總量才不會比別人高出一大截。
              // 家人當天已經有服事的，可以比別人多排一次（一起出席）。
              int score(String p) =>
                  (counts[p] ?? 0) +
                  (planTotals[p] ?? 0) -
                  (familyHere(p) ? 1 : 0);
              final byCount = score(a).compareTo(score(b));
              if (byCount != 0) return byCount;
              final byFamily = (familyHere(b) ? 1 : 0).compareTo(
                familyHere(a) ? 1 : 0,
              );
              if (byFamily != 0) return byFamily;
              final byTotal = (planTotals[a] ?? 0).compareTo(
                planTotals[b] ?? 0,
              );
              if (byTotal != 0) return byTotal;
              final byStreak = (servedLastWeek(a) ? 1 : 0).compareTo(
                servedLastWeek(b) ? 1 : 0,
              );
              if (byStreak != 0) return byStreak;
              final la = last[a];
              final lb = last[b];
              if (la == null && lb != null) return -1;
              if (lb == null && la != null) return 1;
              if (la != null && lb != null) {
                final byLast = la.compareTo(lb);
                if (byLast != 0) return byLast;
              }
              return a.compareTo(b);
            });

      final weeks = consecutiveWeeks[duty.role] ?? 1;
      final cur = streak[duty.role];
      final keep =
          weeks > 1 &&
          cur != null &&
          cur.left > 0 &&
          cur.people.length == need.count &&
          cur.people.every(candidates.contains);
      final picked = keep
          ? List<String>.from(cur.people)
          : candidates.take(need.count).toList();
      if (weeks > 1 && picked.isNotEmpty) {
        streak[duty.role] = keep
            ? (people: picked, left: cur.left - 1)
            : (people: picked, left: weeks - 1);
      }
      if (picked.isEmpty) {
        duties.add(duty);
        shortfalls.add(
          AutoAssignment(roster: roster, role: duty.role, people: const []),
        );
        continue;
      }
      for (final p in picked) {
        record(duty.role, p, roster.date);
        dayBusy.putIfAbsent(p, () => {}).add(duty.role);
      }
      duties.add(duty.copyWith(people: picked, personIdsByName: const {}));
      changed = true;
      final assignment = AutoAssignment(
        roster: roster,
        role: duty.role,
        people: picked,
      );
      assignments.add(assignment);
      if (picked.length < need.count) shortfalls.add(assignment);
    }
    if (changed) updated.add(roster.copyWith(duties: duties));
  }

  return AutoAssignResult(
    updated: updated,
    assignments: assignments,
    shortfalls: shortfalls,
  );
}

/// 聖餐週：有標「聖餐」的週；一整個月都沒標的話，就用那個月的第一個主日
/// （教會平常的習慣）。回傳服事表 id。
Set<String> communionWeeks(List<ServiceRoster> rosters) {
  final byMonth = <String, List<ServiceRoster>>{};
  for (final r in rosters) {
    byMonth.putIfAbsent(_monthKey(r.date), () => []).add(r);
  }
  final result = <String>{};
  for (final month in byMonth.values) {
    final marked = month.where(_hasCommunion).toList();
    if (marked.isNotEmpty) {
      result.addAll(marked.map((r) => r.id));
    } else {
      final first = month.reduce((a, b) => a.date.isBefore(b.date) ? a : b);
      if (first.date.day <= 7) result.add(first.id);
    }
  }
  return result;
}

String _monthKey(DateTime d) => '${d.year}-${d.month}';

/// 以小組為單位的服事：每個月一組，照 [groups] 的順序輪。
///
/// 接著歷史上最後一個月的那一組往下輪；這次期間裡某個月已經有人填了
/// 某一組，那個月就是那一組，後面的月份從它接著輪。回傳 "年-月" → 小組。
Map<String, String> monthlyGroupRotation({
  required List<ServiceRoster> targets,
  required List<ServiceRoster> history,
  required String role,
  required List<String> groups,
}) {
  String? groupOf(ServiceRoster r) {
    for (final d in r.duties) {
      if (d.role != role) continue;
      for (final p in d.people) {
        if (groups.contains(p.trim())) return p.trim();
      }
    }
    return null;
  }

  var index = -1;
  String? lastMonth;
  final past = [...history]..sort((a, b) => a.date.compareTo(b.date));
  for (final r in past) {
    final g = groupOf(r);
    if (g == null) continue;
    index = groups.indexOf(g);
    lastMonth = _monthKey(r.date);
  }

  final fixed = <String, String>{};
  for (final r in targets) {
    final g = groupOf(r);
    if (g != null) fixed.putIfAbsent(_monthKey(r.date), () => g);
  }

  final months = <String>[];
  final sorted = [...targets]..sort((a, b) => a.date.compareTo(b.date));
  for (final r in sorted) {
    final m = _monthKey(r.date);
    if (!months.contains(m)) months.add(m);
  }

  final result = <String, String>{};
  for (final m in months) {
    final g = fixed[m];
    if (g != null) {
      index = groups.indexOf(g);
    } else if (m != lastMonth || index < 0) {
      index = (index + 1) % groups.length;
    }
    result[m] = groups[index];
  }
  return result;
}

/// 「一鍵清空」：排好的人改回「待定」，講員不動。只回傳有改到的週次。
List<ServiceRoster> clearAssignments(
  List<ServiceRoster> rosters, {
  Set<String> keepRoles = const {kTwSpeakerRole, kMwSpeakerRole},
}) {
  final result = <ServiceRoster>[];
  for (final r in rosters) {
    var changed = false;
    final duties = [
      for (final d in r.duties)
        if (keepRoles.contains(d.role) || !d.people.any((p) {
          final n = p.trim();
          return n.isNotEmpty && n != kTbdPlaceholder;
        }))
          d
        else
          () {
            changed = true;
            return d.copyWith(
              people: const [kTbdPlaceholder],
              personIdsByName: const {},
            );
          }(),
    ];
    if (changed) result.add(r.copyWith(duties: duties));
  }
  return result;
}

/// 「同工名單」：每項服事可以排哪些人。由安排者維護（加新同工、拿掉不再
/// 服事的人），一鍵安排只從這份名單挑。還沒整理過的服事項目，用今年做過
/// 的人當預設（見 [withDefaults]）。
class StaffPool {
  const StaffPool([this.roles = const {}, this.families = const []]);

  /// 服事項目 → 名單（照安排者排的順序）。
  final Map<String, List<String>> roles;

  /// 夫妻、家人（一起出席一起缺席），一鍵安排盡量排同一天。
  final List<List<String>> families;

  /// 沒有整理過的項目補上預設：今年做過的人，做得多的在前面。
  StaffPool withDefaults(
    Map<String, Map<String, int>> counts,
    Iterable<String> roleNames,
  ) {
    return StaffPool({
      for (final role in roleNames)
        role:
            roles[role] ??
            ((counts[role]?.entries.toList() ?? <MapEntry<String, int>>[])
                  ..sort((a, b) {
                    final byCount = b.value.compareTo(a.value);
                    return byCount != 0 ? byCount : a.key.compareTo(b.key);
                  }))
                .map((e) => e.key)
                .toList(),
    }, families);
  }

  Map<String, Set<String>> get eligible => {
    for (final e in roles.entries) e.key: e.value.toSet(),
  };

  Map<String, dynamic> toJson() => {
    'pool': {for (final e in roles.entries) e.key: e.value},
    // Firestore 不能存陣列裡的陣列，一家一個 map。
    'families': [
      for (final f in families) {'members': f},
    ],
  };

  factory StaffPool.fromJson(Object? json) {
    if (json is! Map) return const StaffPool();
    final rawFamilies = json['families'];
    final families = <List<String>>[
      if (rawFamilies is List)
        for (final f in rawFamilies)
          if (f is Map && f['members'] is List)
            [
              for (final m in f['members'] as List)
                if (m is String && m.trim().isNotEmpty) m.trim(),
            ],
    ].where((f) => f.length > 1).toList();
    final pool = json['pool'];
    if (pool is! Map) return StaffPool(const {}, families);
    return StaffPool({
      for (final e in pool.entries)
        if (e.key is String && e.value is List)
          canonicalRole(e.key as String): [
            for (final v in e.value as List)
              if (v is String && v.trim().isNotEmpty) v.trim(),
          ],
    }, families);
  }
}
