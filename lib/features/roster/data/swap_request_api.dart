import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../domain/swap_request.dart';

/// LINE 服事小幫手（Cloudflare Worker `ipcf-line-reminder`）的網址。
/// 換班申請存在那邊，App 只讀取與核准。
const String kLineWorkerUrl = String.fromEnvironment(
  'LINE_WORKER_URL',
  defaultValue: 'https://ipcf-line-reminder.victorh-ipcf.workers.dev',
);

class SwapRequestException implements Exception {
  const SwapRequestException(this.message);
  final String message;

  @override
  String toString() => message;
}

typedef SwapIdTokenProvider = Future<String?> Function();

/// 換班申請 API：列出申請、核准或退回（只有管理者可以用）。
class SwapRequestApi {
  SwapRequestApi({
    http.Client? client,
    SwapIdTokenProvider? idToken,
    Uri? baseUrl,
  }) : _client = client ?? http.Client(),
       _idToken = idToken ?? _firebaseIdToken,
       _base = baseUrl ?? Uri.parse(kLineWorkerUrl);

  static const _timeout = Duration(seconds: 30);

  final http.Client _client;
  final SwapIdTokenProvider _idToken;
  final Uri _base;

  static Future<String?> _firebaseIdToken() =>
      FirebaseAuth.instance.currentUser?.getIdToken() ?? Future.value(null);

  Future<Map<String, String>> _headers() async {
    final token = await _idToken();
    if (token == null || token.isEmpty) {
      throw const SwapRequestException('請先登入');
    }
    return {
      'Authorization': 'Bearer $token',
      'content-type': 'application/json; charset=utf-8',
    };
  }

  Future<Map<String, dynamic>> _send(Future<http.Response> request) async {
    final http.Response response;
    try {
      response = await request.timeout(_timeout);
    } on TimeoutException {
      throw const SwapRequestException('連線逾時，請稍後再試');
    } catch (_) {
      throw const SwapRequestException('連不上 LINE 小幫手，請檢查網路後再試一次');
    }
    Object? body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      body = null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = body is Map ? body['error']?.toString() : null;
      throw SwapRequestException(
        message ?? 'LINE 小幫手回應錯誤（${response.statusCode}）',
      );
    }
    if (body is! Map<String, dynamic>) {
      throw const SwapRequestException('LINE 小幫手的回應看不懂，請再試一次');
    }
    return body;
  }

  /// 全部申請，新的在前面。
  Future<List<SwapRequest>> list() async {
    final body = await _send(
      _client.get(_base.resolve('/api/swaps'), headers: await _headers()),
    );
    final raw = body['requests'];
    return [
      if (raw is List)
        for (final r in raw) ?SwapRequest.fromJson(r),
    ];
  }

  /// 核准（服事表要先改好）或退回。回傳通知了幾個 LINE 帳號。
  Future<int> decide(String id, {required bool approve, String? note}) async {
    final body = await _send(
      _client.post(
        _base.resolve('/api/swaps/$id'),
        headers: await _headers(),
        body: jsonEncode({
          'decision': approve ? 'approve' : 'reject',
          if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        }),
      ),
    );
    final notified = body['notified'];
    return notified is int ? notified : 0;
  }
}
