import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'safe_http.dart';

/// Dictionary word audio only: never accepts sentences, meanings or notes.
class WordAudioService {
  static const channel = MethodChannel('io.wordnest/tts');
  static const maxBytes = 1024 * 1024;
  int _generation = 0;
  Process? _windowsPlayer;
  String? lastContentType;

  static String normalizeWord(String input) {
    final word = input.trim().toLowerCase();
    if (!RegExp(r"^[a-z]+(?:['-][a-z]+)*$").hasMatch(word) ||
        word.length > 80) {
      throw const FormatException('在线发音只支持单个英语词（可含连字符或撇号），不会发送句子或笔记');
    }
    return word;
  }

  static Uri source(String word) => Uri.https('dict.youdao.com', '/dictvoice', {
    'audio': normalizeWord(word),
    'type': '2',
  });

  static bool isMp3(List<int> b) {
    // Require two consistent MPEG Layer III frames, not merely a MIME label.
    for (var i = 0; i + 4 < b.length && i < 8192; i++) {
      final size = _frameSize(b, i);
      if (size != null &&
          i + size + 4 <= b.length &&
          _frameSize(b, i + size) != null &&
          (b[i + 1] & 0x1e) == (b[i + size + 1] & 0x1e) &&
          (b[i + 2] & 0x0c) == (b[i + size + 2] & 0x0c)) {
        return true;
      }
    }
    return false;
  }

  static int? _frameSize(List<int> b, int i) {
    if (i + 4 > b.length || b[i] != 255 || (b[i + 1] & 0xe0) != 0xe0) {
      return null;
    }
    final version = (b[i + 1] >> 3) & 3;
    if (version == 1 || ((b[i + 1] >> 1) & 3) != 1) return null;
    final rateIndex = b[i + 2] >> 4;
    final sampleIndex = (b[i + 2] >> 2) & 3;
    if (rateIndex == 0 || rateIndex == 15 || sampleIndex == 3) return null;
    final rates = version == 3
        ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];
    final sample =
        [44100, 48000, 32000][sampleIndex] ~/
        (version == 3
            ? 1
            : version == 2
            ? 2
            : 4);
    return (version == 3 ? 144000 : 72000) * rates[rateIndex] ~/ sample +
        ((b[i + 2] >> 1) & 1);
  }

  Future<File> cachedAudio(String input) async {
    final word = normalizeWord(input);
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}${Platform.pathSeparator}word-audio-v1');
    await dir.create(recursive: true);
    final name = Uri.encodeComponent(word);
    final file = File('${dir.path}${Platform.pathSeparator}$name.mp3');
    if (await file.exists()) {
      if (await file.length() <= maxBytes && isMp3(await file.readAsBytes())) {
        return file;
      }
      await file.delete();
    }
    final response = await safeHttpGet(
      uri: source(word),
      resolver: InternetAddress.lookup,
      timeout: const Duration(seconds: 15),
      maxBodyBytes: maxBytes,
      exchange: (client, uri) async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptHeader, 'audio/mpeg');
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        final response = await request.close();
        if (response.statusCode != 200) {
          return FetchResponse(
            response.statusCode,
            const [],
            location: response.headers.value(HttpHeaders.locationHeader),
          );
        }
        final mime = response.headers.contentType?.mimeType.toLowerCase();
        lastContentType = mime;
        if (!{'audio/mpeg', 'audio/mp3', 'audio/x-mpeg'}.contains(mime) ||
            response.contentLength > maxBytes ||
            (response.headers.value(HttpHeaders.contentEncodingHeader) ??
                    'identity') !=
                'identity') {
          throw const FormatException('词典未返回受支持的 MP3 音频');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const FormatException('词音频过大');
          }
          bytes.addAll(chunk);
        }
        if (!isMp3(bytes)) throw const FormatException('词典返回内容不是有效 MP3');
        return FetchResponse(200, bytes);
      },
    );
    if (response.statusCode != 200 || !isMp3(response.body)) {
      throw StateError('词典音频不可用（HTTP ${response.statusCode}）');
    }
    // Complete writes only; partial files never become cache entries.
    final temp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temp.writeAsBytes(response.body, flush: true);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
    return file;
  }

  Future<void> play(String word) async {
    await stop();
    final token = _generation;
    final file = await cachedAudio(word);
    if (token != _generation) return;
    if (Platform.isAndroid) {
      await channel.invokeMethod<void>('playWordAudio', {'path': file.path});
    } else if (Platform.isWindows) {
      // Built-in Windows MCI MPEG decoder. No shell interpolation of the word
      // or path: the cached filename travels through an environment variable.
      const script = r'''
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class WordAudioMci { [DllImport("winmm.dll", CharSet=CharSet.Unicode)] public static extern int mciSendString(string command, System.Text.StringBuilder output, int size, IntPtr hwnd); }'
$p = $env:WORDNEST_AUDIO_PATH
if ($p.Contains('"')) { exit 2 }
try {
  $code = [WordAudioMci]::mciSendString('open "' + $p + '" type mpegvideo alias wordnest', $null, 0, [IntPtr]::Zero)
  if ($code -ne 0) { exit 3 }
  $code = [WordAudioMci]::mciSendString('play wordnest wait', $null, 0, [IntPtr]::Zero)
  if ($code -ne 0) { exit 4 }
} finally { [void][WordAudioMci]::mciSendString('close wordnest', $null, 0, [IntPtr]::Zero) }
''';
      final system = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final process = await Process.start(
        '$system\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
        ['-NoProfile', '-NonInteractive', '-Command', script],
        environment: {'WORDNEST_AUDIO_PATH': file.path},
        runInShell: false,
      );
      if (token != _generation) {
        process.kill();
        await Future.wait([
          process.stdout.drain<void>(),
          process.stderr.drain<void>(),
        ]);
        return;
      }
      _windowsPlayer = process;
      // Drain both pipes even if a platform error produces verbose output.
      final stdoutDone = process.stdout.drain<void>();
      final stderrDone = process.stderr.drain<void>();
      try {
        final code = await process.exitCode.timeout(
          const Duration(seconds: 20),
        );
        await Future.wait([stdoutDone, stderrDone]);
        if (token == _generation && code != 0) {
          throw StateError('Windows 音频解码/播放失败（$code）');
        }
      } finally {
        process.kill();
        if (identical(_windowsPlayer, process)) _windowsPlayer = null;
      }
    } else {
      throw UnsupportedError('词音频目前支持 Android 和 Windows');
    }
  }

  Future<void> stop() async {
    _generation++;
    _windowsPlayer?.kill();
    _windowsPlayer = null;
    if (Platform.isAndroid) await channel.invokeMethod<void>('stopWordAudio');
  }
}
