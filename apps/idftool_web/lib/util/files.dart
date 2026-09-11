import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

/// A file the user picked.
typedef PickedFile = ({String name, Uint8List bytes});

/// Let the user pick a file, optionally limited to [extensions] (without
/// dots). Returns `null` if they cancelled.
Future<PickedFile?> pickFile({List<String>? extensions}) async {
  final file = await FilePicker.pickFile(
    type: extensions == null ? FileType.any : FileType.custom,
    allowedExtensions: extensions,
  );
  if (file == null) return null;
  return (name: file.name, bytes: await file.readAsBytes());
}

/// Hand [bytes] to the user as [filename] — on the web that's a download,
/// elsewhere the platform share sheet (same approach as the FarmTRX apps).
Future<void> saveBytes(String filename, Uint8List bytes, {String mimeType = 'application/octet-stream'}) async {
  await SharePlus.instance.share(ShareParams(
    files: [XFile.fromData(bytes, name: filename, mimeType: mimeType)],
    fileNameOverrides: [filename],
  ));
}

Future<void> saveText(String filename, String text, {String mimeType = 'text/plain'}) =>
    saveBytes(filename, Uint8List.fromList(text.codeUnits), mimeType: mimeType);
