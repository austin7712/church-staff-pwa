import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/roster_view_model.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import '../providers/roster_provider.dart';
import '../../../auth/presentation/providers/user_admin_provider.dart';
import '../../../../core/widgets/settings_bottom_sheet.dart';
import '../../../../core/widgets/text_controller_scope.dart';
import '../write_failure.dart';

/// 部分失敗時接在後面的話：設定本身寫進去了，只有幾天的服事表沒同步到新
/// 名稱。再存一次會補上 —— 改過的那幾天已經沒有舊名稱可以換，不會重複改。
const _partialSaveNote = '設定本身已儲存，再按一次儲存會補上';

class RoleSettingsScreen extends StatefulWidget {
  const RoleSettingsScreen({super.key});

  @override
  State<RoleSettingsScreen> createState() => _RoleSettingsScreenState();
}

class _RoleSettingsScreenState extends State<RoleSettingsScreen> {
  late Map<ServiceType, List<String>> _editingTemplates;
  late Map<ServiceType, Map<String, String>> _renamedRolesByType;
  late final Map<ServiceType, ScrollController> _scrollControllers;
  ScrollController? _worshipScroll;

  @override
  void initState() {
    super.initState();
    final provider = context.read<RosterProvider>();
    _editingTemplates = Map.fromIterables(
      provider.templates.keys,
      provider.templates.values.map((list) => List<String>.from(list)),
    );
    _renamedRolesByType = {
      for (final type in ServiceType.values) type: <String, String>{},
    };
    _scrollControllers = {
      for (final type in ServiceType.values) type: ScrollController(),
    };
    // 開頁時就記下來：之後的編輯不能影響「原本是誰包含誰」。
    _coverAtOpen.length;
    _childRolesAtOpen.length;
  }

  /// 主日崇拜包含兒童主日等項目時（見 [coveringServices]）：那一頁叫「總覽」、
  /// 放第一個，跟服事表一致。子分頁（兒童主日…）只是總覽的一部分。
  late final Map<String, String> _coverAtOpen = coveringServices({
    for (final MapEntry(key: t, value: roles) in _editingTemplates.entries)
      t.name: roles,
  });

  /// 分頁：總覽（主日崇拜全部）→ 主日（只有崇拜本身的項目）→ 兒童主日…，
  /// 其他獨立的聚會照原本順序。
  List<_RoleTab> get _tabs {
    final parents = _coverAtOpen.values.toSet();
    final active = ServiceType.active;
    return [
      for (final t in active.where((t) => parents.contains(t.name))) ...[
        _RoleTab('總覽', t),
        _RoleTab(t.label, t, worshipOnly: true),
      ],
      for (final t in active.where((t) => !parents.contains(t.name)))
        _RoleTab(t.label, t),
    ];
  }

  /// 「主日」分頁不放的項目：被兒童主日等分頁拿去的那幾項。
  Set<String> _childRolesOf(ServiceType parent) => {
    for (final MapEntry(key: child, value: p) in _coverAtOpen.entries)
      if (p == parent.name) ...?_editingTemplates[ServiceType(child)],
  };

  /// 某個分頁看到的項目，以及每一項在聚會樣板裡的位置。
  (List<String>, List<int>) _rolesForTab(_RoleTab tab) {
    final all = _editingTemplates[tab.type] ?? const <String>[];
    if (!tab.worshipOnly) return (all, [for (var i = 0; i < all.length; i++) i]);
    final hidden = _childRolesOf(tab.type);
    final idx = [
      for (var i = 0; i < all.length; i++)
        if (!hidden.contains(all[i])) i,
    ];
    return ([for (final i in idx) all[i]], idx);
  }

  late final Map<String, Set<String>> _childRolesAtOpen = {
    for (final child in _coverAtOpen.keys)
      child: {...?_editingTemplates[ServiceType(child)]},
  };

