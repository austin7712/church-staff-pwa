import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';
import 'package:church_staff_pwa/features/roster/domain/roster_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

ServiceRoster _day(
  String id,
  List<RosterEntry> duties, {
  List<String> events = const [],
}) => ServiceRoster(
  id: id,
  date: DateTime(2026, 11, 8),
  type: ServiceType.sundayService,
  serviceName: '主日崇拜',
  duties: duties,
  specialEvents: events,
);

void main() {
  group('isPersonMe', () {
    final duty = RosterEntry(
      role: '音控',
      people: const ['Crispin', 'Hugo'],
      personIdsByName: const {'Hugo': 'uid-hugo'},
    );

    test('名字相符（大小寫不拘）', () {
      expect(isPersonMe(duty, 'Crispin', userName: 'crispin'), isTrue);
      expect(isPersonMe(duty, 'Crispin', userName: 'Hugo'), isFalse);
    });

    test('uid 相符時，改名也認得', () {
      expect(
        isPersonMe(duty, 'Hugo', userId: 'uid-hugo', userName: 'Hugo Wang'),
        isTrue,
      );
    });

    test('佔位字永遠不是我', () {
      final tw = RosterEntry(role: '音控', people: const ['台語']);
      expect(isPersonMe(tw, '台語', userName: '台語'), isFalse);
    });
  });

  test('rolesForUser 列出這一天我的服事', () {
    final day = _day('d', [
      RosterEntry(role: '報告', people: const ['CT']),
      RosterEntry(role: '奉獻點算', people: const ['Kevin', 'CT']),
      RosterEntry(role: '音控', people: const ['Hugo']),
    ]);
    expect(rolesForUser(day, userName: 'CT'), ['報告', '奉獻點算']);
    expect(rolesForUser(day, userName: 'Austin'), isEmpty);
  });

  test('rosterSummary 同一位講員只寫一次，略過佔位字', () {
    final day = _day('d', [
      RosterEntry(role: kTwSpeakerRole, people: const ['高士超']),
      RosterEntry(role: kMwSpeakerRole, people: const ['高士超']),
      RosterEntry(role: '敬拜主領', people: const ['Joe', 'Gina']),
    ]);
    expect(rosterSummary(day), '講員 高士超　｜　敬拜 Joe、Gina');

    final combined = _day('c', [
      RosterEntry(role: kTwSpeakerRole, people: const ['高士超']),
      RosterEntry(role: '敬拜主領', people: const ['台語']),
    ]);
    expect(rosterSummary(combined), '講員 高士超');
  });

  group('buildRosterTable', () {
    final normal = _day('n', [
      RosterEntry(role: '音控', people: const ['Crispin', 'Hugo']),
      RosterEntry(role: kTwSpeakerRole, people: const ['李世榮']),
      RosterEntry(role: kMwSpeakerRole, people: const ['林國泰']),
      RosterEntry(role: '敬拜主領', people: const ['Joe', 'Gina']),
      RosterEntry(role: '愛餐整潔', people: const []),
    ]);
    final combined = _day(
      'c',
      [
        RosterEntry(role: '音控', people: const ['台語']),
        RosterEntry(role: kTwSpeakerRole, people: const ['高士超']),
        RosterEntry(role: '奉獻點算', people: const ['CT', 'Kevin']),
      ],
      events: const ['聯合崇拜（台語主領）'],
    );

    test('講員放第一欄，沒人排的服事不出現', () {
      final t = buildRosterTable([normal, combined]);
      expect(t.hasLanes, isTrue);
      expect(t.columns.map((c) => c.header), ['講員', '音控', '敬拜', '奉獻']);
    });

    test('一般主日分台、華兩行；其他服事都在華行', () {
      final t = buildRosterTable([normal], userName: 'Crispin');
      expect(t.rows.map((r) => r.lane), ['台', '華']);
      final tai = t.rows[0].cells;
      final hua = t.rows[1].cells;
      expect(tai[0].map((c) => c.text), ['李世榮']);
      expect(hua[0].map((c) => c.text), ['林國泰']);
      expect(tai[1], isEmpty);
      expect(hua[1].map((c) => c.text), ['Crispin', 'Hugo']);
      expect(hua[1].first.isMe, isTrue);
      expect(hua[1].last.isMe, isFalse);
      expect(t.rows[0].isFirstOfDay && !t.rows[0].isLastOfDay, isTrue);
      expect(!t.rows[1].isFirstOfDay && t.rows[1].isLastOfDay, isTrue);
    });

    test('同一位講員兩堂都講，台、華兩行都寫', () {
      final day = _day('s', [
        RosterEntry(role: kTwSpeakerRole, people: const ['高士超']),
        RosterEntry(role: kMwSpeakerRole, people: const ['高士超']),
      ]);
      final t = buildRosterTable([day]);
      expect(t.rows[0].cells[0].single.text, '高士超');
      expect(t.rows[1].cells[0].single.text, '高士超');
    });

    test('聯合崇拜合併成一行，台語堂負責的寫「台語堂」', () {
      final t = buildRosterTable([combined]);
      expect(t.rows.single.lane, '合');
      final cells = t.rows.single.cells;
      expect(cells[0].single.text, '高士超');
      expect(cells[1].single.text, '台語堂');
      expect(cells[1].single.isPlaceholder, isTrue);
      expect(cells[2].map((c) => c.text), ['CT', 'Kevin']);
    });

    test('一般主日裡寫「台語」的佔位放台行', () {
      final day = _day('p', [
        RosterEntry(role: kMwSpeakerRole, people: const ['林國泰']),
        RosterEntry(role: '報告', people: const ['台語']),
      ]);
      final t = buildRosterTable([day]);
      expect(t.rows[0].cells[1].single.text, '台語堂');
      expect(t.rows[1].cells[1], isEmpty);
    });

    test('沒有台華講員的聚會（兒童主日）一天一行、不分台華', () {
      final kids = ServiceRoster(
        id: 'k',
        date: DateTime(2026, 11, 8),
        type: ServiceType.children,
        serviceName: '兒童主日',
        duties: [RosterEntry(role: '小組老師', people: const ['Ann'])],
      );
      final t = buildRosterTable([kids]);
      expect(t.hasLanes, isFalse);
      expect(t.rows.single.lane, isNull);
      expect(t.columns.single.header, '小組');
    });
  });

  group('安排者用', () {
    test('同一天排到兩項的人標出來；佔位字與同項重複不算', () {
      final day = _day('d', [
        RosterEntry(role: '報告', people: const ['Joe']),
        RosterEntry(role: '奉獻點算', people: const ['Joe', 'Joe']),
        RosterEntry(role: '音控', people: const ['台語']),
        RosterEntry(role: '敬拜主領', people: const ['台語']),
      ]);
      expect(doubleBookedPeople(day), {'Joe'});
      final t = buildRosterTable([day]);
      final joe = t.rows.single.cells.expand((c) => c).where((c) => c.text == 'Joe');
      expect(joe.every((c) => c.isConflict), isTrue);
    });

    test('編輯時沒人排的服事項目也有一欄', () {
      final day = _day('d', [
        RosterEntry(role: kMwSpeakerRole, people: const ['林國泰']),
        RosterEntry(role: '音控', people: const ['Hugo']),
      ]);
      final t = buildRosterTable(
        [day],
        alwaysShowRoles: const [kTwSpeakerRole, '敬拜主領', '音控', '愛餐整潔'],
        editing: true,
      );
      expect(t.columns.map((c) => c.header), ['講員', '敬拜', '音控', '愛餐']);
    });

    test('編輯時佔位字跟人名一起放在華行', () {
      final day = _day('d', [
        RosterEntry(role: kMwSpeakerRole, people: const ['林國泰']),
        RosterEntry(role: '報告', people: const ['台語']),
      ]);
      final t = buildRosterTable([day], editing: true);
      expect(t.rows[0].cells[1], isEmpty);
      expect(t.rows[1].cells[1].single.text, '台語堂');
    });

    test('roleForCell：台行改台語講員、華行改華語講員、合行改已排的那位', () {
      final normal = _day('n', [
        RosterEntry(role: kTwSpeakerRole, people: const ['A']),
        RosterEntry(role: kMwSpeakerRole, people: const ['B']),
        RosterEntry(role: '音控', people: const ['C']),
      ]);
      final t = buildRosterTable([normal]);
      expect(roleForCell(t.rows[0], t.columns[0]), kTwSpeakerRole);
      expect(roleForCell(t.rows[1], t.columns[0]), kMwSpeakerRole);
      expect(roleForCell(t.rows[0], t.columns[1]), '音控');

      final mwLed = _day(
        'c',
        [RosterEntry(role: kMwSpeakerRole, people: const ['B'])],
        events: const ['聯合崇拜（華語主領）'],
      );
      final c = buildRosterTable([mwLed]);
      expect(roleForCell(c.rows.single, c.columns[0]), kMwSpeakerRole);
    });

    test('serviceCounts 由多到少', () {
      final a = _day('a', [
        RosterEntry(role: '音控', people: const ['Hugo', 'Crispin']),
        RosterEntry(role: '報告', people: const ['Hugo', '台語']),
      ]);
      final b = _day('b', [
        RosterEntry(role: '音控', people: const ['Crispin']),
      ]);
      expect(
        serviceCounts([a, b]).map((e) => '${e.key}:${e.value}'),
        ['Crispin:2', 'Hugo:2'],
      );
    });
  });

  group('照服事項目設定排序', () {
    final day = _day('d', [
      RosterEntry(role: '音控', people: const ['Hugo']),
      RosterEntry(role: '收奉', people: const ['Kevin']),
      RosterEntry(role: kMwSpeakerRole, people: const ['林國泰']),
      RosterEntry(role: '司會報告', people: const ['CT']),
      RosterEntry(role: '敬拜主領', people: const ['Joe']),
      RosterEntry(role: '小組', people: const ['Ann']),
    ]);
    const order = [
      kTwSpeakerRole,
      kMwSpeakerRole,
      '司會報告',
      '敬拜主領',
      '音控',
      '收奉',
      '聖餐',
    ];

    test('表格欄位', () {
      final t = buildRosterTable([day], roleOrder: order);
      expect(
        t.columns.map((c) => c.header),
        ['講員', '司會', '敬拜', '音控', '收奉', '小組'],
      );
    });

    test('卡片：不在設定裡的放最後', () {
      expect(
        dutiesInOrder(day.duties, order).map((d) => d.role),
        [kMwSpeakerRole, '司會報告', '敬拜主領', '音控', '收奉', '小組'],
      );
      expect(dutiesInOrder(day.duties, const []), same(day.duties));
    });
  });
}
