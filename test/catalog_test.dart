import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/platform/catalog_service.dart';
import 'package:wordnest/platform/update_service.dart';

void main() {
  test('catalog lists only allowlisted verified HTTPS sources', () async {
    final books = await CatalogService().list();
    expect(books, isNotEmpty);
    final ids = books.map((b) => b.id).toSet();
    expect(ids.length, books.length);
    for (final book in books) {
      expect(book.url.scheme, 'https');
      expect(book.url.host, 'raw.githubusercontent.com');
      expect(book.license, isNotEmpty);
      expect(book.source, isNotEmpty);
      expect(book.filename, endsWith('.txt'));
      expect(book.maxBytes, lessThanOrEqualTo(CatalogService.hardMaxBytes));
      expect(() => validateUpdateUrl(book.url.toString()), returnsNormally);
      expect(book.isBuiltin, isTrue);
    }
    final dwyl = books.firstWhere((b) => b.id == 'english-words-alpha');
    expect(dwyl.license, contains('Unlicense'));
    expect(dwyl.source, 'dwyl/english-words');
    expect(dwyl.description, contains('没有释义'));
  });

  test(
    'KyleBing study books are allowlisted with license attribution',
    () async {
      final books = await CatalogService().list();
      final kylebing = books
          .where((b) => b.source == 'KyleBing/english-vocabulary')
          .toList();
      expect(kylebing.length, 7);
      expect(kylebing.map((b) => b.id).toSet(), {
        'kylebing-junior',
        'kylebing-highschool',
        'kylebing-cet4',
        'kylebing-cet6',
        'kylebing-postgrad',
        'kylebing-toefl',
        'kylebing-sat',
      });
      for (final book in kylebing) {
        expect(book.license, 'BSD-3-Clause');
        expect(book.attribution, contains('KyleBing/english-vocabulary'));
        expect(book.attribution, contains('BSD-3-Clause'));
        expect(book.attribution, contains('https://github.com/'));
        expect(book.url.host, 'raw.githubusercontent.com');
        expect(book.url.pathSegments.last, contains('乱序'));
        expect(book.description, contains('Tab'));
        expect(book.maxBytes, lessThanOrEqualTo(2 * 1024 * 1024));
      }
      final cet4 = kylebing.firstWhere((b) => b.id == 'kylebing-cet4');
      expect(cet4.url.pathSegments.last, '3 四级-乱序.txt');
      expect(
        cet4.url.toString(),
        'https://raw.githubusercontent.com/KyleBing/english-vocabulary/master/3%20%E5%9B%9B%E7%BA%A7-%E4%B9%B1%E5%BA%8F.txt',
      );
    },
  );

  test('fetch returns text and filename through injected transport', () async {
    final service = CatalogService(
      resolver: (_) async => [InternetAddress('8.8.8.8')],
      transport: (uri, address) async {
        expect(uri.host, 'raw.githubusercontent.com');
        expect(address.address, '8.8.8.8');
        return FetchResponse(200, utf8.encode('apple\nbanana\ncherry\n'));
      },
    );
    final book = (await service.list()).first;
    final download = await service.fetch(book);
    expect(download.filename, book.filename);
    expect(download.text, 'apple\nbanana\ncherry\n');
    expect(download.byteLength, 20);
    expect(download.book.id, book.id);
  });

  test('fetch rejects forged or arbitrary books without network', () async {
    var calls = 0;
    final service = CatalogService(
      resolver: (_) async => [InternetAddress('8.8.8.8')],
      transport: (_, _) async {
        calls++;
        return FetchResponse(200, utf8.encode('x'));
      },
    );
    final real = (await service.list()).first;
    final forgedSameId = CatalogBook(
      id: real.id,
      title: real.title,
      description: real.description,
      url: Uri.parse(
        'https://raw.githubusercontent.com/attacker/evil/master/words.txt',
      ),
      filename: real.filename,
      maxBytes: real.maxBytes,
      license: real.license,
      source: real.source,
      attribution: real.attribution,
    );
    final arbitrary = CatalogBook(
      id: 'custom',
      title: 'custom',
      description: 'custom',
      url: Uri.parse('https://example.com/words.txt'),
      filename: 'custom.txt',
      maxBytes: 1024,
      license: 'unknown',
      source: 'unknown',
      attribution: 'unknown',
    );
    await expectLater(
      service.fetch(forgedSameId),
      throwsA(isA<CatalogError>()),
    );
    await expectLater(service.fetch(arbitrary), throwsA(isA<CatalogError>()));
    expect(calls, 0);
    expect(forgedSameId.isBuiltin, isFalse);
  });

  test(
    'fetch surfaces server, size, encoding and DNS failures in Chinese',
    () async {
      final book = (await CatalogService().list()).first;
      Future<CatalogError> run(PinnedFetch transport) async {
        final service = CatalogService(
          resolver: (_) async => [InternetAddress('8.8.8.8')],
          transport: transport,
        );
        try {
          await service.fetch(book);
          fail('expected CatalogError');
        } on CatalogError catch (error) {
          return error;
        }
      }

      final failing = await run((_, _) async => const FetchResponse(503, []));
      expect(failing.message, contains('503'));

      final oversized = await run(
        (_, _) async => FetchResponse(200, List.filled(book.maxBytes + 1, 32)),
      );
      expect(oversized.message, contains('大小'));

      final empty = await run((_, _) async => const FetchResponse(200, []));
      expect(empty.message, contains('空'));

      final badEncoding = await run(
        (_, _) async => FetchResponse(200, [0xff, 0xfe, 0xfd]),
      );
      expect(badEncoding.message, contains('无效'));

      var calls = 0;
      final privateDns = CatalogService(
        resolver: (_) async => [InternetAddress('127.0.0.1')],
        transport: (_, _) async {
          calls++;
          return FetchResponse(200, utf8.encode('x'));
        },
      );
      await expectLater(
        privateDns.fetch(book),
        throwsA(
          isA<CatalogError>().having(
            (e) => e.message,
            'message',
            contains('私有'),
          ),
        ),
      );
      expect(calls, 0);

      final redirectLoop = CatalogService(
        resolver: (_) async => [InternetAddress('8.8.8.8')],
        transport: (_, _) async =>
            const FetchResponse(302, [], location: '/again'),
      );
      await expectLater(redirectLoop.fetch(book), throwsA(isA<CatalogError>()));

      final downgrade = CatalogService(
        resolver: (_) async => [InternetAddress('8.8.8.8')],
        transport: (_, _) async =>
            const FetchResponse(302, [], location: 'http://example.com/a.txt'),
      );
      await expectLater(downgrade.fetch(book), throwsA(isA<CatalogError>()));
    },
  );
}
