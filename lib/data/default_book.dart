import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/controller.dart';
import 'importer.dart';

// The public exporter switches only this private-build selection. Existing
// collections are never migrated, deleted, or replaced by default-book setup.
const defaultBookAsset = licensedBookAsset;
const licensedBookAsset = 'assets/cet4-kylebing.txt';
const licensedBookTitle = '四级词汇 · KyleBing（完整乱序）';
const licensedBookAttribution =
    'KyleBing/english-vocabulary · Copyright (c) 2022-2026, KyleBing · BSD-3-Clause';
bool _licenseRegistered = false;

void registerBookLicenses() {
  if (_licenseRegistered) return;
  _licenseRegistered = true;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      ['KyleBing/english-vocabulary'],
      await rootBundle.loadString('assets/KYLEBING-LICENSE.txt'),
    );
  });
}

Future<void> ensurePersonalBook(AppController controller) async {
  registerBookLicenses();
  if (!controller.ready || controller.state.books.isNotEmpty) return;
  var asset = defaultBookAsset;
  String text;
  try {
    text = await rootBundle.loadString(asset);
  } on FlutterError {
    // Personal asset absent: use the complete licensed offline book, never demo.
    asset = licensedBookAsset;
    text = await rootBundle.loadString(asset);
  }
  final licensed = asset == licensedBookAsset;
  final preview = ImportParser.parse(
    text,
    asset,
    title: licensed ? licensedBookTitle : null,
    source: licensed ? licensedBookAttribution : null,
  );
  await controller.importBook(preview);
}
