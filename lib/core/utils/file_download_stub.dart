import 'dart:typed_data';

const bool canDownloadFiles = false;

void downloadFile(Uint8List bytes, String fileName, String mimeType) {
  throw UnsupportedError('這個版本不支援下載檔案');
}
