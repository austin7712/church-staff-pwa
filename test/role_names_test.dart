import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';
import 'package:church_staff_pwa/features/roster/domain/role_names.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('舊名字換成統一名稱', () {
    expect(canonicalRole('報告'), '司會報告');
    expect(canonicalRole('司會'), '司會報告');
    expect(canonicalRole('敬拜主領'), '敬拜讚美');
    expect(canonicalRole('收奉'), '奉獻點算');
    expect(canonicalRole('收奉獻'), '奉獻點算');
    expect(canonicalRole('聖餐'), '聖餐長老');
    expect(canonicalRole('兒童主日學'), '兒童主日');
    expect(canonicalRole('愛餐整潔'), '愛餐整理');
    expect(canonicalRole('音控'), '音控');
  });

  test('同一天兩個舊寫法合併成一項，待定讓位給真的人', () {
    final duties = canonicalDuties([
      RosterEntry(role: '司會', people: const ['待定']),
      RosterEntry(role: '音控', people: const ['Hugo']),
      RosterEntry(role: '報告', people: const ['CT']),
    ]);
    expect(duties.map((d) => d.role), ['司會報告', '音控']);
    expect(duties.first.people, ['CT']);
  });
}
