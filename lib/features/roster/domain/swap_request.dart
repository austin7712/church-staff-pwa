import 'entities/service_roster.dart';
import 'role_names.dart';

/// LINE 小幫手送來的換班／代班申請裡的一格服事。
class SwapSlot {
  const SwapSlot({
    required this.rosterId,
    required this.dateKey,
    required this.serviceName,
    required this.role,
    required this.person,
  });

  final String rosterId;
  final String dateKey;
  final String serviceName;
  final String role;

  /// 原本在這一格的人（服事表上的寫法）。
  final String person;

  static SwapSlot? fromJson(Object? json) {
    if (json is! Map) return null;
    String s(String key) => (json[key] ?? '').toString().trim();
    if (s('rosterId').isEmpty || s('role').isEmpty) return null;
    return SwapSlot(
      rosterId: s('rosterId'),
      dateKey: s('dateKey'),
      serviceName: s('serviceName'),
      role: canonicalRole(s('role')),
      person: s('person'),
    );
  }
}

enum SwapStatus {
  asking('等對方回覆'),
  pending('等待核准'),
  approved('已核准'),
  rejected('未核准'),
  declined('對方婉拒'),
  cancelled('已取消');

  const SwapStatus(this.label);
  final String label;

  static SwapStatus parse(Object? value) => SwapStatus.values.firstWhere(
    (s) => s.name == value,
    orElse: () => SwapStatus.cancelled,
  );
}

/// 換班／代班申請。資料存在 LINE 小幫手（Cloudflare Worker），App 只負責核准。
///
/// - 代班（[isSwap] = false）：[from] 那一格由 [candidate] 接手。
/// - 互換：[from] 那一格由 [candidate] 接手，[to] 那一格（原本是 [candidate]）
///   改成申請人 `from.person`。
class SwapRequest {
  const SwapRequest({
    required this.id,
    required this.isSwap,
    required this.status,
    required this.from,
    required this.to,
    required this.candidate,
    required this.confirmedByLine,
    required this.createdAt,
    this.decidedBy,
    this.note,
  });

  final String id;
  final bool isSwap;
  final SwapStatus status;
  final SwapSlot from;
  final SwapSlot? to;
  final String candidate;

  /// true：對方在 LINE 上按了同意；false：申請人說已經私下講好。
  final bool confirmedByLine;
  final DateTime? createdAt;
  final String? decidedBy;
  final String? note;

  String get requester => from.person;

  static SwapRequest? fromJson(Object? json) {
    if (json is! Map) return null;
    final from = SwapSlot.fromJson(json['from']);
    final id = (json['id'] ?? '').toString();
    final candidate = (json['candidate'] ?? '').toString().trim();
    if (from == null || id.isEmpty || candidate.isEmpty) return null;
    final isSwap = json['mode'] == 'swap';
    final to = isSwap ? SwapSlot.fromJson(json['to']) : null;
    if (isSwap && to == null) return null;
    return SwapRequest(
      id: id,
      isSwap: isSwap,
      status: SwapStatus.parse(json['status']),
      from: from,
      to: to,
      candidate: candidate,
      confirmedByLine: json['confirmedBy'] == 'line',
      createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()),
      decidedBy: json['decidedBy']?.toString(),
      note: json['note']?.toString(),
    );
  }
}

/// 核准時要寫回的服事表，或為什麼不能套用。
class SwapApplyResult {
  const SwapApplyResult.ok(this.rosters, {this.lockedWarning = false})
    : error = null;
  const SwapApplyResult.error(this.error)
    : rosters = const [],
      lockedWarning = false;

  /// 改好的服事表（已經套用過的話是空的）。
  final List<ServiceRoster> rosters;
  final String? error;

  /// 被換的格子有鎖定 🔒（還是可以核准，畫面上提醒一下）。
  final bool lockedWarning;

  bool get isOk => error == null;
}

/// 把申請套用到服事表上。
///
/// [replace] 是「把某格的某人換成另一人」的實作（App 裡是
/// `RosterProvider.replaceDutyPerson`，會一起處理待定與 uid）。
///
/// 服事表已經是申請後的樣子（例如上一次核准到一半）就當作已套用，回傳空的
/// 清單；原本的人已經不在那一格、也不是申請後的樣子，就回傳錯誤，不亂改。
SwapApplyResult applySwapRequest(
  SwapRequest request,
  List<ServiceRoster> rosters,
  RosterEntry Function(RosterEntry duty, String from, String to) replace,
) {
  final changes = <String, ServiceRoster>{};
  var locked = false;

  String? apply(SwapSlot slot, String newPerson) {
    final roster =
        changes[slot.rosterId] ??
        rosters.where((r) => r.id == slot.rosterId).firstOrNull;
    if (roster == null) return '找不到 ${slot.dateKey} 的服事表';
    final index = roster.duties.indexWhere(
      (d) => canonicalRole(d.role) == slot.role,
    );
    if (index < 0) return '${slot.dateKey} 的服事表沒有「${slot.role}」';
    final duty = roster.duties[index];
    bool has(String name) => duty.people.any(
      (p) => p.trim().toLowerCase() == name.trim().toLowerCase(),
    );
    String spelling(String name) => duty.people.firstWhere(
      (p) => p.trim().toLowerCase() == name.trim().toLowerCase(),
    );
    if (has(newPerson) && !has(slot.person)) return null; // 已經改好了
    if (!has(slot.person)) {
      return '${slot.dateKey} ${slot.role} 已經不是 ${slot.person}，'
          '服事表可能被改過了，請退回這筆申請';
    }
    if (duty.locked) locked = true;
    final duties = List<RosterEntry>.of(roster.duties);
    duties[index] = replace(duty, spelling(slot.person), newPerson);
    changes[slot.rosterId] = roster.copyWith(duties: duties);
    return null;
  }

  final error =
      apply(request.from, request.candidate) ??
      (request.to == null ? null : apply(request.to!, request.from.person));
  if (error != null) return SwapApplyResult.error(error);
  return SwapApplyResult.ok(
    changes.values.toList(),
    lockedWarning: locked,
  );
}
