import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/swap_request_api.dart';
import '../../domain/swap_request.dart';
import '../providers/roster_provider.dart';

const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

String _date(String dateKey) {
  final d = DateTime.tryParse(dateKey);
  if (d == null) return dateKey;
  return '${d.month}/${d.day}（${_weekdays[d.weekday - 1]}）';
}

String _slot(SwapSlot s) => '${_date(s.dateKey)}${s.serviceName} ${s.role}';

/// 管理者頁面：LINE 小幫手送來的換班／代班申請，核准後自動改服事表。
class SwapRequestsScreen extends StatefulWidget {
  const SwapRequestsScreen({super.key, this.api});

  final SwapRequestApi? api;

  @override
  State<SwapRequestsScreen> createState() => _SwapRequestsScreenState();
}

class _SwapRequestsScreenState extends State<SwapRequestsScreen> {
  late final SwapRequestApi _api = widget.api ?? SwapRequestApi();
  late Future<List<SwapRequest>> _requests = _api.list();
  final Set<String> _busy = {};
  bool _showDone = false;

  void _reload() => setState(() => _requests = _api.list());

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<bool> _confirm(String title, String body, String ok) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(ok),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _approve(SwapRequest request) async {
    if (!await _confirm('核准這筆申請？', _describe(request), '核准並更新服事表')) {
      return;
    }
    if (!mounted) return;
    final roster = context.read<RosterProvider>();
    setState(() => _busy.add(request.id));
    try {
      final result = await roster.prepareSwap(request);
      if (!result.isOk) {
        _snack(result.error!);
        return;
      }
      if (!mounted) return;
      if (result.lockedWarning &&
          !await _confirm('格子有鎖定 🔒', '要換的格子已經鎖定（跟同工確認過）。確定還是要改嗎？', '確定修改')) {
        return;
      }
      await roster.writeSwap(result);
      final notified = await _api.decide(request.id, approve: true);
      _snack(notified > 0 ? '已核准，服事表已更新，已用 LINE 通知 $notified 人' : '已核准，服事表已更新');
      _reload();
    } catch (e) {
      _snack('$e');
    } finally {
      if (mounted) setState(() => _busy.remove(request.id));
    }
  }

  Future<void> _reject(SwapRequest request) async {
    final controller = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退回這筆申請？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_describe(request)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: '原因（選填，會用 LINE 告訴同工）',
              ),
              maxLength: 100,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('退回'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (note == null) return;
    setState(() => _busy.add(request.id));
    try {
      await _api.decide(request.id, approve: false, note: note);
      _snack('已退回，服事表不變');
      _reload();
    } catch (e) {
      _snack('$e');
    } finally {
      if (mounted) setState(() => _busy.remove(request.id));
    }
  }

  String _describe(SwapRequest r) {
    final lines = ['${_slot(r.from)}：${r.from.person} → ${r.candidate}'];
    if (r.to != null) {
      lines.add('${_slot(r.to!)}：${r.to!.person} → ${r.from.person}');
    }
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('換班申請'),
        actions: [
          IconButton(
            tooltip: '重新整理',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      body: FutureBuilder<List<SwapRequest>>(
        future: _requests,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _Message(
              icon: Icons.error_outline,
              text: '${snapshot.error}',
              action: FilledButton(
                onPressed: _reload,
                child: const Text('再試一次'),
              ),
            );
          }
          final all = snapshot.data ?? const <SwapRequest>[];
          final pending = all
              .where((r) => r.status == SwapStatus.pending)
              .toList();
          final asking = all
              .where((r) => r.status == SwapStatus.asking)
              .toList();
          final done = all
              .where(
                (r) =>
                    r.status != SwapStatus.pending &&
                    r.status != SwapStatus.asking,
              )
              .toList();
          return RefreshIndicator(
            onRefresh: () async {
              _reload();
              await _requests;
            },
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  '同工在 LINE 服事小幫手傳「換班」申請代班或互換。核准後會自動修改服事表，並用 LINE 通知雙方。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                _Header('等待核准', pending.length),
                if (pending.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('目前沒有待核准的申請 🙂'),
                  ),
                for (final r in pending)
                  _RequestCard(
                    request: r,
                    describe: _describe,
                    busy: _busy.contains(r.id),
                    onApprove: () => _approve(r),
                    onReject: () => _reject(r),
                  ),
                if (asking.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _Header('等對方在 LINE 回覆', asking.length),
                  for (final r in asking)
                    _RequestCard(request: r, describe: _describe),
                ],
                if (done.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  InkWell(
                    onTap: () => setState(() => _showDone = !_showDone),
                    child: Row(
                      children: [
                        Expanded(child: _Header('已處理', done.length)),
                        Icon(_showDone ? Icons.expand_less : Icons.expand_more),
                      ],
                    ),
                  ),
                  if (_showDone)
                    for (final r in done.take(30))
                      _RequestCard(request: r, describe: _describe),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title, this.count);
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(
      '$title（$count）',
      style: Theme.of(context).textTheme.titleMedium,
    ),
  );
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.request,
    required this.describe,
    this.busy = false,
    this.onApprove,
    this.onReject,
  });

  final SwapRequest request;
  final String Function(SwapRequest) describe;
  final bool busy;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = request;
    final created = r.createdAt?.toLocal();
    final meta = [
      if (r.status == SwapStatus.pending)
        r.confirmedByLine ? '${r.candidate} 已在 LINE 同意' : '申請人說已私下講好',
      if (created != null) '申請於 ${created.month}/${created.day}',
      if (r.decidedBy != null) '${r.status.label}：${r.decidedBy}',
      if (r.note != null) '原因：${r.note}',
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  r.isSwap ? Icons.swap_horiz : Icons.person_add_alt,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  r.isSwap ? '互換' : '代班',
                  style: theme.textTheme.titleSmall,
                ),
                const Spacer(),
                Chip(
                  label: Text(r.status.label),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(describe(r), style: theme.textTheme.bodyMedium),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                meta.join('・'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
            if (onApprove != null) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  OutlinedButton(
                    onPressed: busy ? null : onReject,
                    child: const Text('退回'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: busy ? null : onApprove,
                    child: const Text('核准'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    ),
  );
}
