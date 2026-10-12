import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/app.dart';
import 'package:wordnest/data/storage.dart';
import 'package:wordnest/domain/controller.dart';
import 'package:wordnest/domain/models.dart';
import 'package:wordnest/features/study_page.dart';
import 'package:wordnest/platform/desktop_service.dart';
import 'package:wordnest/platform/word_audio_service.dart';

class _UnavailableWordAudio extends WordAudioService {
  @override
  Future<void> play(String word) async => throw StateError('injected dictionary unavailable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const tts = MethodChannel('flutter_tts');
  const sound = MethodChannel('io.wordnest/sound');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(tts, null);
    messenger.setMockMethodCallHandler(sound, null);
  });

  test('speech initializes English and volume before speaking; rejection is visible', () async {
    final calls = <MethodCall>[];
    final errors = <String>[];
    var accepted = true;
    messenger.setMockMethodCallHandler(tts, (call) async {
      calls.add(call);
      if (call.method == 'isLanguageAvailable') return true;
      if (call.method == 'speak') return accepted ? 1 : 0;
      return 1;
    });
    final service = DesktopService(onAudioError: errors.add, wordAudio: _UnavailableWordAudio());
    await service.speak(' focus ');
    expect(
      calls.map((c) => c.method),
      containsAllInOrder([
        'isLanguageAvailable',
        'setLanguage',
        'setSpeechRate',
        'setVolume',
        'stop',
        'speak',
      ]),
    );
    expect(calls.singleWhere((c) => c.method == 'isLanguageAvailable').arguments, 'en-US');
    expect(calls.singleWhere((c) => c.method == 'setVolume').arguments, 1.0);
    expect(errors, [contains('仅将当前英语词发送到有道公开词音频服务')]);
    expect(service.audioError, isNull);
    accepted = false;
    await service.speak('read');
    expect(errors, [contains('仅将当前英语词'), contains('朗读失败')]);
    expect(service.lastError, contains('语音引擎拒绝'));
  });

  test(
    'missing English voice is actionable and initialization can retry',
    () async {
      var available = false;
      final calls = <String>[];
      final errors = <String>[];
      messenger.setMockMethodCallHandler(tts, (call) async {
        calls.add(call.method);
        return call.method == 'isLanguageAvailable' ? available : 1;
      });
      final service = DesktopService(onAudioError: errors.add, wordAudio: _UnavailableWordAudio());
      await service.speak('focus');
      expect(errors, [contains('仅将当前英语词'), contains('英语离线语音数据')]);
      expect(calls, isNot(contains('speak')));
      available = true;
      await service.speak('focus');
      expect(calls, contains('speak'));
    },
  );

  test(
    'Android effects use native channel, obey mute, and report failure once',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final played = <String>[];
      final errors = <String>[];
      var fail = false;
      messenger.setMockMethodCallHandler(sound, (call) async {
        if (fail) throw PlatformException(code: 'sound_play_failed');
        expect(call.method, 'play');
        played.add((call.arguments as Map)['sound'] as String);
        return null;
      });
      final service = DesktopService(onAudioError: errors.add, wordAudio: _UnavailableWordAudio());
      final settings = AppSettings()
        ..tts = false
        ..sound = true;
      await service.configure(settings);
      await service.playStudySound('key');
      await service.playStudySound('correct');
      await service.playStudySound('incorrect');
      expect(played, ['key', 'correct', 'incorrect']);
      settings.sound = false;
      await service.playStudySound('key');
      expect(played.length, 3);
      settings.sound = true;
      fail = true;
      await service.playStudySound('key');
      await service.playStudySound('key');
      expect(errors.single, contains('媒体音量'));
    },
  );

  for (final floating in [false, true]) {
    testWidgets(
      'bottom navigation has no overlay while pressed (${floating ? 'floating' : 'normal'})',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(440, 900);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = AppController(MemoryStorage());
        await c.initialize();
        await c.updateSettings((s) {
          s.navigationStyle = floating ? 'floating' : 'adaptive';
          s.tts = false;
        });
        await tester.pumpWidget(WordNestApp(controller: c, native: false));
        await tester.pumpAndSettle();
        final finder = find.byType(NavigationBar);
        final bar = tester.widget<NavigationBar>(finder);
        expect(bar.indicatorColor, Colors.transparent);
        for (final states in [
          <WidgetState>{},
          {WidgetState.pressed},
          {WidgetState.hovered},
          {WidgetState.focused},
          {WidgetState.selected},
        ]) {
          expect(bar.overlayColor!.resolve(states), Colors.transparent);
        }
        final context = tester.element(finder);
        expect(Theme.of(context).splashFactory, NoSplash.splashFactory);
        final icons = NavigationBarTheme.of(context).iconTheme!;
        expect(
          icons.resolve({WidgetState.selected})!.color,
          isNot(icons.resolve({})!.color),
        );
        expect(
          bar.labelTextStyle!.resolve({WidgetState.selected})!.fontWeight,
          FontWeight.w700,
        );
        final target = find.descendant(of: finder, matching: find.text('记录'));
        final gesture = await tester.startGesture(tester.getCenter(target));
        await tester.pump(const Duration(milliseconds: 80));
        expect(
          tester.widget<NavigationBar>(finder).overlayColor!.resolve({
            WidgetState.pressed,
          }),
          Colors.transparent,
        );
        await gesture.up();
        await tester.pumpAndSettle();
        expect(tester.widget<NavigationBar>(finder).selectedIndex, 3);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets(
    'typing forwards key and result effects; muted typing makes no calls',
    (tester) async {
      final c = AppController(MemoryStorage());
      await c.initialize();
      await c.importBook(
        ImportPreview(
          book: WordBook(
            id: 'audio-book',
            title: '音效测试',
            importedAt: DateTime.now(),
            members: [BookMember(entryId: 'focus', unit: '1', position: 0)],
          ),
          entries: {
            'focus': WordEntry(id: 'focus', word: 'focus', meaning: '集中'),
          },
          total: 1,
          duplicates: 0,
          missingMeanings: 0,
          missingExamples: 1,
        ),
      );
      await c.updateSettings((s) {
        s.tts = false;
        s.sound = true;
        s.autoAdvance = false;
      });
      await c.begin('typing', ids: ['focus']);
      final played = <String>[];
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
              onPlaySound: (sound) async => played.add(sound),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'wrong');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(played, containsAllInOrder(['key', 'incorrect']));
      await tester.enterText(find.byType(TextField), 'focus');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(played.last, 'correct');
      await tester.pumpWidget(const SizedBox.shrink());
      await c.updateSettings((s) => s.sound = false);
      await c.begin('typing', ids: ['focus'], resume: false);
      played.clear();
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
              onPlaySound: (sound) async => played.add(sound),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'focus');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(played, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
