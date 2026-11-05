import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/roster/domain/roster_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sunday = ServiceType('sun');
  const kids = ServiceType('kids');
  const meal = ServiceType('meal');

  test('主日崇拜包含兒童主日等項目：總覽＝主日全部，其他分頁只看自己的欄', () {
    final tabs = rosterTabs(
      [sunday, kids, meal],
      {
        sunday: ['音控', '兒童主日', '愛餐整理'],
        kids: ['兒童主日'],
        meal: ['愛餐整理'],
      },
    );
    expect(tabs.map((t) => t.label), ['總覽', 'sun', 'kids', 'meal']);
    expect(tabs[0].isOverview, isTrue);
    expect(tabs[0].types, [sunday]);
    expect(tabs[1].exceptRoles, {'兒童主日', '愛餐整理'});
    expect(tabs[2].types, [sunday], reason: '讀主日崇拜的資料');
    expect(tabs[2].onlyRoles, {'兒童主日'});
  });

  test('各自獨立的聚會：總覽加上各聚會分頁（原本的樣子）', () {
    final tabs = rosterTabs(
      [sunday, kids],
      {
        sunday: ['音控'],
        kids: ['小組老師'],
      },
    );
    expect(tabs.map((t) => t.label), ['總覽', 'sun', 'kids']);
    expect(tabs[0].types, [sunday, kids]);
    expect(tabs.every((t) => !t.isFiltered), isTrue);
  });

  test('只有一個聚會：不需要總覽', () {
    final tabs = rosterTabs([sunday], {sunday: ['音控']});
    expect(tabs.map((t) => t.label), ['sun']);
  });
}
