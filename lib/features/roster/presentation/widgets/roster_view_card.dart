import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../domain/entities/service_roster.dart';
import '../../domain/roster_view_model.dart';
import 'duty_row.dart';
import 'roster_view_colors.dart';

class RosterViewCard extends StatefulWidget {
  final ServiceRoster roster;
  final bool initiallyExpanded;
  final int Function(ServiceRoster roster, String event) resolveEventColor;

  /// 目前登入的同工。用來在卡片上標出「我」的服事；不傳就不標。
  final String? userId;
  final String? userName;

  const RosterViewCard({
    super.key,
    required this.roster,
    required this.resolveEventColor,
    this.initiallyExpanded = false,
    this.userId,
    this.userName,
    this.roleOrder = const [],
  });

  /// 服事項目的顯示順序（服事項目設定的順序）。
  final List<String> roleOrder;

  @override
  State<RosterViewCard> createState() => _RosterViewCardState();
}

class _RosterViewCardState extends State<RosterViewCard> {
  static final _dateFormat = DateFormat('yyyy/MM/dd (EEEEE)', 'zh_TW');

  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final roster = widget.roster;
    final combined = isCombinedService(roster);
    final myRoles = rolesForUser(
      roster,
      userId: widget.userId,
      userName: widget.userName,
    );
    final myNames = namesForUser(
      roster,
      userId: widget.userId,
      userName: widget.userName,
    );
    final summary = rosterSummary(roster);

    final BorderSide side;
    if (combined) {
      side = const BorderSide(color: kRosterCombinedBorder, width: 1.5);
    } else if (myRoles.isNotEmpty) {
      side = const BorderSide(color: kRosterMeBorder, width: 1.5);
    } else {
      side = BorderSide.none;
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 2.0,
      color: combined ? kRosterCombinedFill : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: side,
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey(roster.id),
        initiallyExpanded: widget.initiallyExpanded,
        onExpansionChanged: (value) => setState(() => _expanded = value),
        // 卡片本身已經有圓角與外框，ExpansionTile 展開時不要再畫一層線。
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(
          Icons.event_note,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: Text(
          _dateFormat.format(roster.date),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(roster.displayName),
                if (roster.specialEvents.isNotEmpty) const SizedBox(width: 8),
                if (roster.specialEvents.isNotEmpty)
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      children: [
                        ...roster.specialEvents.map((event) {
                          final color = Color(
                            widget.resolveEventColor(roster, event),
                          );
                          return Chip(
                            label: Text(
                              event,
                              style: TextStyle(
                                color: color,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            backgroundColor: color.withValues(alpha: 0.12),
                            side: BorderSide(
                              color: color.withValues(alpha: 0.4),
                            ),
                            padding: EdgeInsets.zero,
                            labelPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 0,
                            ),
                            visualDensity: const VisualDensity(
                              horizontal: -2,
                              vertical: -3,
                            ),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          );
                        }),
                      ],
                    ),
                  ),
              ],
            ),
            // 收起來也看得到重點，不用一張張點開。
            if (!_expanded && summary.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  summary,
                  style: TextStyle(fontSize: 13, color: Colors.grey[800]),
                ),
              ),
            if (myRoles.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: kRosterMeFill,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '你：${myRoles.join('、')}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: kRosterMeText,
                    ),
                  ),
                ),
              ),
          ],
        ),
        // 收合狀態下 ExpansionTile 會把 body 從樹上移除，所以獨立成 widget
        // 之後，看不到的服事列表就不會被 build。捲動時每張卡片只配置一個
        // widget 物件，而不是十幾列 Row/Text。
        children: [
          _RosterViewCardBody(
            roster: roster,
            myNames: myNames,
            roleOrder: widget.roleOrder,
          ),
        ],
      ),
    );
  }
}

/// [RosterViewCard] 展開後的服事項目列表。
class _RosterViewCardBody extends StatelessWidget {
  const _RosterViewCardBody({
    required this.roster,
    required this.myNames,
    required this.roleOrder,
  });

  final ServiceRoster roster;
  final Set<String> myNames;
  final List<String> roleOrder;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        children: dutiesInOrder(roster.duties, roleOrder).map((duty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            // dense：這裡沒有按鈕要撐觸控目標，列高就跟著文字走，一頁多看
            // 得到幾天。切換模式時的位移是靠錨定日期修的（見 [ScrollAnchor]），
            // 不必為此把檢視模式撐到跟編輯模式一樣高。
            child: DutyRow(
              role: duty.role,
              people: duty.people,
              dense: true,
              highlightedPeople: myNames,
              showPlaceholderLabels: true,
            ),
          );
        }).toList(),
      ),
    );
  }
}
