import 'dart:typed_data';

import 'file_download_stub.dart'
    if (dart.library.js_interop) 'file_download_web.dart'
    as impl;

/// 這個平台能不能直接下載檔案（網頁版可以）。
bool get canDownloadFiles => impl.canDownloadFiles;

/// 讓瀏覽器下載 [bytes]，存成 [fileName]。
void downloadFile(Uint8List bytes, String fileName, String mimeType) =>
    impl.downloadFile(bytes, fileName, mimeType);
