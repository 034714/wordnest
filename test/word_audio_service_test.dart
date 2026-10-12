// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:wordnest/platform/word_audio_service.dart';

class _RealHttpOverrides extends HttpOverrides {}

class _ProbePaths extends PathProviderPlatform {
  _ProbePaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('word-only privacy gate and encoded public HTTPS URL', () {
    expect(WordAudioService.normalizeWord(' Hello '), 'hello');
    expect(WordAudioService.source("don't").queryParameters['audio'], "don't");
    expect(WordAudioService.source('hello').scheme, 'https');
    expect(WordAudioService.source('hello').host, 'dict.youdao.com');
    for (final input in [
      'my private note',
      '你好',
      'https://localhost',
      '../hello',
      'hello\nworld',
      'hello?secret=note',
      '',
    ]) {
      expect(() => WordAudioService.source(input), throwsFormatException);
    }
  });

  test('MP3 requires two real frame headers; HTML/JSON rejected', () {
    expect(WordAudioService.isMp3('<html>error</html>'.codeUnits), false);
    expect(WordAudioService.isMp3([73, 68, 51, 0, 0]), false);
    final frames = List<int>.filled(834, 0);
    for (final offset in [0, 417]) {
      frames.setRange(offset, offset + 4, [255, 251, 144, 0]);
    }
    expect(WordAudioService.isMp3(frames), true);
    frames[418] = 0;
    expect(WordAudioService.isMp3(frames), false);
  });

  test(
    'real safe_http dictionary MP3 and Windows decoder playback',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final dir = await Directory.systemTemp.createTemp(
        'wordnest-audio-probe-',
      );
      final old = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _ProbePaths(dir.path);
      final audio = WordAudioService();
      try {
        final file = await audio.cachedAudio('hello');
        final bytes = await file.readAsBytes();
        expect(WordAudioService.isMp3(bytes), true);
        // A successful download necessarily passed status, MIME, size and
        // two-frame validation inside the safe_http exchange.
        print(
          'PROBE source=${WordAudioService.source('hello')} status=200 mime=${audio.lastContentType} bytes=${bytes.length} MP3=true',
        );
        final modified = await file.lastModified();
        final cached = await audio.cachedAudio('hello');
        expect(await cached.lastModified(), modified);
        print('PROBE cache-hit=true (no network fetch on second request)');
        if (Platform.isWindows) {
          await audio.play('hello');
          print(
            'PROBE Windows MCI open/play-wait succeeded; decoder/player exit=0. Human audible confirmation not performed.',
          );
        }
      } finally {
        await audio.stop();
        PathProviderPlatform.instance = old;
        await dir.delete(recursive: true);
      }
    }, _RealHttpOverrides()),
    skip: !const bool.fromEnvironment('WORD_AUDIO_PROBE'),
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
