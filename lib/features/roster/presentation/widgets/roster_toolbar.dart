import 'package:flutter/material.dart';

/// 服事表標題列下方的工具列：每個按鈕都有圖示「加文字」，同工才知道按了
/// 會做什麼。放不下時可以左右滑，不會被擠出畫面。
///
/// 檢視模式與編輯模式用同一個高度（[height]），切換模式時清單的起點不變，
/// 同一天才會停在同一個位置（見 roster_scroll_anchor_test）。
class RosterToolbar extends StatelessWidget {
  const RosterToolbar({super.key, required this.children});

  final List<Widget> children;

  static const double height = 48;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// 標題列的 bottom：工具列＋聚會分頁。
PreferredSizeWidget rosterAppBarBottom({
  required List<Widget> tools,
  PreferredSizeWidget? tabs,
}) {
  final tabsHeight = tabs?.preferredSize.height ?? 0;
  return PreferredSize(
    preferredSize: Size.fromHeight(RosterToolbar.height + tabsHeight),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RosterToolbar(children: tools),
        ?tabs,
      ],
    ),
  );
}

/// 卡片／表格切換（檢視與編輯模式共用）。
class RosterViewModeSwitch extends StatelessWidget {
  const RosterViewModeSwitch({
    super.key,
    required this.tableMode,
    required this.onChanged,
  });

  final bool tableMode;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment(
          value: false,
          label: Text('卡片'),
          icon: Icon(Icons.view_agenda_outlined, size: 16),
        ),
        ButtonSegment(
          value: true,
          label: Text('表格'),
          icon: Icon(Icons.table_rows_outlined, size: 16),
        ),
      ],
      selected: {tableMode},
      showSelectedIcon: false,
      onSelectionChanged: (selection) => onChanged(selection.first),
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
      ),
    );
  }
}

/// 工具列上有圖示也有文字的按鈕。
class RosterToolButton extends StatelessWidget {
  const RosterToolButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// 比按鈕文字更完整的說明（滑鼠停留／長按時顯示）。
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
    );
    final message = tooltip;
    return message == null ? button : Tooltip(message: message, child: button);
  }
}
