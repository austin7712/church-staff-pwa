import 'dart:convert';

import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/roster/data/swap_request_api.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';
import 'package:church_staff_pwa/features/roster/domain/swap_request.dart';
import 'package:church_staff_pwa/features/roster/presentation/providers/roster_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ServiceRoster _roster(String id, DateTime date, Map<String, List<String>> d,
        {bool locked = false}) =>
    ServiceRoster(
      id: id,
      date: date,
      type: ServiceType.sundayService,
      serviceName: '主日崇拜',
      duties: [
        for (final MapEntry(key: role, value: people) in d.entries)
          RosterEntry(role: role, people: people, locked: locked),
      ],
    );

Map<String, dynamic> _json({String mode = 'sub', String status = 'pending'}) => {
  'id': 'abc123',
  'mode': mode,
  'status': status,
  'candidate': 'Joe',
  'confirmedBy': 'private',
  'createdAt': '2026-11-07T07:00:00.000Z',
  'from': {
    'rosterId': 'r1',
    'dateKey': '2026-11-22',
    'serviceName': '主日崇拜',
    'role': '音控',
    'person': 'Austin',
  },
  if (mode == 'swap')
    'to': {
      'rosterId': 'r2',
      'dateKey': '2026-12-06',
      'serviceName': '主日崇拜',
      'role': '音控',
      'person': 'Joe',
    },
};

RosterEntry _replace(RosterEntry d, String from, String to) =>
    RosterProvider.replaceDutyPerson(d, from, to);

void main() {
  final r1 = _roster('r1', DateTime.utc(2026, 11, 22), {
    '音控': ['Austin'],
    '收奉': ['Grace', 'Austin'],
  });
  final r2 = _roster('r2', DateTime.utc(2026, 12, 6), {
    '音控': ['Joe'],
  });

  test('解析申請：代班、互換、壞資料', () {
    final sub = SwapRequest.fromJson(_json())!;
    expect(sub.isSwap, isFalse);
    expect(sub.requester, 'Austin');
    expect(sub.status, SwapStatus.pending);
    final swap = SwapRequest.fromJson(_json(mode: 'swap'))!;
    expect(swap.to!.person, 'Joe');
    expect(SwapRequest.fromJson({'id': 'x'}), isNull);
    expect(SwapRequest.fromJson(_json(mode: 'swap')..remove('to')), isNull);
  });

  test('代班：只改那一格，同一天其他服事不動', () {
    final result = applySwapRequest(
      SwapRequest.fromJson(_json())!,
      [r1, r2],
      _replace,
    );
    expect(result.isOk, isTrue);
    expect(result.rosters, hasLength(1));
    final duties = result.rosters.single.duties;
    expect(duties[0].people, ['Joe']);
    expect(duties[1].people, ['Grace', 'Austin']);
  });

  test('互換：兩天一起改', () {
    final result = applySwapRequest(
      SwapRequest.fromJson(_json(mode: 'swap'))!,
      [r1, r2],
      _replace,
    );
    expect(result.isOk, isTrue);
    final byId = {for (final r in result.rosters) r.id: r};
    expect(byId['r1']!.duties[0].people, ['Joe']);
    expect(byId['r2']!.duties[0].people, ['Austin']);
  });

  test('已經改好的不重複改；原本的人不在了就報錯', () {
    final done = _roster('r1', DateTime.utc(2026, 11, 22), {
      '音控': ['Joe'],
    });
    final again = applySwapRequest(
      SwapRequest.fromJson(_json())!,
      [done],
      _replace,
    );
    expect(again.isOk, isTrue);
    expect(again.rosters, isEmpty);

    final changed = _roster('r1', DateTime.utc(2026, 11, 22), {
      '音控': ['Henry'],
    });
    final bad = applySwapRequest(
      SwapRequest.fromJson(_json())!,
      [changed],
      _replace,
    );
    expect(bad.isOk, isFalse);
    expect(bad.error, contains('已經不是 Austin'));
  });

  test('鎖定的格子會提醒', () {
    final locked = _roster('r1', DateTime.utc(2026, 11, 22), {
      '音控': ['Austin'],
    }, locked: true);
    final result = applySwapRequest(
      SwapRequest.fromJson(_json())!,
      [locked],
      _replace,
    );
    expect(result.lockedWarning, isTrue);
    expect(result.rosters.single.duties.single.locked, isTrue);
  });

  test('API：帶登入憑證、讀錯誤訊息', () async {
    final seen = <http.Request>[];
    final api = SwapRequestApi(
      baseUrl: Uri.parse('https://w.example'),
      idToken: () async => 'tok',
      client: MockClient((req) async {
        seen.add(req);
        if (req.method == 'GET') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({'requests': [_json(), {'bad': 1}]})),
            200,
          );
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode({'error': '服事表還沒改好'})),
          409,
        );
      }),
    );
    final list = await api.list();
    expect(list, hasLength(1));
    expect(seen.first.headers['Authorization'], 'Bearer tok');
    expect(seen.first.url.toString(), 'https://w.example/api/swaps');
    await expectLater(
      api.decide('abc123', approve: true),
      throwsA(
        isA<SwapRequestException>().having(
          (e) => e.message,
          'message',
          '服事表還沒改好',
        ),
      ),
    );
    expect(jsonDecode(seen.last.body), {'decision': 'approve'});
  });
}
