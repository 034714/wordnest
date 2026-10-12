import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/app.dart';
import 'package:wordnest/data/storage.dart';
import 'package:wordnest/domain/controller.dart';
import 'package:wordnest/domain/models.dart';
import 'package:wordnest/features/study_page.dart';

void main() {
  String typingGlyphs(WidgetTester tester) => tester
      .widget<RichText>(find.byKey(const ValueKey('typing-slot-glyphs')))
      .text
      .toPlainText();

  Future<AppController> controllerWith(List<List<String>> words) async {
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
            for (var i = 0; i < words.length; i++)
              BookMember(entryId: 'w$i', unit: 'Unit 1', position: i),
          ],
        ),
        entries: {
          for (var i = 0; i < words.length; i++)
            'w$i': WordEntry(
              id: 'w$i',
              word: words[i][0],
              meaning: words[i][1],
              uk: words[i].length > 2 ? words[i][2] : '',
            ),
        },
        total: words.length,
        duplicates: 0,
        missingMeanings: 0,
        missingExamples: words.length,
      ),
    );
    return c;
  }

  Future<AppController> controller() => controllerWith(const [
    ['focus', 'v. 集中注意力'],
    ['read', 'v. 阅读'],
    ['travel', 'v. 旅行'],
    ['write', 'v. 书写'],
  ]);

  Widget page(AppController c, String mode) => MaterialApp(
    home: Scaffold(
      body: StudyPage(
        controller: c,
        mode: mode,
        onBack: () async {},
        onRestart: () async {},
        onSpeak: (_) async {},
        onToggleCompact: () async {},
        onPause: () {},
      ),
    ),
  );

  void wide(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
      // Drain bounded native stop timeouts scheduled by study teardown.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      tester.view.resetPhysicalSize();
    },
  );
  testWidgets(
    'formal test hides answer content until selection and persists result',
    (tester) async {
      final c = await controller();
      await c.updateSettings((settings) => settings.autoAdvance = false);
      await c.begin('formal', ids: ['w0']);
      await tester.pumpWidget(page(c, 'formal'));
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
      await tester.pumpWidget(page(c, 'formal'));
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
      await tester.pumpWidget(page(c, 'typing'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'focus');
      await tester.ensureVisible(find.text('检查拼写 · Enter'));
      await tester.tap(find.text('检查拼写 · Enter'));
      await tester.pumpAndSettle();
      expect(find.text('下一词 · Enter'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(page(c, 'typing'));
      await tester.pumpAndSettle();
      expect(find.text('下一词 · Enter'), findsOneWidget);
      expect(typingGlyphs(tester), 'focus');
      expect(find.byKey(const ValueKey('typing-answer')), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      expect(c.state.events.where((e) => e.kind == 'typing').length, 1);
      expect(c.formalToday, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'formal history freezes options and results without duplicate events',
    (tester) async {
      wide(tester);
      final c = await controller();
      await c.updateSettings((s) => s.autoAdvance = false);
      await c.begin('formal', ids: ['w0', 'w1']);
      await tester.pumpWidget(page(c, 'formal'));
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
      wide(tester);
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
    wide(tester);
    final c = await controller();
    await c.updateSettings((s) {
      s.autoAdvance = false;
      s.typingReveal = false;
    });
    await c.begin('typing', ids: ['w0']);
    await tester.pumpWidget(page(c, 'typing'));
    await tester.pumpAndSettle();
    expect(find.text('focus'), findsNothing);
    expect(typingGlyphs(tester), '_____');
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    await tester.enterText(find.byType(TextField), 'focys');
    await tester.pump();
    expect(typingGlyphs(tester), 'focys');
    // The native editor keeps the text for IME/caret but paints it
    // transparently; the visible glyphs come from the slot row above.
    final editorStyle = tester
        .widget<EditableText>(find.byType(EditableText))
        .style;
    expect(editorStyle.color?.a, 0);
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
    wide(tester);
    final c = await controller();
    await c.updateSettings((s) {
      s.autoAdvance = false;
      s.typingReveal = true;
    });
    await c.begin('typing', ids: ['w0']);
    await tester.pumpWidget(page(c, 'typing'));
    await tester.pumpAndSettle();
    expect(typingGlyphs(tester), 'f____');
    expect(find.text('focus'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.text('focus'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.text('focus'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('arrow up/down page words while left/right no longer navigate', (
    tester,
  ) async {
    wide(tester);
    final c = await controller();
    await c.updateSettings((s) {
      s.autoAdvance = false;
      s.questionDirection = 'en2zh';
    });
    await c.begin('formal', ids: ['w0', 'w1']);
    await tester.pumpWidget(page(c, 'formal'));
    await tester.pumpAndSettle();
    expect(find.text('focus'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(c.sessionIndex, 1);
    expect(find.text('read'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(c.sessionIndex, 0);
    // ←/→ stopped paging entirely; up/down own the pagination.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(c.sessionIndex, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(c.sessionIndex, 0);
    // Space continues to the next word once the answer is revealed.
    await tester.tap(find.text('v. 集中注意力'));
    await tester.pumpAndSettle();
    expect(c.formalToday, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(c.sessionIndex, 1);
    expect((c.state.session['history'] as Map)['0']['optionLabels'], isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('quick mode keeps left/right as self-rating keys', (
    tester,
  ) async {
    wide(tester);
    final c = await controller();
    await c.updateSettings((s) => s.autoAdvance = false);
    await c.begin('quick', ids: ['w0', 'w1']);
    await tester.pumpWidget(page(c, 'quick'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
      (c.state.session['history'] as Map)['0']['quickResult']['familiar'],
      false,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      (c.state.session['history'] as Map)['1']['quickResult']['familiar'],
      true,
    );
    expect(c.formalToday, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('space submits typing while words with spaces wait for Enter', (
    tester,
  ) async {
    wide(tester);
    final c = await controllerWith(const [
      ['focus', 'v. 集中注意力'],
      ['read', 'v. 阅读'],
      ['travel', 'v. 旅行'],
      ['give up', 'v. 放弃'],
    ]);
    await c.updateSettings((s) {
      s.autoAdvance = false;
      s.typingReveal = false;
    });
    await c.begin('typing', ids: ['w0']);
    await tester.pumpWidget(page(c, 'typing'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'focus');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text('下一词 · Enter'), findsOneWidget);
    expect(find.text('拼写正确。继续下一词。'), findsOneWidget);
    expect(c.state.events.where((e) => e.kind == 'typing').length, 1);
    // A word that contains a space keeps the space key for the text itself.
    await c.begin('typing', ids: ['w3']);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'give up');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(c.state.events.where((e) => e.kind == 'typing').length, 1);
    expect(find.text('下一词 · Enter'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'give up',
    );
    // Enter still submits it.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('下一词 · Enter'), findsOneWidget);
    expect(c.state.events.where((e) => e.kind == 'typing').length, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'zh2en asks with the meaning, offers English words and hides the word',
    (tester) async {
      wide(tester);
      final c = await controllerWith(const [
        ['focus', 'v. 集中注意力', 'ˈfəʊkəs'],
        ['read', 'v. 阅读', 'riːd'],
        ['travel', 'v. 旅行', 'ˈtrævl'],
        ['write', 'v. 书写', 'raɪt'],
      ]);
      await c.updateSettings((s) {
        s.autoAdvance = false;
        s.questionDirection = 'zh2en';
      });
      await c.begin('formal', ids: ['w0', 'w1']);
      await tester.pumpWidget(page(c, 'formal'));
      await tester.pumpAndSettle();
      // Prompt is the Chinese meaning; the word only appears as an option and
      // phonetics stay hidden until the answer is submitted.
      expect(find.byKey(const ValueKey('zh2en-prompt')), findsOneWidget);
      expect(find.text('v. 集中注意力'), findsOneWidget);
      expect(find.text('focus'), findsOneWidget);
      expect(find.text('read'), findsOneWidget);
      expect(find.text('v. 阅读'), findsNothing);
      expect(find.text('/ˈfəʊkəs/'), findsNothing);
      final labels = List<String>.from(
        (c.state.session['history'] as Map)['0']['optionLabels'],
      );
      expect(labels, containsAll(const ['focus', 'read']));
      await tester.tap(find.text('focus'));
      await tester.pumpAndSettle();
      expect(c.formalToday, 1);
      expect(c.correctToday, 1);
      expect(find.text('/ˈfəʊkəs/'), findsOneWidget);
      expect(find.byKey(const ValueKey('zh2en-prompt')), findsNothing);
      expect(find.text('focus'), findsNWidgets(2));
      // Frozen history keeps rendering the zh2en question after paging.
      await c.navigateTo(1);
      await tester.pumpAndSettle();
      await c.navigateTo(0);
      await tester.pumpAndSettle();
      expect((c.state.session['history'] as Map)['0']['optionLabels'], labels);
      expect(find.text('focus'), findsNWidgets(2));
      expect(find.text('下一词 · Enter'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('notebook toggle works at any time and shows the auto-add hint', (
    tester,
  ) async {
    wide(tester);
    final c = await controller();
    await c.updateSettings((s) {
      s.autoAdvance = false;
      s.questionDirection = 'en2zh';
      s.notebookAutoAddErrors = true;
    });
    await c.begin('formal', ids: ['w0']);
    await tester.pumpWidget(page(c, 'formal'));
    await tester.pumpAndSettle();
    expect(find.text('加入生词本'), findsOneWidget);
    // Filing a word is the user's own collection, not an answer: allowed now.
    await tester.ensureVisible(find.text('加入生词本'));
    await tester.tap(find.text('加入生词本'));
    await tester.pumpAndSettle();
    expect(c.isNotebook('w0'), isTrue);
    await tester.tap(find.text('已在生词本'));
    await tester.pumpAndSettle();
    expect(c.isNotebook('w0'), isFalse);
    // A wrong formal answer auto-adds the word and says so.
    await tester.ensureVisible(find.text('v. 阅读'));
    await tester.tap(find.text('v. 阅读'));
    await tester.pumpAndSettle();
    expect(c.formalToday, 1);
    expect(c.correctToday, 0);
    expect(c.isNotebook('w0'), isTrue);
    expect(find.text('已在生词本'), findsOneWidget);
    expect(find.text('已加入生词本'), findsOneWidget);
    // One tap leaves the notebook again.
    await tester.tap(find.text('已在生词本'));
    await tester.pumpAndSettle();
    expect(c.isNotebook('w0'), isFalse);
    expect(find.text('加入生词本'), findsOneWidget);
    expect(find.text('已加入生词本'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('study card keeps working at 390x844', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = await controller();
    await c.updateSettings((s) {
      s.autoAdvance = false;
      s.showChinese = false;
    });
    await c.begin('quick', ids: ['w0']);
    await tester.pumpWidget(page(c, 'quick'));
    await tester.pumpAndSettle();
    expect(find.text('focus'), findsOneWidget);
    expect(find.text('加入生词本'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

extension on TestFlutterView {
  Future<void> physicalSizeTestValueSet(Size size) async {
    devicePixelRatio = 1;
    physicalSize = size;
  }
}
