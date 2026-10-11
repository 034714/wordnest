import 'dart:io';

import 'package:path/path.dart' as p;

String get nativeExecutablePath => Platform.resolvedExecutable;

String notificationIconPath() {
  final path = p.join(
    p.dirname(Platform.resolvedExecutable),
    'data',
    'flutter_assets',
    'assets',
    'tray.ico',
  );
  return File(path).existsSync() ? path : '';
}
