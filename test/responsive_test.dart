import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/app.dart';
import 'package:wordnest/data/storage.dart';
import 'package:wordnest/domain/controller.dart';
import 'package:wordnest/domain/models.dart';
import 'package:wordnest/features/home_page.dart';
import 'package:wordnest/features/library_page.dart';
import 'package:wordnest/features/settings_page.dart';
import 'package:wordnest/features/stats_page.dart';
import 'package:wordnest/features/study_page.dart';

void main() {
  Future<AppController> createController() async {
    final controller = AppController(MemoryStorage());
    await controller.initialize();

    final words = <WordEntry>{
      for (var index = 0; index < 24; index++)
        WordEntry(
          id: 'word-$index',
          word: 'word$index',
          meaning: '第 $index 个测试词条的中文释义',
          example: 'This is an example sentence for word $index.',
          exampleTranslation: '这是第 $index 个词条的例句。',
          uk: 'ˈwɜːd$index',
        ),
    };
    await controller.importBook(
      ImportPreview(
        book: WordBook(
          id: 'responsive-book',
          title: '响应式测试词书',
          source: 'responsive_test.dart',
          importedAt: DateTime.now(),
          members: [
            for (var index = 0; index < words.length; index++)
              BookMember(
                entryId: 'word-$index',
                unit: 'Unit ${(index ~/ 6) + 1}',
                position: index,
              ),
          ],
        ),
        entries: {for (final word in words) word.id: word},
        total: words.length,
        duplicates: 0,
        missingMeanings: 0,
        missingExamples: 0,
      ),
    );
    await controller.updateSettings((settings) => settings.fontScale = 1.3);

    await controller.review('word-0', kind: 'formal', correct: true);
    await controller.review('word-1', kind: 'formal', correct: false);
    await controller.review(
      'word-2',
      kind: 'self',
      familiar: true,
      action: 'remember',
    );
    await controller.review('word-3', kind: 'view', familiar: false);
    return controller;
  }

  Future<void> setNarrowViewport(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<List<FlutterErrorDetails>> exercisePage(
    WidgetTester tester,
    Future<void> Function() showPage,
  ) async {
    final errors = <FlutterErrorDetails>[];
    final previousHandler = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      await showPage();
      await tester.pumpAndSettle();
      for (var attempt = 0; attempt < 12; attempt++) {
        final scrollable = find.byType(Scrollable);
        if (!tester.any(scrollable)) break;
        await tester.drag(scrollable.first, const Offset(0, -720));
        await tester.pumpAndSettle();
      }
      final scrollable = find.byType(Scrollable);
      expect(scrollable, findsWidgets);
      final position = tester.state<ScrollableState>(scrollable.first).position;
      expect(position.extentAfter, lessThanOrEqualTo(1), reason: '页面没有滚动到底部。');
    } finally {
      FlutterError.onError = previousHandler;
    }
    return errors;
  }

  Future<void> expectNoLayoutErrors(
    WidgetTester tester,
    Future<void> Function() showPage,
  ) async {
    final errors = await exercisePage(tester, showPage);
    final messages = errors.map((error) => error.toString()).toList();
    expect(
      messages,
      isEmpty,
      reason: '页面产生了 Flutter 异常：\n${messages.join('\n')}',
    );
  }

  testWidgets('Home 在 390x844、1.3 倍字号下可滚动到底部', (tester) async {
    await setNarrowViewport(tester);
    final controller = await createController();

    await tester.pumpWidget(WordNestApp(controller: controller, native: false));
    await expectNoLayoutErrors(tester, () async {
      expect(find.byType(HomePage), findsOneWidget);
    });
  });

  testWidgets('Library 在 390x844、1.3 倍字号下可滚动到底部', (tester) async {
    await setNarrowViewport(tester);
    final controller = await createController();

    await tester.pumpWidget(WordNestApp(controller: controller, native: false));
    await tester.pumpAndSettle();
    final errors = await exercisePage(tester, () async {
      await tester.tap(find.text('词书').last);
      await tester.pumpAndSettle();
      expect(find.byType(LibraryPage), findsOneWidget);
    });
    expect(
      errors.map((error) => error.toString()),
      isEmpty,
      reason: '词书页面产生了 Flutter 异常。',
    );
  });

  testWidgets('Settings 在 390x844、1.3 倍字号下可滚动到底部', (tester) async {
    await setNarrowViewport(tester);
    final controller = await createController();

    await tester.pumpWidget(WordNestApp(controller: controller, native: false));
    await tester.pumpAndSettle();
    final errors = await exercisePage(tester, () async {
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(
        tester.widget<SettingsPage>(find.byType(SettingsPage)).native,
        isFalse,
      );
    });
    expect(
      errors.map((error) => error.toString()),
      isEmpty,
      reason: '设置页面产生了 Flutter 异常。',
    );
  });

  testWidgets('Stats 在 390x844、1.3 倍字号下可滚动到底部', (tester) async {
    await setNarrowViewport(tester);
    final controller = await createController();

    await tester.pumpWidget(WordNestApp(controller: controller, native: false));
    await tester.pumpAndSettle();
    final errors = await exercisePage(tester, () async {
      await tester.tap(find.text('记录').last);
      await tester.pumpAndSettle();
      expect(find.byType(StatsPage), findsOneWidget);
    });
    expect(
      errors.map((error) => error.toString()),
      isEmpty,
      reason: '记录页面产生了 Flutter 异常。',
    );
  });

  testWidgets('Study typing 在 390x844、1.3 倍字号下可滚动到底部', (tester) async {
    await setNarrowViewport(tester);
    final controller = await createController();
    await controller.updateSettings((settings) => settings.autoAdvance = false);
    await controller.begin('typing', ids: ['word-0', 'word-1']);

    final errors = await exercisePage(tester, () async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: Scaffold(
              body: StudyPage(
                controller: controller,
                mode: 'typing',
                onBack: () async {},
                onRestart: () async {},
                onSpeak: (_) async {},
                onToggleCompact: () async {},
                onPause: () {},
              ),
            ),
          ),
        ),
      );
    });
    expect(
      errors.map((error) => error.toString()),
      isEmpty,
      reason: '输入题页面产生了 Flutter 异常。',
    );
  });
}
