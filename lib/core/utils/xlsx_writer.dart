import 'dart:convert';
import 'dart:typed_data';

/// 產生一個只有一張工作表的 .xlsx（Excel、Numbers、Google 試算表都打得開）。
///
/// 沒有用套件：只需要「一張表、全是文字、第一列粗體、凍結第一列」，手寫
/// 幾個 XML 加一個不壓縮的 zip 就夠了，不必為此多一個相依。
///
/// [widths] 是每一欄的寬度（Excel 的字元數）；沒給的欄用預設寬度。
Uint8List buildXlsx(
  List<List<String>> rows, {
  String sheetName = 'Sheet1',
  List<double> widths = const [],
}) {
  String esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      // XML 1.0 不允許的控制字元（換行、tab 除外）拿掉，否則 Excel 說檔案損毀。
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

  String col(int i) {
    var n = i + 1;
    var s = '';
    while (n > 0) {
      final r = (n - 1) % 26;
      s = String.fromCharCode(65 + r) + s;
      n = (n - 1) ~/ 26;
    }
    return s;
  }

  final sheet = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write(
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
    )
    ..write(
      '<sheetViews><sheetView workbookViewId="0">'
      '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>'
      '</sheetView></sheetViews>',
    );
  if (widths.isNotEmpty) {
    sheet.write('<cols>');
    for (var i = 0; i < widths.length; i++) {
      sheet.write(
        '<col min="${i + 1}" max="${i + 1}" width="${widths[i]}" customWidth="1"/>',
      );
    }
    sheet.write('</cols>');
  }
  sheet.write('<sheetData>');
  for (var r = 0; r < rows.length; r++) {
    sheet.write('<row r="${r + 1}">');
    for (var c = 0; c < rows[r].length; c++) {
      final value = rows[r][c];
      if (value.isEmpty) continue;
      final style = r == 0 ? ' s="1"' : '';
      sheet.write(
        '<c r="${col(c)}${r + 1}" t="inlineStr"$style>'
        '<is><t xml:space="preserve">${esc(value)}</t></is></c>',
      );
    }
    sheet.write('</row>');
  }
  sheet.write('</sheetData></worksheet>');

  final files = <String, String>{
    '[Content_Types].xml':
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '</Types>',
    '_rels/.rels':
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>',
    'xl/workbook.xml':
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="${esc(sheetName)}" sheetId="1" r:id="rId1"/></sheets>'
        '</workbook>',
    'xl/_rels/workbook.xml.rels':
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '</Relationships>',
    'xl/styles.xml':
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
        '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
        '<fills count="2"><fill><patternFill patternType="none"/></fill>'
        '<fill><patternFill patternType="gray125"/></fill></fills>'
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
        '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>'
        '</styleSheet>',
    'xl/worksheets/sheet1.xml': sheet.toString(),
  };
  return storedZip({
    for (final e in files.entries) e.key: utf8.encode(e.value),
  });
}

/// 不壓縮（stored）的 zip。公開給測試用。
Uint8List storedZip(Map<String, List<int>> files) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var offset = 0;

  void u16(BytesBuilder b, int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
  void u32(BytesBuilder b, int v) => b.add([
    v & 0xff,
    (v >> 8) & 0xff,
    (v >> 16) & 0xff,
    (v >> 24) & 0xff,
  ]);

  for (final e in files.entries) {
    final name = utf8.encode(e.key);
    final data = e.value;
    final crc = crc32(data);

    final local = BytesBuilder();
    u32(local, 0x04034b50);
    u16(local, 20); // version needed
    u16(local, 0x0800); // flags: UTF-8 names
    u16(local, 0); // stored
    u16(local, 0); // time
    u16(local, 0x21); // date 1980-01-01
    u32(local, crc);
    u32(local, data.length);
    u32(local, data.length);
    u16(local, name.length);
    u16(local, 0);
    local.add(name);
    local.add(data);
    final localBytes = local.takeBytes();

    u32(central, 0x02014b50);
    u16(central, 20); // version made by
    u16(central, 20);
    u16(central, 0x0800);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0x21);
    u32(central, crc);
    u32(central, data.length);
    u32(central, data.length);
    u16(central, name.length);
    u16(central, 0); // extra
    u16(central, 0); // comment
    u16(central, 0); // disk
    u16(central, 0); // internal attrs
    u32(central, 0); // external attrs
    u32(central, offset);
    central.add(name);

    out.add(localBytes);
    offset += localBytes.length;
  }
  final centralBytes = central.takeBytes();
  out.add(centralBytes);
  final end = BytesBuilder();
  u32(end, 0x06054b50);
  u16(end, 0);
  u16(end, 0);
  u16(end, files.length);
  u16(end, files.length);
  u32(end, centralBytes.length);
  u32(end, offset);
  u16(end, 0);
  out.add(end.takeBytes());
  return out.takeBytes();
}

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc = _crcTable[(crc ^ b) & 0xff] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
