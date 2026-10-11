import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/data/default_book.dart';
import 'package:wordnest/data/storage.dart';
import 'package:wordnest/domain/controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('public demo is available on first launch and not duplicated', () async {
    final controller = AppController(MemoryStorage());
    await controller.initialize();
    await ensureDemoBook(controller);
    expect(controller.state.books, hasLength(1));
    expect(controller.state.entries, hasLength(24));
    expect(controller.state.books.single.members, hasLength(24));
    expect(controller.state.books.single.units, hasLength(3));
    await ensureDemoBook(controller);
    expect(controller.state.books, hasLength(1));
    expect(controller.settings.roundSize, 50);
    expect(controller.settings.theme, 'dark');
    controller.dispose();
  });
}
