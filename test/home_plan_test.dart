import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/data/storage.dart';
import 'package:wordnest/domain/controller.dart';
import 'package:wordnest/domain/models.dart';
import 'package:wordnest/features/home_page.dart';
import 'package:wordnest/platform/desktop_service.dart';

class FixedController extends AppController {
  FixedController(super.storage);
  @override
  DateTime get now => DateTime(2026, 10, 11, 15);
}

void main() {
  Future<FixedController> setup(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = FixedController(MemoryStorage());
    await c.initialize();
    await c.importBook(
      ImportPreview(
        book: WordBook(
          id: 'b',
          title: '计划词书',
          importedAt: c.now,
          members: [
            for (var i = 0; i < 101; i++)
              BookMember(entryId: 'w$i', unit: '1', position: i),
          ],
        ),
        entries: {
          for (var i = 0; i < 101; i++)
            'w$i': WordEntry(id: 'w$i', word: 'word$i', meaning: '词'),
        },
        total: 101,
        duplicates: 0,
        missingMeanings: 0,
        missingExamples: 101,
      ),
    );
    await c.updateSettings((s) => s.dailyNew = 50);
    addTearDown(c.dispose);
    return c;
  }

  Future<void> show(WidgetTester tester, AppController c) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: c,
            builder: (context, _) => HomePage(
              controller: c,
              onStart: (_) async {},
              onLibrary: () {},
              onWidget: () async {},
              desktop: DesktopService(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'no exam shows estimates and changes only persisted daily target',
    (tester) async {
      final c = await setup(tester);
      final roundSize = c.settings.roundSize;
      await show(tester, c);
      expect(find.text('每日新词 50 个'), findsOneWidget);
      expect(find.text('剩余新词 101 个'), findsOneWidget);
      expect(find.text('预计 3 天学完'), findsOneWidget);
      expect(find.text('预计完成日期 2026-10-13'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('edit-daily-new')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('daily-new-input')),
        '0',
      );
      await tester.tap(find.text('保存计划'));
      await tester.pumpAndSettle();
      expect(find.text('请输入大于 0 的整数'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('daily-new-input')),
        '1000',
      );
      await tester.tap(find.text('保存计划'));
      // Saving waits for the dialog's 300 ms exit cleanup before persistence.
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(c.settings.dailyNew, 1000);
      expect(c.settings.roundSize, roundSize);
      expect((await c.storage.load()).settings.dailyNew, 1000);
      expect(find.text('预计 1 天学完'), findsOneWidget);
      expect(find.text('预计完成日期 2026-10-11'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'reviews do not reduce new words; exam recommendation remains separate',
    (tester) async {
      final c = await setup(tester);
      await c.updateSettings((s) => s.examDate = '2026-10-13');
      c.state.cards['w0'] = ReviewCard(
        entryId: 'w0',
        due: c.now,
        seen: true,
        reviews: 30,
      );
      c.state.events.addAll([
        for (var i = 0; i < 30; i++)
          LearningEvent(
            id: 'e$i',
            entryId: 'w0',
            kind: 'formal',
            at: c.now,
            correct: true,
          ),
      ]);
      await show(tester, c);
      expect(find.text('剩余新词 100 个'), findsOneWidget);
      expect(find.text('预计 2 天学完'), findsOneWidget);
      expect(find.text('距考试 2 天 · 倒推推荐每日新词 50 个'), findsOneWidget);
      await c.updateSettings((s) => s.dailyNew = 10);
      await tester.pumpAndSettle();
      expect(find.text('预计 10 天学完'), findsOneWidget);
      expect(find.text('距考试 2 天 · 倒推推荐每日新词 50 个'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('plan fits narrow home layout', (tester) async {
    final c = await setup(tester);
    tester.view.physicalSize = const Size(390, 844);
    await show(tester, c);
    expect(tester.takeException(), isNull);
    expect(find.text('剩余新词 101 个'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
