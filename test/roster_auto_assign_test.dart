import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';
import 'package:church_staff_pwa/features/roster/domain/roster_auto_assign.dart';
import 'package:flutter_test/flutter_test.dart';

ServiceRoster _week(
  DateTime date,
  Map<String, List<String>> duties, {
  List<String> events = const [],
  ServiceType type = ServiceType.sundayService,
}) => ServiceRoster(
  id: '${date.toIso8601String()}_${type.name}',
  date: date,
  type: type,
  serviceName: '主日崇拜',
  specialEvents: events,
  duties: [
    for (final MapEntry(key: role, value: people) in duties.entries)
      RosterEntry(role: role, people: people),
  ],
);

DateTime _sun(int i) => DateTime.utc(2026, 1, 4).add(Duration(days: 7 * i));

/// 一年份的歷史：音控每週兩人、收奉兩人；聯合崇拜（台語主領）只排收奉；
/// 聖餐只在聖餐週。
List<ServiceRoster> _history() {
  const sound = ['A', 'B', 'C', 'D'];
  const offering = ['O1', 'O2', 'O3'];
  return [
    for (var i = 0; i < 12; i++)
      if (i % 4 == 2)
        _week(
          _sun(i),
          {
            '台語講員': ['講員'],
            '音控': ['台語'],
            '收奉': [offering[i % 3], offering[(i + 1) % 3]],
          },
          events: const ['聯合崇拜（台語主領）'],
        )
      else
        _week(
          _sun(i),
          {
            '台語講員': ['講員'],
            '音控': [sound[i % 4], sound[(i + 1) % 4]],
            '收奉': [offering[i % 3], offering[(i + 1) % 3]],
            if (i % 4 == 0) '聖餐': ['C1', 'C2'],
          },
          events: [if (i % 4 == 0) '聖餐'],
        ),
  ];
}

ServiceRoster _blank(int i, {List<String> events = const []}) => _week(
  DateTime.utc(2027, 1, 3).add(Duration(days: 7 * i)),
  {
    '台語講員': ['待定'],
    '音控': ['待定'],
    '收奉': ['待定'],
    '聖餐': ['待定'],
  },
  events: events,
);

