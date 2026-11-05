part of 'roster_card.dart';

/// 編輯模式的「表格」：像 Excel 一樣，點一格就改那一天、那一項服事的人。
///
/// 選人視窗、候選名單與存檔都跟卡片編輯同一套（[_RosterPeopleDialog]、
/// [_loadSelectablePeopleFor]、[_saveRoster]），所以兩邊改出來的資料一樣。
class RosterEditTable extends StatelessWidget {
  const RosterEditTable({
    super.key,
    required this.type,
    required this.rosters,
    this.onSaved,
  });

  final ServiceType type;
  final List<ServiceRoster> rosters;

  /// 存成功後通知（排班模式用來更新自己那份資料；一般編輯模式不用，
  /// provider 會自己更新）。
  final ValueChanged<ServiceRoster>? onSaved;

  static final _dateFormat = DateFormat('M/d (EEEEE)', 'zh_TW');

  @override
  Widget build(BuildContext context) {
    final roles = context.select<RosterProvider, List<String>>(
      (provider) => provider.templates[type] ?? const <String>[],
    );
    return RosterTableView(
      rosters: rosters,
      alwaysShowRoles: roles,
      showCounts: true,
      onCellTap: (row, column) =>
          _editCell(context, row.roster, roleForCell(row, column)),
    );
  }

  Future<void> _editCell(
    BuildContext context,
    ServiceRoster roster,
    String role,
  ) async {
    final index = roster.duties.indexWhere((d) => d.role == role);
    final existing = index >= 0 ? roster.duties[index] : null;

    Future<_PeopleOptions> peopleLoader(String? _) => _loadSelectablePeopleFor(
      context,
      roster.type,
      existing?.people ?? const [],
      role,
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return _RosterPeopleDialog(
          title: '${_dateFormat.format(roster.date)}　$role',
          rosterType: roster.type,
          initialRoleText: role,
          roleOptions: const [],
          initialRole: role,
          peopleLoader: peopleLoader,
          initialPeople: existing == null || existing.people.isEmpty
              ? const [placeholderPerson]
              : existing.people,
          initialPersonIdsByName: existing?.personIdsByName ?? const {},
          onSubmit: (selection) async {
            final duties = List<RosterEntry>.from(roster.duties);
            if (index >= 0) {
              duties[index] = duties[index].copyWith(
                people: selection.people,
                personIdsByName: selection.personIdsByName,
              );
            } else {
              duties.add(
                RosterEntry(
                  role: role,
                  people: selection.people,
                  personIdsByName: selection.personIdsByName,
                ),
              );
            }
            final updated = roster.copyWith(duties: duties);
            final ok = await _saveRoster(
              context,
              updated,
              ranking: selection.ranking,
            );
            if (ok) onSaved?.call(updated);
          },
          submitLabel: '儲存',
          roleEditable: false,
          useBottomSheet: true,
        );
      },
    );
  }
}
