import 'dart:io';

Future<void> appendLicenseDebugLogLine(String fileName, String line) async {
  final file = File('${Directory.systemTemp.path}/$fileName');
  await file.writeAsString(line, mode: FileMode.append, flush: true);
}
