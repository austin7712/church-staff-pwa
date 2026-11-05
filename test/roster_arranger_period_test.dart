import 'package:church_staff_pwa/features/roster/presentation/screens/roster_arranger_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('排班期間的起訖日', () {
    expect(ArrangerPeriod.year.range(2027), (
      DateTime.utc(2027, 1, 1),
      DateTime.utc(2027, 12, 31),
    ));
    expect(ArrangerPeriod.firstHalf.range(2027).$2, DateTime.utc(2027, 6, 30));
    expect(ArrangerPeriod.secondHalf.range(2027).$1, DateTime.utc(2027, 7, 1));
    expect(ArrangerPeriod.q1.range(2028).$2, DateTime.utc(2028, 3, 31));
    expect(ArrangerPeriod.q4.range(2027), (
      DateTime.utc(2027, 10, 1),
      DateTime.utc(2027, 12, 31),
    ));
  });
}
