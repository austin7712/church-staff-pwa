import 'package:flutter/material.dart';

/// 服事表檢視模式的顏色。刻意各用不同色系，不可混用：
/// - 綠色：我自己的服事
/// - 黃色：聯合崇拜（跟紙本／Excel 服事表的黃底一致）
/// - 灰色：台語堂負責等佔位字
const Color kRosterMeFill = Color(0xFFD3EFDD);
const Color kRosterMeBorder = Color(0xFF2E8B57);
const Color kRosterMeText = Color(0xFF14532D);

const Color kRosterCombinedFill = Color(0xFFFFF8DB);
const Color kRosterCombinedBorder = Color(0xFFE9C84A);
const Color kRosterCombinedText = Color(0xFF6B5200);

const Color kRosterPlaceholderFill = Color(0xFFEEF1F5);
const Color kRosterPlaceholderText = Color(0xFF5B6573);

/// 「台」「華」兩行的標籤色。
const Color kRosterLaneTw = Color(0xFF8A4B12);
const Color kRosterLaneMw = Color(0xFF2F5D8A);

/// 同一天重複排到（只有編輯表格會標）。
const Color kRosterConflict = Color(0xFFC62828);
