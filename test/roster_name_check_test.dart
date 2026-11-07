import 'package:church_staff_pwa/features/roster/domain/name_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('找出寫法相近的名字，用得多的排前面', () {
    final r = checkNames(
      poolNames: const ['Jasmine', 'Daniel', 'An-ting', 'kevin'],
      rosterCounts: const {'Jasemine': 30, 'Daniel': 40, 'Anting': 2, 'Kevin': 20},
      userNames: const ['Daniel Wang'],
    );
    final groups = [for (final g in r.similar) g.names.join('|')];
    expect(groups, contains('Jasemine|Jasmine'));
    expect(groups, contains('Anting|An-ting'));
    expect(groups, contains('Kevin|kevin'));
    expect(groups.any((g) => g.split('|').contains('Daniel')), isFalse);
  });

  test('名單上有、但服事表和帳號都沒有的名字', () {
    final r = checkNames(
      poolNames: const ['Austin', 'Newbie', 'Hugo'],
      rosterCounts: const {'Hugo': 3},
      userNames: const ['Austin Lin'],
    );
    expect(r.unknown, ['Newbie']);
  });

  test('中文名字不拿來比相似（避免誤判）', () {
    final r = checkNames(
      poolNames: const ['陳敏', '陳明'],
      rosterCounts: const {'陳敏': 1, '陳明': 1},
      userNames: const [],
    );
    expect(r.similar, isEmpty);
  });
}
