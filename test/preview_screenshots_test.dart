// Public documentation previews, rendered by Flutter's widget-test engine.
// These are not OS/window captures: native integrations are disabled, and all
// content is self-authored demo data in MemoryStorage (no SQLite, personal notes,
// bundled CET4 data, imported files, or fabricated learning/statistics events).
// Opt in with:
// flutter test test/preview_screenshots_test.dart --dart-define=WORDNEST_PREVIEWS=true
// Output: docs/screenshots/*.png. Normal test runs skip this file's generator.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/app.dart';
import 'package:wordnest/data/storage.dart';
import 'package:wordnest/domain/controller.dart';
import 'package:wordnest/domain/models.dart';
import 'package:wordnest/features/settings_page.dart';
import 'package:wordnest/features/study_page.dart';

const _enabled = bool.fromEnvironment('WORDNEST_PREVIEWS');

Future<AppController> _demoController() async {
  final controller = AppController(MemoryStorage());
  await controller.initialize();
  const words = ['focus', 'wander', 'create', 'gentle', 'bloom', 'reflect'];
  const meanings = [
    'v. 集中注意力',
    'v. 漫步；闲逛',
    'v. 创造；创作',
    'adj. 温柔的；轻柔的',
    'v. 开花；绽放',
    'v. 思考；反思',
  ];
  const examples = [
    'Focus on one small step today.',
    'We wander along the quiet path.',
    'Create something with your own hands.',
    'A gentle breeze moves the leaves.',
    'The flowers bloom in spring.',
    'Take a moment to reflect on your day.',
  ];
  const translations = [
    '今天先专注于一小步。',
    '我们沿着安静的小路漫步。',
    '用自己的双手创作一些东西。',
    '轻柔的微风吹动树叶。',
    '花朵在春天绽放。',
    '花一点时间回顾今天。',
  ];
  const phonetics = [
    'ˈfəʊkəs',
    'ˈwɒndə',
    'kriˈeɪt',
    'ˈdʒentl',
    'bluːm',
    'rɪˈflekt',
  ];
  await controller.importBook(
    ImportPreview(
      book: WordBook(
        id: 'public-preview-demo',
        title: '日常小词 · 原创演示',
        source: 'Self-authored public preview fixture',
        importedAt: DateTime(2026, 1, 1),
        members: [
          for (var i = 0; i < words.length; i++)
            BookMember(
              entryId: 'preview-$i',
              unit: 'Daily moments',
              position: i,
            ),
        ],
      ),
      entries: {
        for (var i = 0; i < words.length; i++)
          'preview-$i': WordEntry(
            id: 'preview-$i',
            word: words[i],
            meaning: meanings[i],
            uk: phonetics[i],
            example: examples[i],
            exampleTranslation: translations[i],
          ),
      },
      total: words.length,
      duplicates: 0,
      missingMeanings: 0,
      missingExamples: 0,
    ),
  );
  await controller.updateSettings((settings) {
    settings.theme = 'dark';
    settings.tts = false;
    settings.autoTts = false;
    settings.autoAdvance = false;
    settings.widgetAuto = false;
    settings.notifications = false;
    settings.roundSize = words.length;
  });
  return controller;
}

void main() {
  testWidgets(
    'generate public Flutter-rendered demo previews (explicit opt-in only)',
    (tester) async {
      // DesktopService constructs the hotkey singleton even with native:false.
      // Stub only its event-channel handshake; no native APIs execute.
      const hotkeyEvents = MethodChannel(
        'dev.leanflutter.plugins/hotkey_manager_event',
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        hotkeyEvents,
        (_) async => null,
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          hotkeyEvents,
          null,
        );
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      // Widget tests otherwise substitute Ahem. Load the same Windows font
      // family named by WordNestApp, plus the application's Material icons.
      // Fail explicitly rather than publishing unreadable placeholder glyphs.
      await tester.runAsync(() async {
        final windows = Platform.environment['WINDIR'] ?? r'C:\Windows';
        final fontFile = File('$windows/Fonts/msyh.ttc');
        if (!await fontFile.exists()) {
          throw StateError('Microsoft YaHei is required for Chinese previews.');
        }
        await ui.loadFontFromList(
          await fontFile.readAsBytes(),
          fontFamily: 'Microsoft YaHei',
        );
        await ui.loadFontFromList(
          await File('$windows/Fonts/segoeui.ttf').readAsBytes(),
          fontFamily: 'Segoe UI',
        );
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });

      final controller = await _demoController();
      addTearDown(controller.dispose);
      final boundaryKey = GlobalKey();
      Widget captureRoot(Widget child) =>
          RepaintBoundary(key: boundaryKey, child: child);
      Future<void> save(String name) async {
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          controller.state.events,
          isEmpty,
          reason: 'Previews must never create or fabricate scores.',
        );
        expect(controller.state.notes, isEmpty);
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            if (bytes == null) throw StateError('PNG encoding failed.');
            final file = File('docs/screenshots/$name.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }

      await tester.pumpWidget(
        captureRoot(WordNestApp(controller: controller, native: false)),
      );
      await save('home-dark');
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));

      // Formal mode now starts from the mode chip + primary button.
      await tester.tap(find.text('回忆验证'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.textContaining(
          RegExp('开始新一轮|继续上次学习|开启一小轮|接着上次的小脚印'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(StudyPage), findsOneWidget);
      expect(controller.sessionMode, 'formal');
      expect(controller.formalToday, 0);
      await save('study-formal-unanswered');

      await tester.tap(find.text('今日').first);
      await tester.pumpAndSettle();
      await controller.updateSettings(
        (settings) => settings.copyStyle = 'cute',
      );
      await save('home-cute');

      await tester.tap(find.text('偏好设置'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SettingsPage>(find.byType(SettingsPage)).native,
        isFalse,
      );
      await save('settings-cute');

      // Render the real compact StudyPage with the app's actual theme, without
      // invoking the native window resize method or implying an OS window.
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.begin('quick', resume: false, ids: ['preview-0']);
      tester.view.physicalSize = const Size(480, 640);
      await tester.pumpWidget(
        captureRoot(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: app.theme,
            darkTheme: app.darkTheme,
            themeMode: ThemeMode.dark,
            locale: app.locale,
            supportedLocales: app.supportedLocales,
            localizationsDelegates: app.localizationsDelegates,
            home: Scaffold(
              body: SafeArea(
                child: StudyPage(
                  controller: controller,
                  mode: 'quick',
                  compact: true,
                  onBack: () async {},
                  onRestart: () async {},
                  onSpeak: (_) async {},
                  onStopSpeech: () async {},
                  onToggleCompact: () async {},
                  onPause: () {},
                ),
              ),
            ),
          ),
        ),
      );
      expect(controller.formalToday, 0);
      await save('study-compact-quick');
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.flush();
    },
    skip: !_enabled,
  );
}
