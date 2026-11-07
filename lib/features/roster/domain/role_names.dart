import 'entities/service_roster.dart';
import 'roster_view_model.dart';

/// 服事項目的統一名稱（全 app 一致）。舊資料裡的寫法在讀進來時換成這些名字，
/// 之後存檔就是新名字，不需要一次把資料庫全部改寫。
const Map<String, String> kRoleAliases = {
  '報告': '司會報告',
  '司會': '司會報告',
  '敬拜主領': '敬拜讚美',
  '收奉': '奉獻點算',
  '收奉獻': '奉獻點算',
  '奉獻': '奉獻點算',
  '聖餐': '聖餐長老',
  '兒童主日學': '兒童主日',
  '幼兒主日學': '幼兒主日',
  '愛餐整潔': '愛餐整理',
  '愛餐': '愛餐整理',
};

String canonicalRole(String role) {
  final r = role.trim();
  return kRoleAliases[r] ?? r;
}

/// 換成統一名稱；舊資料同一天有兩個寫法（例如「司會」與「報告」）就合併。
List<RosterEntry> canonicalDuties(List<RosterEntry> duties) {
  final result = <RosterEntry>[];
  for (final duty in duties) {
    final role = canonicalRole(duty.role);
    final i = result.indexWhere((d) => d.role == role);
    if (i < 0) {
      result.add(role == duty.role ? duty : duty.copyWith(role: role));
      continue;
    }
    final prev = result[i];
    final people = <String>[
      for (final p in prev.people)
        if (!isPlaceholderPerson(p) || p.trim() == kTaiwanesePlaceholder) p,
    ];
    for (final p in duty.people) {
      if (!people.contains(p) && p.trim() != kTbdPlaceholder) people.add(p);
    }
    result[i] = prev.copyWith(
      people: people.isEmpty ? prev.people : people,
      personIdsByName: {...prev.personIdsByName, ...duty.personIdsByName},
      locked: prev.locked || duty.locked,
    );
  }
  return result;
}
