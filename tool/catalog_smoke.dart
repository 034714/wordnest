// Developer smoke check for the real (non-injected) catalog transport.
// Run: flutter pub run tool/catalog_smoke.dart   (or: dart run tool/catalog_smoke.dart)
import 'dart:io';

import 'package:wordnest/platform/catalog_service.dart';

Future<void> main() async {
  final service = CatalogService();
  final books = await service.list();
  stdout.writeln('books: ${books.length}');
  final target = books.firstWhere((b) => b.id == 'kylebing-cet4');
  stdout.writeln('fetching ${target.title} <- ${target.url}');
  try {
    final download = await service.fetch(target);
    stdout.writeln(
      'ok: ${download.filename} chars=${download.text.length} '
      'first=${download.text.split('\n').first}',
    );
  } on CatalogError catch (error) {
    stdout.writeln('catalog error: $error');
    exitCode = 1;
  } catch (error) {
    stdout.writeln('unexpected: $error');
    exitCode = 2;
  }
}