void main() {
  test('預設可排的人：做過兩次（含）以上', () {
    final counts = roleHistoryCounts([
      _week(_sun(0), {
        '音控': ['A', 'B'],
      }),
      _week(_sun(1), {
        '音控': ['A', 'Austin'],
      }),
      _week(_sun(2), {
        '音控': ['B', '台語'],
      }),
    ]);
    expect(counts['音控'], {'A': 2, 'B': 2, 'Austin': 1});
    expect(defaultEligible(counts)['音控'], {'A', 'B'});
  });

  test('只填空格、講員不排、次數平均、同一天不重複', () {
    final history = _history();
    final eligible = defaultEligible(roleHistoryCounts(history));
    final targets = [for (var i = 0; i < 8; i++) _blank(i)];
    final result = autoAssign(
      targets: targets,
      history: history,
      eligible: eligible,
    );

    for (final r in result.updated) {
      expect(
        r.duties.firstWhere((d) => d.role == '台語講員').people,
        ['待定'],
        reason: '講員不排',
      );
      final sound = r.duties.firstWhere((d) => d.role == '音控').people;
      expect(sound, hasLength(2), reason: '歷史上音控每週兩人');
      final everyone = r.duties.expand((d) => d.people).where((p) => p != '待定');
      expect(everyone.toSet().length, everyone.length, reason: '同一天不重複');
    }

    final soundCounts = roleHistoryCounts(result.updated)['音控']!;
    expect(soundCounts.keys.toSet(), {'A', 'B', 'C', 'D'});
    final values = soundCounts.values.toList();
    expect(
      values.reduce((a, b) => a > b ? a : b) -
          values.reduce((a, b) => a < b ? a : b),
      lessThanOrEqualTo(1),
      reason: '同一項裡次數平均：$soundCounts',
    );
  });

  test('已經排好的人不動，也算進次數', () {
    final history = _history();
    final first = _blank(0);
    final prefilled = first.copyWith(
      duties: [
        for (final d in first.duties)
          d.role == '音控' ? d.copyWith(people: const ['A', 'B']) : d,
      ],
    );
    final result = autoAssign(
      targets: [prefilled, _blank(1)],
      history: history,
      eligible: defaultEligible(roleHistoryCounts(history)),
    );
    final week0 = result.updated.firstWhere((r) => r.id == prefilled.id);
    expect(week0.duties.firstWhere((d) => d.role == '音控').people, ['A', 'B']);
    final week1 = result.updated.firstWhere((r) => r.id != prefilled.id);
    expect(
      week1.duties.firstWhere((d) => d.role == '音控').people.toSet(),
      {'C', 'D'},
      reason: 'A、B 這次已經排過一次了',
    );
  });

  test('不跨事工：只從勾選的人裡挑；安排者可以加人', () {
    final history = _history();
    final eligible = defaultEligible(roleHistoryCounts(history));
    eligible['音控'] = {...eligible['音控']!, 'Austin'};
    final result = autoAssign(
      targets: [for (var i = 0; i < 6; i++) _blank(i)],
      history: history,
      eligible: eligible,
    );
    final sound = result.assignments
        .where((a) => a.role == '音控')
        .expand((a) => a.people)
        .toSet();
    expect(sound, contains('Austin'));
    expect(sound.difference({'A', 'B', 'C', 'D', 'Austin'}), isEmpty);
    final offering = result.assignments
        .where((a) => a.role == '收奉')
        .expand((a) => a.people)
        .toSet();
    expect(offering.difference({'O1', 'O2', 'O3'}), isEmpty);
  });

  test('聯合崇拜（台語主領）照歷史：音控寫台語、收奉照排；聖餐只在聖餐週', () {
    final history = _history();
    final result = autoAssign(
      targets: [
        _blank(0, events: const ['聯合崇拜（台語主領）']),
        _blank(1, events: const ['聖餐']),
        _blank(2),
      ],
      history: history,
      eligible: defaultEligible(roleHistoryCounts(history)),
    );
    List<String> peopleOf(int i, String role) => result.updated[i].duties
        .firstWhere((d) => d.role == role)
        .people;

    expect(peopleOf(0, '音控'), ['台語']);
    expect(peopleOf(0, '收奉'), hasLength(2));
    expect(peopleOf(0, '聖餐'), ['待定'], reason: '不是聖餐週');
    expect(peopleOf(1, '聖餐').toSet(), {'C1', 'C2'});
    expect(peopleOf(2, '聖餐'), ['待定']);
  });

  test('盡量不連續兩週排同一個人', () {
    final history = [
      _week(_sun(0), {
        '音控': ['A'],
      }),
      _week(_sun(1), {
        '音控': ['B'],
      }),
      _week(_sun(2), {
        '音控': ['A'],
      }),
      _week(_sun(3), {
        '音控': ['B'],
      }),
    ];
    final result = autoAssign(
      targets: [
        for (var i = 0; i < 4; i++)
          _week(DateTime.utc(2027, 1, 3).add(Duration(days: 7 * i)), {
            '音控': ['待定'],
          }),
      ],
      history: history,
      eligible: const {
        '音控': {'A', 'B'},
      },
    );
    final order = [
      for (final r in result.updated) r.duties.single.people.single,
    ];
    for (var i = 1; i < order.length; i++) {
      expect(order[i], isNot(order[i - 1]), reason: '$order');
    }
  });

  group('同工名單', () {
    test('還沒整理過的項目用今年做過的人當預設，做得多的在前', () {
      final counts = {
        '音控': {'A': 1, 'B': 5, 'Austin': 1},
        '收奉': {'O1': 2},
      };
      const saved = StaffPool({
        '收奉': ['O1', '新同工'],
      });
      final pool = saved.withDefaults(counts, ['音控', '收奉', '聖餐']);
      expect(pool.roles['音控'], ['B', 'A', 'Austin']);
      expect(pool.roles['收奉'], ['O1', '新同工'], reason: '整理過的照存的');
      expect(pool.roles['聖餐'], isEmpty);
      expect(pool.eligible['音控'], {'A', 'B', 'Austin'});
    });

    test('存檔讀回一樣', () {
      const pool = StaffPool({
        '音控': ['Austin', 'Henry'],
      });
      expect(StaffPool.fromJson(pool.toJson()).roles, pool.roles);
      expect(StaffPool.fromJson(null).roles, isEmpty);
    });
  });

  group('愛餐整理：以小組為單位、一個月一組', () {
    const groups = ['忍耐小組', '喜樂小組', '溫柔小組'];
    ServiceRoster love(DateTime d, [List<String>? people]) => ServiceRoster(
      id: '${d.toIso8601String()}_love',
      date: d,
      type: ServiceType.sundayService,
      serviceName: '愛餐整理',
      duties: [
        if (people != null) RosterEntry(role: '愛餐整理', people: people),
      ],
    );
    List<ServiceRoster> weeks(int n) => [
      for (var i = 0; i < n; i++)
        love(DateTime.utc(2027, 1, 3).add(Duration(days: 7 * i))),
    ];

    test('同一個月同一組，下個月換下一組；接著歷史輪', () {
      final result = autoAssign(
        targets: weeks(14),
        history: [
          love(DateTime.utc(2026, 12, 27), ['忍耐小組']),
        ],
        eligible: const {},
        groupRoles: const {'愛餐整理': groups},
      );
      final byMonth = <int, Set<String>>{};
      for (final r in result.updated) {
        byMonth
            .putIfAbsent(r.date.month, () => {})
            .addAll(r.duties.single.people);
      }
      expect(byMonth, {
        1: {'喜樂小組'},
        2: {'溫柔小組'},
        3: {'忍耐小組'},
        4: {'喜樂小組'},
      });
    });

    test('已經填好某組的月份照填的，後面接著輪', () {
      final targets = weeks(10);
      targets[0] = love(targets[0].date, ['溫柔小組']);
      final result = autoAssign(
        targets: targets,
        history: const [],
        eligible: const {},
        groupRoles: const {'愛餐整理': groups},
      );
      final months = {
        for (final r in result.updated)
          r.date.month: r.duties.single.people.single,
      };
      expect(months, {1: '溫柔小組', 2: '忍耐小組', 3: '喜樂小組'});
    });
  });

  test('沒有歷史的新服事（兒童主日）：名單上有人就每週排一位、輪流', () {
    final result = autoAssign(
      targets: [
        for (var i = 0; i < 4; i++)
          _week(DateTime.utc(2027, 1, 3).add(Duration(days: 7 * i)), {
            '兒童主日': ['待定'],
          }),
      ],
      history: const [],
      eligible: const {
        '兒童主日': {'Ann', 'Ben'},
      },
    );
    final order = [
      for (final r in result.updated) r.duties.single.people.single,
    ];
    expect(order, ['Ann', 'Ben', 'Ann', 'Ben']);
  });

  test('空白表沒標聖餐：每個月第一個主日排聖餐', () {
    final history = _history();
    final result = autoAssign(
      targets: [for (var i = 0; i < 6; i++) _blank(i)],
      history: history,
      eligible: defaultEligible(roleHistoryCounts(history)),
    );
    for (final r in result.updated) {
      final people = r.duties.firstWhere((d) => d.role == '聖餐').people;
      if (r.date.day <= 7) {
        expect(people.toSet(), {'C1', 'C2'}, reason: '${r.date}');
      } else {
        expect(people, ['待定'], reason: '${r.date}');
      }
    }
  });
}
