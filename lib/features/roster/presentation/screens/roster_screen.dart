import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/entities/service_roster.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import '../../../auth/presentation/providers/session_provider.dart';
import '../providers/roster_provider.dart';
import '../widgets/roster_view_card.dart';
import '../widgets/roster_table_view.dart';
import '../widgets/roster_view_colors.dart';
import '../widgets/roster_toolbar.dart';
import '../../domain/roster_view_model.dart';
import '../../../../core/utils/error_messages.dart';
import '../../../../core/widgets/empty_state.dart';
import '../../../../core/utils/scroll_anchor.dart';
import '../../../../core/utils/snappy_page_scroll_physics.dart';
import 'roster_edit_screen.dart' deferred as roster_edit_screen;

class RosterScreen extends StatefulWidget {
  const RosterScreen({
    super.key,
    this.allowEdit = true,
    this.initialTableMode = true,
  });

  final bool allowEdit;

  /// 一開始用表格還是卡片。預設表格（一眼看完整季）。
  final bool initialTableMode;

  @override
  State<RosterScreen> createState() => _RosterScreenState();
}

class _RosterScreenState extends State<RosterScreen>
    with TickerProviderStateMixin {
  bool _editReady = false;
  bool _isLoadingEdit = false;
  TabController? _tabController;

  /// 檢視方式：表格（預設）或卡片。各分頁共用同一個選擇。
  late bool _tableMode = widget.initialTableMode;

  /// 只列出排到自己的那幾天。
  bool _mineOnly = false;

  Future<void> _loadEditLibrary(
    BuildContext context,
    Future<void> Function() loadLibrary,
  ) async {
    if (_isLoadingEdit) return;
    _isLoadingEdit = true;
    var dialogShown = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      await loadLibrary();
      if (!context.mounted) return;
      if (dialogShown) {
        Navigator.of(context, rootNavigator: true).pop();
        dialogShown = false;
      }
      setState(() {
        _editReady = true;
      });
      final rosterProvider = context.read<RosterProvider>();
      if (!rosterProvider.isEditMode) {
        // 先記下現在看到哪一天，編輯清單掛好後才換得回來。
        rosterProvider.captureScrollAnchors();
        rosterProvider.toggleEditMode();
      }
    } catch (error, st) {
      log('載入編輯模式失敗', error: error, stackTrace: st);
      if (context.mounted) {
        if (dialogShown) {
          Navigator.of(context, rootNavigator: true).pop();
          dialogShown = false;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('載入失敗：${mapErrorToUserMessage(error)}')),
        );
      }
    } finally {
      if (dialogShown && context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      _isLoadingEdit = false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rosterProvider = context.read<RosterProvider>();

      if (rosterProvider.rosters.isEmpty) {
        rosterProvider.fetchInitialData();
      }

      if (rosterProvider.isEditMode) {
        rosterProvider.toggleEditMode();
      }
    });
  }

  void _updateTabController(int length) {
    if (length <= 0) {
      _tabController?.dispose();
      _tabController = null;
      return;
    }
    if (_tabController == null || _tabController!.length != length) {
      final previousIndex = _tabController?.index ?? 0;
      _tabController?.dispose();
      _tabController = TabController(
        length: length,
        vsync: this,
        initialIndex: previousIndex.clamp(0, length - 1),
      );
    }
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  void _exitEditMode() {
    final rosterProvider = context.read<RosterProvider>();
    if (rosterProvider.isEditMode) {
      rosterProvider.captureScrollAnchors();
      rosterProvider.toggleEditMode();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionProvider>();
    // 聚會別只看牧區，不看編輯權：給了 roster-editors 不等於多看得到別的牧區。
    // 只有 admin 拿得到全部（見 [User.allowedRosterTypes]）。編輯權決定
    // 「能不能改」，牧區決定「能改哪一本」。
    final canEditRoster = session.canEditRoster;
    final canEdit = canEditRoster && widget.allowEdit;
    final userTypes =
        session.currentUser?.allowedRosterTypes ?? const <ServiceType>[];
    // 沒有任何服事項目、也沒有排過人的聚會不列出來（例如兒童主日、愛餐整理
    // 已經併進主日的服事項目裡，原本的分頁只剩空白週次）。
    // 回傳字串（不是 Set）：select 用 == 比較，才不會每次通知都重建。
    final hiddenKey = context.select<RosterProvider, String>((p) {
      final templates = p.templates;
      if (!templates.values.any((roles) => roles.isNotEmpty)) return '';
      return [
        for (final type in userTypes)
          if ((templates[type] ?? const <String>[]).isEmpty &&
              !p
                  .getRostersByType(type)
                  .any((r) => r.duties.any((d) => d.people.isNotEmpty)))
            type.name,
      ].join('\n');
    });
    final hidden = hiddenKey.isEmpty
        ? const <String>{}
        : hiddenKey.split('\n').toSet();
    final visibleTypes = [
      for (final type in userTypes)
        if (!hidden.contains(type.name)) type,
    ];
    final allowedTypes = visibleTypes.isEmpty ? userTypes : visibleTypes;
    // 標題不分本季／下季：對同工來說那只是「服事表」，範圍怎麼算他不用管。
    const titleText = '服事表';
    // select 而非 watch：否則每次 fetch 的 loading 開關都會重建整個 Scaffold
    // （含 AppBar / TabBar / TabController）。
    final isEditMode = context.select<RosterProvider, bool>(
      (provider) => provider.isEditMode,
    );

    // 兩個以上的聚會才需要「總覽」：同一天各聚會放在一起看。
    final showOverview = allowedTypes.length > 1;
    _updateTabController(allowedTypes.length + (showOverview ? 1 : 0));

    if (isEditMode && _editReady && canEdit) {
      return roster_edit_screen.RosterEditScreen(
        onExit: _exitEditMode,
        tabController: _tabController,
        allowedTypes: allowedTypes,
        showOverview: showOverview,
        tableMode: _tableMode,
        onTableModeChanged: (value) => setState(() => _tableMode = value),
      );
    }

    final tools = <Widget>[
      FilterChip(
        label: const Text('只看我的'),
        tooltip: _mineOnly ? '顯示全部服事' : '只看排到我的日子',
        selected: _mineOnly,
        onSelected: (_) => setState(() => _mineOnly = !_mineOnly),
        showCheckmark: false,
        avatar: Icon(
          _mineOnly ? Icons.person : Icons.person_outline,
          size: 18,
          color: _mineOnly ? kRosterMeText : null,
        ),
        selectedColor: kRosterMeFill,
        side: BorderSide(
          color: _mineOnly ? kRosterMeBorder : Colors.grey[400]!,
        ),
        labelStyle: TextStyle(
          color: _mineOnly ? kRosterMeText : null,
          fontWeight: _mineOnly ? FontWeight.bold : null,
        ),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      RosterViewModeSwitch(
        tableMode: _tableMode,
        onChanged: (value) => setState(() => _tableMode = value),
      ),
      if (canEdit)
        RosterToolButton(
          icon: Icons.edit_outlined,
          label: '編輯',
          tooltip: '切換至編輯模式',
          onPressed: () =>
              _loadEditLibrary(context, roster_edit_screen.loadLibrary),
        ),
    ];

    final appBar = AppBar(
      title: Text(titleText),
      centerTitle: true,
      bottom: rosterAppBarBottom(
        tools: tools,
        tabs: allowedTypes.isEmpty
            ? null
            : TabBar(
                isScrollable: allowedTypes.length > 3,
                controller: _tabController,
                tabs: [
                  if (showOverview) const Tab(text: '總覽'),
                  ...allowedTypes.map((type) => Tab(text: type.label)),
                ],
                indicatorSize: TabBarIndicatorSize.label,
                splashFactory: NoSplash.splashFactory,
                overlayColor: const WidgetStatePropertyAll(
                  Colors.transparent,
                ),
              ),
      ),
    );

    if (allowedTypes.isEmpty) {
      return Scaffold(
        appBar: appBar,
        body: const EmptyState(
          icon: Icons.folder_off_outlined,
          message: '尚未設定可檢視的牧區',
          hint: '請聯絡管理員為您加入服事牧區',
        ),
      );
    }

    return DefaultTabController(
      length: allowedTypes.length + (showOverview ? 1 : 0),
      child: Scaffold(
        appBar: appBar,
        // 刻意不用 Consumer 包住整個 body：Consumer 會在每一次
        // notifyListeners 重建整棵 TabBarView，連帶產生全新的 ListView 與
        // 全新的卡片 widget，底下卡片再怎麼 select 也擋不住。改成只訂閱
        // 「要不要顯示 spinner／錯誤」這兩個 bool，清單自己去訂閱自己那份資料。
        body: Builder(
          builder: (context) {
            // stale-while-revalidate: only block the UI with a spinner when
            // there is truly no data to show yet.  If we already have cached
            // rosters the TabBarView renders immediately while the background
            // server fetch runs silently.
            final showSpinner = context.select<RosterProvider, bool>(
              (provider) => provider.isLoading && provider.rosters.isEmpty,
            );
            if (showSpinner) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(
                      '載入服事資訊中…',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              );
            }

            final error = context.select<RosterProvider, String?>(
              (provider) => provider.error,
            );
            if (error != null) {
              return EmptyState(
                icon: Icons.error_outline,
                message: error,
                action: FilledButton.icon(
                  onPressed: () =>
                      context.read<RosterProvider>().fetchInitialData(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('重試'),
                ),
              );
            }

            return TabBarView(
              // 收尾動畫越久，「換完分頁馬上想往下滑卻沒反應」的窗口就越長。
              physics: const SnappyPageScrollPhysics(),
              controller: _tabController,
              children: [
                if (showOverview)
                  _RosterOverviewList(
                    key: const PageStorageKey('overview'),
                    types: allowedTypes,
                    tableMode: _tableMode,
                    mineOnly: _mineOnly,
                  ),
                ...allowedTypes.map((type) {
                  return _RosterViewList(
                    key: PageStorageKey(type.toString()),
                    type: type,
                    tableMode: _tableMode,
                    mineOnly: _mineOnly,
                  );
                }),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RosterViewList extends StatefulWidget {
  final ServiceType type;
  final bool tableMode;
  final bool mineOnly;

  const _RosterViewList({
    super.key,
    required this.type,
    required this.tableMode,
    required this.mineOnly,
  });

  @override
  State<_RosterViewList> createState() => _RosterViewListState();
}

class _RosterViewListState extends State<_RosterViewList>
    with AutomaticKeepAliveClientMixin, ScrollAnchorSupport {
  @override
  bool get wantKeepAlive => true;

  // dispose 期間 context 已經查不到 InheritedWidget，所以進場時就把 provider
  // 抓在手上，撤銷登記時才有東西可用。
  late final RosterProvider _provider;

  @override
  void initState() {
    super.initState();
    _provider = context.read<RosterProvider>();
    _provider.registerScrollAnchorCapture(widget.type, captureScrollAnchor);
    // 從編輯模式切回來時，把當初頂端那一天挪回原本的位置。
    final anchor = _provider.scrollAnchorFor(widget.type);
    if (anchor != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => restoreScrollAnchor(anchor),
      );
    }
  }

  @override
  void dispose() {
    _provider.unregisterScrollAnchorCapture(widget.type, captureScrollAnchor);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    // 只訂閱這個牧區的清單。getRostersByType 有快取，資料沒變時回傳同一個
    // List instance，所以其他牧區被編輯、或單純的 loading 開關都不會重建這頁。
    final rosters = context.select<RosterProvider, List<ServiceRoster>>(
      (provider) => provider.getRostersByType(widget.type),
    );

    if (rosters.isEmpty) {
      // 能編輯的人第一次進來看到空表，要知道從哪裡開始，而不是「等管理員」。
      final canEdit = context.select<SessionProvider, bool>(
        (session) => session.canEditRoster,
      );
      return EmptyState(
        icon: Icons.event_busy_outlined,
        message: '此類別目前沒有服事資訊',
        hint: canEdit
            ? '按上方的「編輯」開始：先按「服事項目」新增服事項目，再到各日期按「新增服事項目」排班，或用「排班模式」一次排整季、整年。'
            : '管理員建立後會在這裡顯示',
      );
    }

    // 事件選項換過就要重建（標籤顏色是從 provider 查的，不在 roster 裡）。
    context.select<RosterProvider, int>(
      (provider) => provider.eventOptionsRevision,
    );
    // 一個 tear-off 重複用，不要在 itemBuilder 裡每張卡各配一個 closure。
    final resolveEventColor = context.read<RosterProvider>().eventColorOf;

    final userId = context.select<SessionProvider, String?>(
      (session) => session.currentUser?.id,
    );
    final userName = context.select<SessionProvider, String?>(
      (session) => session.currentUser?.name,
    );
    // 服事項目設定的順序，卡片與表格都照它排。
    final roleOrder = context.select<RosterProvider, List<String>>(
      (provider) => provider.templates[widget.type] ?? const <String>[],
    );
    final shown = widget.mineOnly
        ? rosters
              .where(
                (r) => rolesForUser(
                  r,
                  userId: userId,
                  userName: userName,
                ).isNotEmpty,
              )
              .toList()
        : rosters;

    final Widget body;
    if (shown.isEmpty) {
      body = const EmptyState(
        icon: Icons.event_available_outlined,
        message: '這段期間沒有排到你的服事',
        hint: '再按一次上方的「只看我的」，可以回到完整的服事表',
      );
    } else if (widget.tableMode) {
      body = RosterTableView(
        rosters: shown,
        userId: userId,
        userName: userName,
        roleOrder: roleOrder,
      );
    } else {
      body = ListView.builder(
        key: anchorListKey,
        controller: anchorController,
        padding: const EdgeInsets.only(top: 12, bottom: 20),
        itemCount: shown.length,
        itemBuilder: (context, index) {
          final roster = shown[index];
          return ScrollAnchorItem(
            key: ValueKey(roster.id),
            id: roster.id,
            child: RosterViewCard(
              roster: roster,
              // 最近兩週先打開：同工最常看的就是這週和下週。
              initiallyExpanded: index < 2,
              resolveEventColor: resolveEventColor,
              userId: userId,
              userName: userName,
              roleOrder: roleOrder,
            ),
          );
        },
      );
    }

    return body;
  }
}

/// 「總覽」分頁：所有聚會一起看。卡片模式一天一張卡（一個聚會一段），
/// 表格模式一個聚會一張表疊在一起。
class _RosterOverviewList extends StatelessWidget {
  const _RosterOverviewList({
    super.key,
    required this.types,
    required this.tableMode,
    required this.mineOnly,
  });

  final List<ServiceType> types;
  final bool tableMode;
  final bool mineOnly;

  @override
  Widget build(BuildContext context) {
    final all = context.select<RosterProvider, List<ServiceRoster>>(
      (provider) => provider.rosters,
    );
    context.select<RosterProvider, int>(
      (provider) => provider.eventOptionsRevision,
    );
    final provider = context.read<RosterProvider>();
    final roleOrderByType = {
      for (final type in types) type: provider.templates[type] ?? const <String>[],
    };
    final userId = context.select<SessionProvider, String?>(
      (session) => session.currentUser?.id,
    );
    final userName = context.select<SessionProvider, String?>(
      (session) => session.currentUser?.name,
    );
    bool mine(ServiceRoster r) =>
        rolesForUser(r, userId: userId, userName: userName).isNotEmpty;

    final typeIndex = {for (var i = 0; i < types.length; i++) types[i]: i};
    final byDate = <DateTime, List<ServiceRoster>>{};
    for (final r in all) {
      if (!typeIndex.containsKey(r.type)) continue;
      final day = DateTime(r.date.year, r.date.month, r.date.day);
      (byDate[day] ??= []).add(r);
    }
    final days = byDate.keys.toList()..sort();
    for (final list in byDate.values) {
      list.sort((a, b) => typeIndex[a.type]!.compareTo(typeIndex[b.type]!));
    }
    final shownDays = mineOnly
        ? days.where((d) => byDate[d]!.any(mine)).toList()
        : days;

    if (shownDays.isEmpty) {
      return EmptyState(
        icon: mineOnly
            ? Icons.event_available_outlined
            : Icons.event_busy_outlined,
        message: mineOnly ? '這段期間沒有排到你的服事' : '目前沒有服事資訊',
      );
    }

    if (tableMode) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
        children: [
          for (final type in types) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
              child: Text(
                type.serviceName,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            _overviewTable(
              rosters: [
                for (final d in shownDays)
                  ...byDate[d]!.where(
                    (r) => r.type == type && (!mineOnly || mine(r)),
                  ),
              ],
              userId: userId,
              userName: userName,
              roleOrder: roleOrderByType[type]!,
            ),
          ],
        ],
      );
    }

    final resolveEventColor = provider.eventColorOf;
    return ListView.builder(
      padding: const EdgeInsets.only(top: 12, bottom: 20),
      itemCount: shownDays.length,
      itemBuilder: (context, index) {
        final day = shownDays[index];
        return RosterOverviewCard(
          key: ValueKey('overview-$day'),
          rosters: byDate[day]!,
          resolveEventColor: resolveEventColor,
          initiallyExpanded: index < 2,
          userId: userId,
          userName: userName,
          roleOrderByType: roleOrderByType,
        );
      },
    );
  }

  Widget _overviewTable({
    required List<ServiceRoster> rosters,
    required String? userId,
    required String? userName,
    required List<String> roleOrder,
  }) {
    final hasPeople = rosters.any((r) => r.duties.any((d) => d.people.isNotEmpty));
    if (!hasPeople) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text('尚未排班', style: TextStyle(color: Colors.grey[600])),
      );
    }
    return RosterTableView(
      rosters: rosters,
      userId: userId,
      userName: userName,
      roleOrder: roleOrder,
      embedded: true,
    );
  }
}
