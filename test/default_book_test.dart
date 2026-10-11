import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/data/default_book.dart';
import 'package:wordnest/data/importer.dart';
import 'package:wordnest/data/storage.dart';
import 'package:wordnest/domain/controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('bundled CET4 book is available on first launch and not duplicated', () async {
    // Expectations derive from whichever asset this build ships (personal or
    // public licensed book), so both trees keep a real regression check.
    String asset = defaultBookAsset;
    String text;
    try {
      text = await rootBundle.loadString(asset);
    } on FlutterError {
      asset = licensedBookAsset;
      text = await rootBundle.loadString(asset);
    }
    final expected = ImportParser.parse(text, asset);

    final controller = AppController(MemoryStorage());
    await controller.initialize();
    await ensurePersonalBook(controller);
    expect(controller.state.books, hasLength(1));
    expect(controller.state.entries, hasLength(expected.entries.length));
    expect(
      controller.state.books.single.members,
      hasLength(expected.book.members.length),
    );
    expect(
      controller.state.books.single.units,
      hasLength(expected.book.units.length),
    );
    await ensurePersonalBook(controller);
    expect(controller.state.books, hasLength(1));
    expect(controller.settings.roundSize, 50);
    expect(controller.settings.theme, 'dark');
    controller.dispose();
  });
}
