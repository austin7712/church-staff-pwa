import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';
import 'package:church_staff_pwa/features/roster/domain/roster_view_model.dart';
import 'package:church_staff_pwa/features/roster/presentation/widgets/roster_table_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

ServiceRoster _day(DateTime d) => ServiceRoster(
  id: d.toIso8601String(),
  date: d,
  type: ServiceType.sundayService,
  serviceName: '主日崇拜',
  duties: [
    RosterEntry(role: '台語講員', people: const ['李世榮']),
    RosterEntry(role: '華語講員', people: const ['林國泰']),
    RosterEntry(role: '司會報告', people: const ['CT']),
    RosterEntry(role: '敬拜讚美', people: const ['Joe', 'Gina']),
    RosterEntry(role: '音控', people: const ['Crispin', 'Hugo']),
    RosterEntry(role: '奉獻點算', people: const ['Kevin', 'Craig']),
    RosterEntry(role: '聖餐長老', people: const ['Daniel']),
    RosterEntry(role: '兒童主日', people: const ['Jasmine']),
    RosterEntry(role: '幼兒主日', people: const ['An-ting']),
    RosterEntry(role: '幼兒助教', people: const ['Paulina']),
    RosterEntry(role: '愛餐整理', people: const ['喜樂小組']),
  ],
);

void main() {
  test('幼兒助教併進幼兒主日那一欄，老師、助教分開標', () {
    final t = buildRosterTable([_day(DateTime(2027, 3, 7))]);
    final col = t.columns.indexWhere((c) => c.header == '幼兒主日');
    expect(col, isNot(-1));
    expect(t.columns.any((c) => c.header == '幼兒助教'), isFalse);
    final cells = t.rows.last.cells[col];
    expect(cells.map((c) => c.text), ['An-ting', 'Paulina']);
    expect(cells.map((c) => c.tag), ['老師', '助教']);
  });

  test('卡片：幼兒主日一行寫老師和助教', () {
    final d = _day(DateTime(2027, 3, 7));
    final merged = mergeDutiesForDisplay(d, d.duties);
    final kid = merged.firstWhere((x) => x.role == '幼兒主日');
    expect(kid.people, ['An-ting（老師）', 'Paulina（助教）']);
    expect(merged.any((x) => x.role == '幼兒助教'), isFalse);
  });

  testWidgets('手機寬度：老師、助教和名字都不會被切掉', (tester) async {
    tester.view.physicalSize = const Size(375 * 3, 812 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RosterTableView(rosters: [_day(DateTime(2027, 3, 7))]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final text in ['老師', '助教', 'An-ting', 'Paulina', 'Crispin']) {
      final finder = find.text(text, findRichText: true);
      expect(finder, findsWidgets, reason: text);
      for (final e in finder.evaluate()) {
        final p = e.renderObject! as RenderParagraph;
        expect(p.debugHasOverflowShader, isFalse, reason: '$text 被切掉了');
      }
    }
  });
}