  /// 子分頁「新增」的項目也要在總覽裡，不然兒童主日等分頁看不到資料。
  /// 在總覽刪掉的不會被加回來。
  void _syncChildRolesIntoParent() {
    for (final MapEntry(key: child, value: parent) in _coverAtOpen.entries) {
      final childRoles = [
        for (final r in _editingTemplates[ServiceType(child)] ?? const <String>[])
          if (!_childRolesAtOpen[child]!.contains(r)) r,
      ];
      final parentRoles = _editingTemplates.putIfAbsent(
        ServiceType(parent),
        () => <String>[],
      );
      for (final role in childRoles) {
        if (!parentRoles.contains(role)) parentRoles.add(role);
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    _worshipScroll?.dispose();
    super.dispose();
  }

  Future<void> _promptAddRole(ServiceType type, {int? insertAt}) async {
    // controller 由 TextControllerScope 在 bottom sheet 子樹卸載時 dispose。
    final controller = TextEditingController();
    final name = await _showRoleNameDialog(
      title: '新增項目',
      controller: controller,
      existing: _editingTemplates[type] ?? const <String>[],
    );
    if (name == null) return;
    setState(() {
      final list = _editingTemplates[type] ??= [];
      if (insertAt != null && insertAt <= list.length) {
        list.insert(insertAt, name);
      } else {
        list.add(name);
      }
    });
  }

  void _removeRole(ServiceType type, int index) {
    setState(() {
      _editingTemplates[type]?.removeAt(index);
    });
  }

  Future<void> _promptEditRole(ServiceType type, int index) async {
    final current = _editingTemplates[type]?[index] ?? '';
    final controller = TextEditingController(text: current);
    final name = await _showRoleNameDialog(
      title: '編輯項目',
      controller: controller,
      existing: _editingTemplates[type] ?? const <String>[],
      currentName: current,
    );
    if (name == null) return;
    _trackRoleRename(type, current, name);
    _updateRole(type, index, name);
  }

  void _trackRoleRename(ServiceType type, String oldName, String newName) {
    final from = oldName.trim();
    final to = newName.trim();
    if (from.isEmpty || to.isEmpty || from == to) return;

    final mapping = _renamedRolesByType[type]!;
    var original = from;
    for (final entry in mapping.entries) {
      if (entry.value == from) {
        original = entry.key;
        break;
      }
    }

    mapping.remove(from);
    if (original == to) {
      mapping.remove(original);
      return;
    }
    mapping[original] = to;
  }

  Future<void> _confirmRemoveRole(ServiceType type, int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('確認刪除'),
        content: const Text('今天以後每一週的服事表都會拿掉這一項，已經排的人也會一起刪掉。已經過去的服事表不會動。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      _removeRole(type, index);
    }
  }

  Future<String?> _showRoleNameDialog({
    required String title,
    required TextEditingController controller,
    required List<String> existing,
    String? currentName,
  }) async {
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) {
        String? errorText;
        String? validateValue(String value) {
          final trimmed = value.trim();
          if (trimmed.isEmpty) return '請輸入名稱';
          final isDuplicate = existing.any(
            (name) =>
                name.trim() == trimmed && name.trim() != currentName?.trim(),
          );
          if (isDuplicate) return '名稱已存在';
          return null;
        }

        void submit(StateSetter setState) {
          final value = controller.text;
          final validation = validateValue(value);
          if (validation != null) {
            setState(() => errorText = validation);
            return;
          }
          Navigator.pop(context, value.trim());
        }

        return TextControllerScope(
          controller: controller,
          child: StatefulBuilder(
            builder: (context, setState) {
              return SettingsBottomSheet(
                title: title,
                onSubmit: () => submit(setState),
                child: TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    labelText: '服事項目名稱',
                    hintText: '例：敬拜主領',
                    hintStyle: TextStyle(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.35),
                    ),
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    border: const OutlineInputBorder(),
                    errorText: errorText,
                  ),
                  onChanged: (value) =>
                      setState(() => errorText = validateValue(value)),
                  onSubmitted: (_) => submit(setState),
                ),
              );
            },
          ),
        );
      },
    );
    return result;
  }

  void _updateRole(ServiceType type, int index, String value) {
    setState(() {
      _editingTemplates[type]?[index] = value;
    });
  }

  /// 有沒有還沒按 ✓ 的變更。
  bool get _hasUnsavedChanges {
    final saved = context.read<RosterProvider>().templates;
    for (final type in ServiceType.values) {
      final editing = _editingTemplates[type] ?? const <String>[];
      final original = saved[type] ?? const <String>[];
      if (editing.length != original.length) return true;
      for (var i = 0; i < editing.length; i++) {
        if (editing[i] != original[i]) return true;
      }
    }
    return false;
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('還沒儲存'),
        content: const Text('剛才的變更還沒儲存。要儲存的話，請按右上角 ✓。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('繼續編輯'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('不儲存，離開'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // 新增完項目按左上角返回，以前會不聲不響地丟掉。✓ 的 Navigator.pop
    // 不經過 PopScope，存好之後照常離開。
    return PopScope(
      canPop: !_hasUnsavedChanges,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: DefaultTabController(
        length: _tabs.length,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('服事項目設定'),
            bottom: TabBar(
              isScrollable: _tabs.length > 4,
              tabs: _tabs.map((tab) => Tab(text: tab.label)).toList(),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.check),
                onPressed: () async {
                  final rosterProvider = context.read<RosterProvider>();
                  final userAdminProvider = context.read<UserAdminProvider>();
                  final messenger = ScaffoldMessenger.of(context);
                  // 失敗一律留在這頁：改到一半的設定還在，再按一次就能重送。
                  PartialUpdateException? partial;
                  _syncChildRolesIntoParent();
                  try {
                    await rosterProvider.updateTemplates(
                      _editingTemplates,
                      renamedRolesByType: _renamedRolesByType,
                    );
                  } on PartialUpdateException catch (e) {
                    // 樣板已經寫進去了，只是有幾天的服事表沒改到名。同工設定
                    // 照樣要跟著新樣板清，不然兩邊對不上。
                    partial = e;
                  } catch (e) {
                    // 樣板沒寫進去就不清同工設定。以前寫失敗也照清，同工的服事
                    // 被新樣板刪掉，樣板本身卻還是舊的。
                    showWriteFailure(messenger, '儲存', e);
                    return;
                  }
                  try {
                    await userAdminProvider.cleanupUserMinistries(
                      _editingTemplates,
                    );
                  } catch (e) {
                    showWriteFailure(messenger, '儲存', e);
                    return;
                  }
                  if (partial != null) {
                    showWriteFailure(
                      messenger,
                      '儲存',
                      partial,
                      partialNote: _partialSaveNote,
                    );
                    return;
                  }
                  if (!context.mounted) return;
                  Navigator.pop(context);
                },
              ),
            ],
          ),
          body: TabBarView(
            children: _tabs.map((tab) {
              final type = tab.type;
              final (roles, positions) = _rolesForTab(tab);
              final scrollController = tab.worshipOnly
                  ? (_worshipScroll ??= ScrollController())
                  : _scrollControllers[type]!;
              return Column(
                children: [
                  // 新教會第一次打開是一片空白，連「新增項目」在左下角都不容易看到。
                  if (roles.isEmpty)
                    Expanded(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            '這個聚會還沒有服事項目。\n按左下角「新增項目」加入，例如「招待」「司琴」，'
                            '全部加好後按右上角 ✓ 儲存。',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: Scrollbar(
                        controller: scrollController,
                        thumbVisibility: true,
                        trackVisibility: true,
                        child: PrimaryScrollController(
                          controller: scrollController,
                          child: ReorderableListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: roles.length,
                            onReorder: (oldIndex, newIndex) {
                              setState(() {
                                if (newIndex > oldIndex) {
                                  newIndex -= 1;
                                }
                                final visible = List<String>.from(roles);
                                final item = visible.removeAt(oldIndex);
                                visible.insert(newIndex, item);
                                // 只動這一頁看得到的項目，其他項目留在原位。
                                final all = List<String>.from(
                                  _editingTemplates[type] ?? const <String>[],
                                );
                                for (var k = 0; k < positions.length; k++) {
                                  all[positions[k]] = visible[k];
                                }
                                _editingTemplates[type] = all;
                              });
                            },
                            itemBuilder: (context, index) {
                              return ListTile(
                                key: ValueKey(
                                  'role_${tab.label}_${type.name}_${roles[index]}',
                                ),
                                title: Text(roles[index]),
                                onTap: () =>
                                    _promptEditRole(type, positions[index]),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () =>
                                          _confirmRemoveRole(
                                            type,
                                            positions[index],
                                          ),
                                    ),
                                    ReorderableDragStartListener(
                                      index: index,
                                      child: const Icon(Icons.drag_handle),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  SafeArea(
                    top: false,
                    child: ListTile(
                      leading: const Icon(Icons.add),
                      title: const Text('新增項目'),
                      onTap: () => tab.worshipOnly && positions.isNotEmpty
                          ? _promptAddRole(type, insertAt: positions.last + 1)
                          : _promptAddRole(type),
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

class _RoleTab {
  const _RoleTab(this.label, this.type, {this.worshipOnly = false});

  final String label;
  final ServiceType type;

  /// 「主日」分頁：同一份主日崇拜樣板，只是不顯示兒童主日等分頁的項目。
  final bool worshipOnly;
}
