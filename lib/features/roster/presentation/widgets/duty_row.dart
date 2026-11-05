import 'package:flutter/material.dart';

import '../../domain/roster_view_model.dart';
import 'roster_view_colors.dart';

/// 編輯模式一列服事的最小高度。
///
/// 48 是那顆刪除 IconButton 的觸控目標高度，給長輩按的，不能再縮。檢視模式
/// 沒有按鈕，不吃這個下限（見 [DutyRow.dense]）—— 切換模式時的位移是靠錨定
/// 日期修的（見 `ScrollAnchor`），不是靠兩邊列高一樣。
const double kDutyRowMinHeight = 48.0;

/// 服事項目的一列：左邊項目名稱、中間人名、右邊（編輯模式才有的）操作按鈕。
///
/// 檢視卡片與編輯卡片共用這一份配置，差別只有 [dense]。
class DutyRow extends StatelessWidget {
  const DutyRow({
    super.key,
    required this.role,
    required this.people,
    this.roleColor,
    this.trailing = const [],
    this.dense = false,
    this.highlightedPeople = const {},
    this.showPlaceholderLabels = false,
  });

  final String role;

  /// 這一項的人。刻意收一份清單而不是排好的字串 —— 中文預設每個字都可以斷
  /// 行，接成一串丟給 Text 的話，欄寬不夠時會從名字中間切開（「陳美／麗」）。
  final List<String> people;

  final Color? roleColor;

  /// 放在最右邊的操作按鈕。檢視模式留空。
  final List<Widget> trailing;

  /// 檢視模式的排法：列高跟著文字走，不撐到 [kDutyRowMinHeight]。這個畫面是
  /// 拿來讀的，一頁看得到幾天比每列多出 25px 的留白重要。文字靠上對齊，名字
  /// 換行時項目名稱才不會跟著往下飄。
  final bool dense;

  /// 要特別標出來的名字（檢視模式標出「我」）。編輯模式不傳。
  final Set<String> highlightedPeople;

  /// 把「台語」顯示成灰色的「台語堂負責」，跟真的人名分開。只給檢視模式用。
  final bool showPlaceholderLabels;

  static const _nameStyle = TextStyle(fontSize: 16, fontWeight: FontWeight.bold);

  Widget _person(String person, bool isLast) {
    final sep = isLast ? '' : '、';
    if (highlightedPeople.contains(person)) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: kRosterMeFill,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: kRosterMeBorder, width: 1.5),
            ),
            child: Text(
              person,
              style: _nameStyle.copyWith(color: kRosterMeText),
            ),
          ),
          if (sep.isNotEmpty) const Text('、', style: _nameStyle),
        ],
      );
    }
    if (showPlaceholderLabels && isPlaceholderPerson(person)) {
      return Text(
        '${displayPersonName(person)}$sep',
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: Colors.grey[600],
        ),
      );
    }
    return Text('$person$sep', style: _nameStyle);
  }

  @override
  Widget build(BuildContext context) {
    final row = Row(
      crossAxisAlignment: dense
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            role,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: roleColor ?? Colors.grey[600],
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          // 一個名字一段（頓號跟在名字後面），斷行機會就只剩名字之間。
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 2,
            children: [
              for (var i = 0; i < people.length; i++)
                _person(people[i], i == people.length - 1),
            ],
          ),
        ),
        ...trailing,
      ],
    );
    if (dense) return row;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kDutyRowMinHeight),
      child: row,
    );
  }
}
