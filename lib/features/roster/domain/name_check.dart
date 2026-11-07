// 「名字檢查」：同一個人在不同地方寫法不一樣（Jasmine／Jasemine、大小寫、
// 空白），系統會當成兩個人——天數拆開算、同一天重複排也檢查不出來、
// LINE 提醒對不上。打開同工名單時把可疑的名字列出來給安排者看。

/// 一組可能是同一個人的名字。
class SimilarNames {
  const SimilarNames(this.names);

  /// 照「用得最多」排，第一個是建議統一成的寫法。
  final List<String> names;
}

class NameCheckResult {
  const NameCheckResult({required this.similar, required this.unknown});

  final List<SimilarNames> similar;

  /// 在同工名單上，卻不在任何服事表、也不是 App 帳號的名字（可能打錯字，
  /// 也可能是新同工）。
  final List<String> unknown;

  bool get isEmpty => similar.isEmpty && unknown.isEmpty;
}

String _key(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'[\s\-_.・]'), '');

int _distance(String a, String b) {
  if (a == b) return 0;
  if ((a.length - b.length).abs() > 2) return 99;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = [
        prev[j] + 1,
        cur[j - 1] + 1,
        prev[j - 1] + cost,
      ].reduce((x, y) => x < y ? x : y);
    }
    prev = cur;
  }
  return prev[b.length];
}

/// [poolNames]：同工名單上的名字。[rosterCounts]：服事表上出現過的名字和
/// 次數。[userNames]：App 帳號的名字（全名，例如 Austin Lin）。
NameCheckResult checkNames({
  required Iterable<String> poolNames,
  required Map<String, int> rosterCounts,
  required Iterable<String> userNames,
}) {
  final uses = <String, int>{};
  for (final n in poolNames) {
    final t = n.trim();
    if (t.isEmpty) continue;
    uses[t] = (uses[t] ?? 0) + 1;
  }
  for (final e in rosterCounts.entries) {
    final t = e.key.trim();
    if (t.isEmpty) continue;
    uses[t] = (uses[t] ?? 0) + e.value;
  }
  final poolSet = {for (final n in poolNames) n.trim()};
  final names = uses.keys.toList()..sort();

  // 寫法相近：去掉大小寫、空白、連字號後一樣，或英文名字差一兩個字母。
  // 只看至少有一個在同工名單上的組合（服事表上的舊名字彼此不管）。
  final parent = {for (final n in names) n: n};
  String find(String n) {
    while (parent[n] != n) {
      n = parent[n]!;
    }
    return n;
  }

  for (var i = 0; i < names.length; i++) {
    for (var j = i + 1; j < names.length; j++) {
      final a = names[i];
      final b = names[j];
      if (!poolSet.contains(a) && !poolSet.contains(b)) continue;
      final ka = _key(a);
      final kb = _key(b);
      final ascii = RegExp(r'^[a-z]+$');
      final close =
          ka == kb ||
          (ascii.hasMatch(ka) &&
              ascii.hasMatch(kb) &&
              ka.length >= 4 &&
              kb.length >= 4 &&
              _distance(ka, kb) <= (ka.length >= 7 ? 2 : 1));
      if (close) parent[find(a)] = find(b);
    }
  }
  final groups = <String, List<String>>{};
  for (final n in names) {
    groups.putIfAbsent(find(n), () => []).add(n);
  }
  final similar = [
    for (final g in groups.values)
      if (g.length > 1)
        SimilarNames(
          g..sort((a, b) {
            final byUse = (uses[b] ?? 0).compareTo(uses[a] ?? 0);
            return byUse != 0 ? byUse : a.compareTo(b);
          }),
        ),
  ];

  // 不認得的名字：不在服事表、也不是任何帳號的全名或名字（第一個字）。
  final known = <String>{
    for (final n in rosterCounts.keys) _key(n),
    for (final u in userNames) ...[
      _key(u),
      _key(u.trim().split(RegExp(r'\s+')).first),
    ],
  };
  final inSimilar = {for (final g in similar) ...g.names};
  final unknown = [
    for (final n in poolSet)
      if (n.isNotEmpty && !known.contains(_key(n)) && !inSimilar.contains(n)) n,
  ]..sort();

  return NameCheckResult(similar: similar, unknown: unknown);
}
