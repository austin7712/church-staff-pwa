import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

const bool canDownloadFiles = true;

void downloadFile(Uint8List bytes, String fileName, String mimeType) {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  // 有些瀏覽器 click 之後才開始讀 blob，晚一點再釋放。
  Future<void>.delayed(
    const Duration(seconds: 30),
    () => web.URL.revokeObjectURL(url),
  );
}
