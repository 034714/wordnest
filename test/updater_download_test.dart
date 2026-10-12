import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/platform/safe_http.dart';
import 'package:wordnest/platform/update_service.dart';
import 'package:wordnest/platform/updater_download_service.dart';

void main() {
  test('stream writes progress, limits size, rejects truncation, timeout and cancel', () async {
    final dir = await Directory.systemTemp.createTemp('wordnest-updater-test-');
    final file = File('${dir.path}/installer.part');
    Future<int> write(
      Stream<List<int>> stream, {
      int? expected,
      void Function()? cancel,
    }) => writeBoundedInstaller(
      stream,
      file,
      maxBytes: 4,
      idleTimeout: const Duration(milliseconds: 20),
      expectedBytes: expected,
      checkCancellation: cancel ?? () {},
      onProgress: (_) {},
    );
    try {
      expect(
        await write(
          Stream.fromIterable([
            [1, 2],
            [3, 4],
          ]),
          expected: 4,
        ),
        4,
      );
      expect(await file.readAsBytes(), [1, 2, 3, 4]);
      await expectLater(
        write(Stream.value([1, 2, 3, 4, 5])),
        throwsFormatException,
      );
      await expectLater(
        write(Stream.value([1, 2]), expected: 4),
        throwsFormatException,
      );
      await expectLater(write(const Stream.empty()), throwsFormatException);
      await expectLater(
        write(Stream.value([1]), cancel: () => throw UpdateDownloadCancelled()),
        throwsA(isA<UpdateDownloadCancelled>()),
      );
      final stalled = StreamController<List<int>>();
      await expectLater(
        write(stalled.stream),
        throwsA(isA<TimeoutException>()),
      );
      await stalled.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test('streamed digest checks actual bytes and rejects tampering', () async {
    final dir = await Directory.systemTemp.createTemp('wordnest-hash-test-');
    final file = File('${dir.path}/installer.part');
    try {
      await file.writeAsString('abc');
      const digest =
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
      expect(await verifyInstallerDigest(file, digest), digest);
      await file.writeAsString('tampered');
      await expectLater(
        verifyInstallerDigest(file, digest),
        throwsFormatException,
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('optional installer size and SHA256 validated strictly', () {
    String feed(Object? size, Object? hash) => jsonEncode({
      'version': '0.4.0+5',
      'platform': 'android',
      'downloadUrl':
          'https://github.com/034714/wordnest/releases/download/v0.4.0/app.apk',
      'sizeBytes': size,
      'sha256': hash,
    });
    final hash = List.filled(64, 'A').join();
    final metadata = parseUpdateMetadata(feed(123, hash), platform: 'android');
    expect(metadata.sizeBytes, 123);
    expect(metadata.sha256, hash.toLowerCase());
    for (final size in [0, -1, 536870913, '123', 1.5]) {
      expect(
        () => parseUpdateMetadata(feed(size, hash), platform: 'android'),
        throwsFormatException,
      );
    }
    for (final badHash in ['', 'xyz', List.filled(63, 'a').join(), 123]) {
      expect(
        () => parseUpdateMetadata(feed(123, badHash), platform: 'android'),
        throwsFormatException,
      );
    }
  });

  test('no-hash releases limited to exact owned HTTPS and asset hosts', () {
    final metadata = UpdateMetadata(
      '0.4.0',
      'android',
      Uri.parse(
        'https://github.com/034714/wordnest/releases/download/v0.4.0/app.apk',
      ),
    );
    for (final url in [
      metadata.downloadUrl.toString(),
      'https://release-assets.githubusercontent.com/asset.apk',
      'https://objects.githubusercontent.com/asset.apk',
    ]) {
      expect(
        () => validateInstallerHop(Uri.parse(url), metadata),
        returnsNormally,
      );
    }
    for (final url in [
      'http://github.com/034714/wordnest/releases/download/a.apk',
      'https://github.com/evil/project/releases/download/a.apk',
      'https://github.com.evil.com/a.apk',
      'https://example.com/a.apk',
      'https://127.0.0.1/a.apk',
    ]) {
      expect(
        () => validateInstallerHop(Uri.parse(url), metadata),
        throwsFormatException,
      );
    }
  });

  test('public DNS uses system proxy instead of forcing DIRECT', () async {
    var proxied = false;
    await safeHttpGet(
      uri: Uri.parse('https://example.com/update'),
      resolver: (_) async => [InternetAddress('8.8.8.8')],
      timeout: const Duration(seconds: 1),
      maxBodyBytes: 1024,
      proxyProbe: (_) async => '127.0.0.1:7890',
      transport: (_, _) async => throw StateError('must not force direct'),
      proxiedFetch: (uri, proxy) async {
        expect(proxy, '127.0.0.1:7890');
        proxied = true;
        return const FetchResponse(200, []);
      },
    );
    expect(proxied, isTrue);
  });

  test(
    'proxy never authorizes private/mixed DNS; redirects repeat gate',
    () async {
      for (final answers in [
        [InternetAddress('10.0.0.1')],
        [InternetAddress('8.8.8.8'), InternetAddress('198.18.0.1')],
        [InternetAddress('::1')],
      ]) {
        await expectLater(
          safeHttpGet(
            uri: Uri.parse('https://github.com/file'),
            resolver: (_) async => answers,
            timeout: const Duration(seconds: 1),
            maxBodyBytes: 1,
            proxyProbe: (_) async => '127.0.0.1:7890',
            proxiedFetch: (_, _) async => throw StateError('unsafe request'),
          ),
          throwsFormatException,
        );
      }
      var calls = 0;
      final metadata = UpdateMetadata(
        '0.4.0',
        'android',
        Uri.parse(
          'https://github.com/034714/wordnest/releases/download/v0.4.0/app.apk',
        ),
      );
      await expectLater(
        safeHttpGet(
          uri: metadata.downloadUrl,
          resolver: (_) async => [InternetAddress('8.8.8.8')],
          timeout: const Duration(seconds: 1),
          maxBodyBytes: 1,
          proxyProbe: (_) async => null,
          validateHop: (uri) => validateInstallerHop(uri, metadata),
          transport: (_, _) async {
            calls++;
            return const FetchResponse(
              302,
              [],
              location: 'https://example.com/evil.apk',
            );
          },
        ),
        throwsFormatException,
      );
      expect(calls, 1);
    },
  );
}
