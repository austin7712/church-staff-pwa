import 'entities/service_roster.dart';
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
}) {
  final patterns = _learnPatterns(history);

  String dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  // 這次期間裡每項服事每個人的次數（從 0 開始，含已經排好的）。
  final planCounts = <String, Map<String, int>>{};
  // 每項服事每個人最後一次排到的日期（歷史＋這次）。
  final lastServed = <String, Map<String, DateTime>>{};
  // 每一天已經有服事的人。
  final busy = <String, Set<String>>{};

  void record(String role, String person, DateTime date, {bool count = true}) {
    if (count) {
      final byPerson = planCounts.putIfAbsent(role, () => {});
      byPerson[person] = (byPerson[person] ?? 0) + 1;
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
        busy.putIfAbsent(dayKey(roster.date), () => {}).add(name);
        if (targets.contains(roster)) record(duty.role, name, roster.date);
      }
    }
  }

  final updated = <ServiceRoster>[];
  final assignments = <AutoAssignment>[];
  final shortfalls = <AutoAssignment>[];

  final sorted = [...targets]..sort((a, b) => a.date.compareTo(b.date));
  for (final roster in sorted) {
    final day = dayKey(roster.date);
    final dayBusy = busy.putIfAbsent(day, () => {});
    var changed = false;
    final duties = <RosterEntry>[];
    for (final duty in roster.duties) {
      if (skipRoles.contains(duty.role) || !_needsFilling(duty)) {
        duties.add(duty);
        continue;
      }
      final stats =
          patterns[duty.role]?[_patternKey(roster, duty.role)] ??
          patterns[duty.role]?[_fallbackKey(roster, duty.role)];
      final need = stats?.decide();
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
      bool servedLastWeek(String p) {
        final d = last[p];
        return d != null && dayKey(d) == dayKey(lastWeek);
      }

      final candidates =
          (eligible[duty.role] ?? const <String>{})
              .where((p) => !dayBusy.contains(p))
              .toList()
            ..sort((a, b) {
              final byCount = (counts[a] ?? 0).compareTo(counts[b] ?? 0);
              if (byCount != 0) return byCount;
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

      final picked = candidates.take(need.count).toList();
      if (picked.isEmpty) {
        duties.add(duty);
        shortfalls.add(
          AutoAssignment(roster: roster, role: duty.role, people: const []),
        );
        continue;
      }
      for (final p in picked) {
        record(duty.role, p, roster.date);
        dayBusy.add(p);
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
