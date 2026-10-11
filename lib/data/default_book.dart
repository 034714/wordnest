import 'package:flutter/services.dart';

import '../domain/controller.dart';
import 'importer.dart';

Future<void> ensureDemoBook(AppController controller) async {
  if (!controller.ready || controller.state.books.isNotEmpty) return;
  try {
    final json = await rootBundle.loadString('assets/demo.json');
    final preview = ImportParser.parse(json, 'demo.json');
    await controller.importBook(preview);
  } catch (_) {}
}
