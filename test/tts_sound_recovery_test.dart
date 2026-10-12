import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/data/storage.dart';
import 'package:wordnest/domain/models.dart';
import 'package:wordnest/platform/desktop_service.dart';
import 'package:wordnest/platform/word_audio_service.dart';

class _UnavailableWordAudio extends WordAudioService {
  int attempts = 0;
  @override
  Future<void> play(String word) async {
    attempts++;
    throw StateError('injected unavailable dictionary audio');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const tts = MethodChannel('flutter_tts');
  const native = MethodChannel('io.wordnest/tts');
  const sound = MethodChannel('io.wordnest/sound');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    for (final channel in [tts, native, sound]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('nullable setters and unavailable volume API do not reject a valid engine', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(tts, (call) async {
      calls.add(call.method);
      if (call.method == 'isLanguageAvailable') return true;
      if (call.method == 'setVolume') throw PlatformException(code: 'unsupported');
      if (call.method == 'speak') return 1;
      return null;
    });
    final wordAudio = _UnavailableWordAudio();
    final service = DesktopService(wordAudio: wordAudio);
    await service.speak('hello');
    expect(wordAudio.attempts, 1);
    expect(calls, contains('speak'));
    expect(service.audioError, isNull);
  });

  test('Windows checks supported getLanguages instead of Android-only availability', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    messenger.setMockMethodCallHandler(tts, (call) async {
      expect(call.method, isNot('isLanguageAvailable'));
      if (call.method == 'getLanguages') return ['en-US'];
      return 1;
    });
    final service = DesktopService(wordAudio: _UnavailableWordAudio());
    await service.speak('hello');
    expect(service.audioError, isNull);
  });

  test('installed engines selectable despite void setEngine, retry clears failure', () async {
    var available = false;
    String? selected;
    messenger.setMockMethodCallHandler(native, (call) async {
      if (call.method == 'initialize') throw PlatformException(code: 'no_voice');
      return null;
    });
    messenger.setMockMethodCallHandler(tts, (call) async {
      if (call.method == 'getEngines') return ['engine.one', 'engine.two'];
      if (call.method == 'setEngine') { selected = call.arguments as String; return null; }
      if (call.method == 'isLanguageAvailable') return available;
      return 1;
    });
    final service = DesktopService(wordAudio: _UnavailableWordAudio());
    await service.speak('hello');
    expect(service.audioError, contains('朗读失败'));
    await service.refreshTtsEngines();
    available = true;
    expect(await service.retryTts(engine: 'engine.two'), isTrue);
    expect(selected, 'engine.two');
    expect(service.audioError, isNull);
    expect(await service.retryTts(engine: 'missing'), isFalse);
  });

  test('plugin failure uses native offline fallback without network request', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(tts, (call) async {
      if (call.method == 'isLanguageAvailable') return false;
      return 1;
    });
    messenger.setMockMethodCallHandler(native, (call) async { calls.add(call); return null; });
    final service = DesktopService(wordAudio: _UnavailableWordAudio());
    await service.speak('hello');
    expect(calls.map((c) => c.method), ['stop', 'initialize', 'speak']);
    expect((calls.last.arguments as Map)['text'], 'hello');
    expect(service.audioError, isNull);
  });

  test('pack persists, old settings migrate, invalid pack rejected transactionally', () async {
    final store = MemoryStorage();
    final settings = AppSettings()..soundPack = 'soft';
    await store.saveSettings(settings);
    expect((await store.load()).settings.soundPack, 'soft');
    final legacy = settings.toJson()..remove('soundPack');
    expect(AppSettings.fromJson(BackupCodec.migrateSettings(legacy)).soundPack, 'classic');
    expect(AppSettings().soundPack, 'classic');
    for (final pack in AppSettings.soundPackLabels.keys) {
      settings.soundPack = pack;
      await store.saveSettings(settings);
      expect((await store.load()).settings.soundPack, pack);
      expect(AppSettings.fromJson(settings.toJson()).soundPack, pack);
    }
    settings.soundPack = 'soft';
    await store.saveSettings(settings);
    settings.soundPack = 'unknown';
    await expectLater(store.saveSettings(settings), throwsFormatException);
    expect((await store.load()).settings.soundPack, 'soft');
  });

  test('mute preserved, previews and quick changes route distinct offline packs', () async {
    final played = <Map>[];
    messenger.setMockMethodCallHandler(sound, (call) async { played.add(call.arguments as Map); return null; });
    final service = DesktopService(wordAudio: _UnavailableWordAudio());
    final settings = AppSettings()..tts = false;
    await service.configure(settings);
    await service.playStudySound('key');
    expect(played, isEmpty);
    for (final pack in AppSettings.soundPackLabels.keys) {
      await service.playStudySound('key', pack: pack, preview: true);
    }
    expect(played.map((p) => p['pack']),
        ['classic', 'soft', 'digital', 'mechanical', 'chime', 'click']);
    settings..sound = true..soundPack = 'digital';
    await service.playStudySound('correct');
    expect(played.last['pack'], 'digital');
    final root = 'android/app/src/main/res/raw';
    final bytes = [
      File('$root/study_key.wav').readAsBytesSync(),
      File('$root/study_soft_key.wav').readAsBytesSync(),
      File('$root/study_digital_key.wav').readAsBytesSync(),
    ];
    for (final pack in ['mechanical', 'chime', 'click']) {
      for (final effect in ['key', 'correct', 'incorrect']) {
        final wav = File('$root/study_${pack}_$effect.wav').readAsBytesSync();
        expect(String.fromCharCodes(wav.take(4)), 'RIFF');
        expect(String.fromCharCodes(wav.skip(8).take(4)), 'WAVE');
        expect(wav.length, greaterThan(1000));
        expect(wav.length, lessThan(20000));
        for (final previous in bytes) {
          expect(listEquals(previous, wav), isFalse);
        }
        bytes.add(wav);
      }
    }
    expect(listEquals(bytes[0], bytes[1]), isFalse);
    expect(listEquals(bytes[1], bytes[2]), isFalse);
  });
}
