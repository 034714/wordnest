import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/app.dart';
import 'package:wordnest/data/storage.dart';
import 'package:wordnest/domain/controller.dart';
import 'package:wordnest/domain/models.dart';
import 'package:wordnest/features/study_page.dart';

void main() {
  Future<AppController> controller() async {
    final storage = MemoryStorage();
    final c = AppController(storage);
    await c.initialize();
    await c.importBook(
      ImportPreview(
        book: WordBook(
          id: 'b',
          title: '测试词书',
          importedAt: DateTime.now(),
          members: [
            for (var i = 0; i < 4; i++)
              BookMember(entryId: 'w$i', unit: 'Unit 1', position: i),
          ],
        ),
        entries: {
          for (var i = 0; i < 4; i++)
            'w$i': WordEntry(
              id: 'w$i',
              word: ['focus', 'read', 'travel', 'write'][i],
              meaning: ['v. 集中注意力', 'v. 阅读', 'v. 旅行', 'v. 书写'][i],
            ),
        },
        total: 4,
        duplicates: 0,
        missingMeanings: 0,
        missingExamples: 4,
      ),
    );
    return c;
  }

  testWidgets(
    'home keeps a direct quick-learning entrance without an account',
    (tester) async {
      await tester.view.physicalSizeTestValueSet(const Size(1360, 1000));
      final c = await controller();
      await tester.pumpWidget(WordNestApp(controller: c, native: false));
      await tester.pumpAndSettle();
      expect(find.text('开始新一轮'), findsOneWidget);
      expect(find.text('测试词书'), findsOneWidget);
      await tester.tap(find.text('开始新一轮'));
      await tester.pumpAndSettle();
      expect(find.text('focus'), findsOneWidget);
      expect(find.text('记住'), findsOneWidget);
      await tester.tap(find.text('记住'));
      await tester.pumpAndSettle();
      expect(c.state.events.where((e) => e.kind == 'view').length, 1);
      expect(c.formalToday, 0);
      expect(find.text('read'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.resetPhysicalSize();
    },
  );
  testWidgets(
    'formal test hides answer content until selection and persists result',
    (tester) async {
      final c = await controller();
      await c.updateSettings((settings) => settings.autoAdvance = false);
      await c.begin('formal', ids: ['w0']);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudyPage(
              controller: c,
              mode: 'formal',
              onBack: () async {},
              onRestart: () async {},
              onSpeak: (_) async {},
              onToggleCompact: () async {},
              onPause: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(c.formalToday, 0);
      expect(find.text('答案会在提交后揭晓。'), findsNothing);
      expect(find.text('v. 集中注意力'), findsOneWidget);
      await tester.ensureVisible(find.text('v. 集中注意力'));
      await tester.tap(find.text('v. 集中注意力'));
      await tester.pumpAndSettle();
      expect(c.formalToday, 1);
      expect(c.correctToday, 1);
      expect(find.text('下一词 · Enter'), findsOneWidget);
      expect(find.text('v. 集中注意力'), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudyPage(
              controller: c,
              mode: 'formal',
              onBack: () async {},
              onRestart: () async {},
              onSpeak: (_) async {},
              onToggleCompact: () async {},
              onPause: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('下一词 · Enter'), findsOneWidget);
      expect(c.formalToday, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'submitted spelling survives page recreation without duplicate event',
    (tester) async {
      final c = await controller();
      await c.begin('typing', ids: ['w0']);
      Widget page() => MaterialApp(
        home: Scaffold(
          body: StudyPage(
            controller: c,
            mode: 'typing',
            onBack: () async {},
            onRestart: () async {},
            onSpeak: (_) async {},
            onToggleCompact: () async {},
            onPause: () {},
          ),
        ),
      );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'focus');
      await tester.ensureVisible(find.text('检查拼写 · Enter'));
      await tester.tap(find.text('检查拼写 · Enter'));
      await tester.pumpAndSettle();
      expect(find.text('下一词 · Enter'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.text('下一词 · Enter'), findsOneWidget);
      expect(find.text('focus'), findsWidgets);
      expect(c.state.events.where((e) => e.kind == 'typing').length, 1);
      expect(c.formalToday, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'formal history freezes options and results without duplicate events',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 1400);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await controller();
      await c.updateSettings((s) => s.autoAdvance = false);
      await c.begin('formal', ids: ['w0', 'w1']);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudyPage(
              controller: c,
              mode: 'formal',
              onBack: () async {},
              onRestart: () async {},
              onSpeak: (_) async {},
              onToggleCompact: () async {},
              onPause: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final labels = List<String>.from(
        (c.state.session['history'] as Map)['0']['optionLabels'],
      );
      await tester.tap(find.text('v. 集中注意力'));
      await tester.pumpAndSettle();
      await c.navigateTo(1);
      await tester.pumpAndSettle();
      await c.updateSettings((s) => s.optionCount = 2);
      await c.navigateTo(0);
      await tester.pumpAndSettle();
      expect((c.state.session['history'] as Map)['0']['optionLabels'], labels);
      expect(find.text('下一词 · Enter'), findsOneWidget);
      await tester.tap(find.text('v. 阅读').last);
      await tester.pumpAndSettle();
      expect(c.formalToday, 1);
      expect(c.correctToday, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'automatic speech runs once per transition and wrong answers stay',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 1400);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await controller();
      await c.updateSettings((s) {
        s.tts = true;
        s.autoTts = true;
        s.autoAdvance = true;
      });
      await c.begin('formal', ids: ['w0', 'w1']);
      final spoken = <String>[];
      var stopped = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudyPage(
              controller: c,
              mode: 'formal',
              onBack: () async {},
              onRestart: () async {},
              onSpeak: (word) async {
                spoken.add(word);
              },
              onStopSpeech: () async {
                stopped++;
              },
              onToggleCompact: () async {},
              onPause: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(spoken, ['focus']);
      await c.updateSettings((s) => s.showNotes = !s.showNotes);
      await tester.pumpAndSettle();
      expect(spoken, ['focus']);
      await tester.tap(find.text('v. 阅读'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      expect(c.sessionIndex, 0);
      await c.navigateTo(1);
      await tester.pumpAndSettle();
      expect(spoken, ['focus', 'read']);
      expect(stopped, greaterThanOrEqualTo(2));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('typing dictates with placeholder and retries wrong input once', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = await controller();
    await c.updateSettings((s) {
      s.autoAdvance = false;
      s.typingReveal = false;
    });
    await c.begin('typing', ids: ['w0']);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudyPage(
            controller: c,
            mode: 'typing',
            onBack: () async {},
            onRestart: () async {},
            onSpeak: (_) async {},
            onToggleCompact: () async {},
            onPause: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('focus'), findsNothing);
    expect(find.text('_ _ _ _ _'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'focys');
    await tester.pump();
    expect(find.text('focys'), findsNWidgets(2));
    await tester.ensureVisible(find.text('检查拼写 · Enter'));
    await tester.tap(find.text('检查拼写 · Enter'));
    await tester.pumpAndSettle();
    expect(find.text('拼写不正确，请重新输入后再检查。'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(c.sessionIndex, 0);
    expect(c.state.events.where((e) => e.kind == 'typing').length, 1);
    await tester.enterText(find.byType(TextField), 'focus');
    await tester.pump();
    await tester.tap(find.text('检查拼写 · Enter'));
    await tester.pumpAndSettle();
    expect(find.text('下一词 · Enter'), findsOneWidget);
    expect(find.text('拼写正确。继续下一词。'), findsOneWidget);
    expect(c.state.events.where((e) => e.kind == 'typing').length, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('typing shows first letter hint and Tab toggles the answer', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = await controller();
    await c.updateSettings((s) {
      s.autoAdvance = false;
      s.typingReveal = true;
    });
    await c.begin('typing', ids: ['w0']);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudyPage(
            controller: c,
            mode: 'typing',
            onBack: () async {},
            onRestart: () async {},
            onSpeak: (_) async {},
            onToggleCompact: () async {},
            onPause: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('f _ _ _ _'), findsOneWidget);
    expect(find.text('focus'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.text('focus'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.text('focus'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

extension on TestFlutterView {
  Future<void> physicalSizeTestValueSet(Size size) async {
    devicePixelRatio = 1;
    physicalSize = size;
  }
}
