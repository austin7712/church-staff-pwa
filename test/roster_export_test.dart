import 'dart:convert';
import 'dart:io';

import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/core/utils/xlsx_writer.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';
import 'package:church_staff_pwa/features/roster/domain/roster_export.dart';
import 'package:flutter_test/flutter_test.dart';

ServiceRoster _r(
  String id,
  DateTime date,
  Map<String, List<String>> duties, {
  ServiceType type = ServiceType.sundayService,
  List<String> events = const [],
}) => ServiceRoster(
  id: id,
  date: date,
  type: type,
  serviceName: '主日崇拜',
  specialEvents: events,
  duties: [
    for (final MapEntry(key: role, value: people) in duties.entries)
      RosterEntry(role: role, people: people),
  ],
);

void main() {
  test('同一天的聚會合併成一列，欄位照服事項目設定排，待定留白', () {
    final rows = rosterExportRows(
      [
        _r('b', DateTime.utc(2027, 1, 10), {
          '音控': ['Joe'],
        }),
        _r('a', DateTime.utc(2027, 1, 3), {
          '收奉': ['Grace', 'Kevin'],
          '音控': ['待定'],
        }, events: ['聖餐']),
        _r('k', DateTime.utc(2027, 1, 3), {
          '兒童主日': ['Joy'],
        }, type: ServiceType.children),
      ],
      roleOrder: ['音控', '奉獻點算', '兒童主日'],
    );
    expect(rows.first, ['日期', '星期', '特別活動', '音控', '奉獻點算', '兒童主日']);
    expect(rows[1], ['2027/1/3', '日', '聖餐', '', 'Grace、Kevin', 'Joy']);
    expect(rows[2], ['2027/1/10', '日', '', 'Joe', '', '']);
  });

  test('crc32 正確', () {
    expect(crc32(utf8.encode('123456789')), 0xCBF43926);
  });

  test('產生的 xlsx 是合法的 zip，內容讀得回來', () async {
    final bytes = buildXlsx([
      ['日期', '音控'],
      ['2027/1/3', 'A & <B>'],
    ], sheetName: '2027 服事表', widths: [10, 12]);
    expect(bytes.sublist(0, 2), [0x50, 0x4b]);

    // 用 python 的 zipfile 驗（CI 的 ubuntu 有 python3；沒有就跳過）。
    final dir = await Directory.systemTemp.createTemp('xlsx');
    final file = File('${dir.path}/t.xlsx')..writeAsBytesSync(bytes);
    ProcessResult result;
    try {
      result = await Process.run('python3', [
        '-c',
        'import sys,zipfile,xml.dom.minidom as m\n'
            'z=zipfile.ZipFile(sys.argv[1])\n'
            'assert z.testzip() is None\n'
            'for n in z.namelist(): m.parseString(z.read(n))\n'
            'print(z.read("xl/worksheets/sheet1.xml").decode())',
        file.path,
      ]);
    } on ProcessException {
      markTestSkipped('python3 not available');
      return;
    }
    await dir.delete(recursive: true);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('A &amp; &lt;B&gt;'));
    expect(result.stdout, contains('2027/1/3'));
  });
}
