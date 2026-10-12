import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordnest/platform/update_service.dart';

void main() {
  test('URL default HTTPS and public addresses', () {
    expect(validateUpdateUrl('updates.example.com/feed.json').scheme, 'https');
    expect(validateUpdateUrl('https://8.8.8.8/feed').host, '8.8.8.8');
    expect(
      isPublicUpdateAddress(InternetAddress('2606:4700:4700::1111')),
      isTrue,
    );
    expect(
      UpdateService.defaultSourceUrlFor('windows'),
      'https://raw.githubusercontent.com/034714/wordnest/main/docs/update-feed-windows.json',
    );
    expect(
      UpdateService.defaultSourceUrlFor('android'),
      'https://raw.githubusercontent.com/034714/wordnest/main/docs/update-feed-android.json',
    );
    expect(UpdateService.defaultSourceUrlFor('linux'), isNull);
  });

  test('unsafe URL schemes, hosts, aliases and reserved IPs rejected', () {
    for (final value in [
      '',
      'file:///etc/passwd',
      'ftp://example.com/a',
      'http://localhost/a',
      'http://a.localhost',
      'http://localhost.',
      'http://host.local',
      'http://127.0.0.1',
      'http://10.0.0.1',
      'http://172.31.1.1',
      'http://192.168.1.1',
      'http://169.254.169.254',
      'http://100.64.0.1',
      'http://0.0.0.0',
      'http://192.0.2.1',
      'http://192.31.196.1',
      'http://192.52.193.1',
      'http://192.175.48.1',
      'http://[2620:4f:8000::1]',
      'http://198.51.100.1',
      'http://203.0.113.1',
      'http://198.18.0.1',
      'http://224.0.0.1',
      'http://255.255.255.255',
      'http://2130706433',
      'http://0x7f000001',
      'http://127.1',
      'http://0177.0.0.1',
      'http://[::1]',
      'http://[::]',
      'http://[::ffff:127.0.0.1]',
      'http://[::ffff:8.8.8.8]',
      'http://[fc00::1]',
      'http://[fe80::1]',
      'http://[ff02::1]',
      'http://[2001:db8::1]',
      'http://[2002:0808:0808::1]',
      'http://[64:ff9b::1]',
      'http://[3fff::1]',
      'https://user:pass@example.com',
      'https://example.com:1234/a',
      'https://example.com/a#fragment',
      r'https://example.com\@localhost',
    ]) {
      expect(
        () => validateUpdateUrl(value),
        throwsFormatException,
        reason: value,
      );
    }
  });

  String metadata({
    String version = '1.2.3+4',
    String platform = 'android',
    String url = 'https://updates.example.com/app.apk',
  }) => jsonEncode({
    'version': version,
    'platform': platform,
    'downloadUrl': url,
  });

  test('metadata validates versions, platform, type, URL and size', () {
    expect(
      parseUpdateMetadata(metadata(), platform: 'android').version,
      '1.2.3+4',
    );
    expect(compareUpdateVersions('1.2.3+4', '1.2.3'), greaterThan(0));
    expect(compareUpdateVersions('1.10.0', '1.9.0'), greaterThan(0));
    for (final body in [
      '{}',
      '[]',
      'null',
      metadata(version: 'latest'),
      metadata(version: '01.2.3'),
      metadata(platform: 'windows'),
      metadata(url: 'https://127.0.0.1/app.apk'),
      metadata(url: 'https://example.com/app.exe'),
      metadata(url: 'javascript:alert(1)'),
      ' ' * (UpdateService.maxBodyBytes + 1),
    ]) {
      expect(
        () => parseUpdateMetadata(body, platform: 'android'),
        throwsFormatException,
      );
    }
    expect(
      () => parseUpdateMetadata(metadata(), platform: 'linux'),
      throwsFormatException,
    );
  });

  PinnedFetch okTransport(
    List<int> body, {
    void Function(Uri uri, InternetAddress address)? onCall,
  }) => (uri, address) async {
    onCall?.call(uri, address);
    return FetchResponse(200, body);
  };

  test('fresh install uses the builtin GitHub feed', () async {
    SharedPreferences.setMockInitialValues({});
    Uri? requested;
    final service = UpdateService(
      resolver: (_) async => [InternetAddress('8.8.8.8')],
      transport: okTransport(
        utf8.encode(metadata(version: '0.2.0', platform: 'android')),
        onCall: (uri, address) {
          requested = uri;
          expect(address.address, '8.8.8.8');
        },
      ),
    );
    await service.initialize();
    expect(service.usesDefaultSource, isTrue);
    expect(service.sourceDisabled, isFalse);
    expect(service.sourceUrl, '');
    expect(
      service.effectiveSourceUrlFor('android'),
      UpdateService.defaultSourceUrlFor('android'),
    );
    final result = await service.check(
      currentVersion: '0.1.0',
      platform: 'android',
    );
    expect(result.state, UpdateState.available);
    expect(requested.toString(), UpdateService.defaultSourceUrlFor('android'));
    service.dispose();
  });

  test('explicit empty source stays disabled until default restored', () async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    final countingTransport = okTransport(
      utf8.encode(metadata(version: '0.2.0')),
      onCall: (_, _) => calls++,
    );
    final service = UpdateService(
      resolver: (_) async => [InternetAddress('8.8.8.8')],
      transport: countingTransport,
    );
    await service.initialize();
    await service.setSourceUrl('');
    expect(service.sourceDisabled, isTrue);
    expect(service.effectiveSourceUrlFor('android'), '');
    expect(
      (await service.check(currentVersion: '0.1.0', platform: 'android')).state,
      UpdateState.noSource,
    );
    expect(calls, 0);
    final restored = UpdateService(
      resolver: (_) async => [InternetAddress('8.8.8.8')],
      transport: countingTransport,
    );
    await restored.initialize();
    expect(restored.sourceDisabled, isTrue);
    expect(
      (await restored.check(
        currentVersion: '0.1.0',
        platform: 'android',
      )).state,
      UpdateState.noSource,
    );
    expect(calls, 0);
    await restored.useDefaultSource();
    expect(restored.usesDefaultSource, isTrue);
    expect(
      (await restored.check(
        currentVersion: '0.1.0',
        platform: 'android',
      )).state,
      UpdateState.available,
    );
    expect(calls, 1);
    service.dispose();
    restored.dispose();
  });

  test('custom source persists and legacy values migrate', () async {
    SharedPreferences.setMockInitialValues({
      'wordnest.update.source.v1': 'https://updates.example.com/feed.json',
    });
    final migrated = UpdateService();
    await migrated.initialize();
    expect(migrated.sourceMode, UpdateSourceMode.custom);
    expect(migrated.sourceUrl, 'https://updates.example.com/feed.json');
    migrated.dispose();

    SharedPreferences.setMockInitialValues({'wordnest.update.source.v1': ''});
    final legacyEmpty = UpdateService();
    await legacyEmpty.initialize();
    expect(legacyEmpty.usesDefaultSource, isTrue);
    legacyEmpty.dispose();

    SharedPreferences.setMockInitialValues({});
    final service = UpdateService(
      resolver: (_) async => [InternetAddress('8.8.8.8')],
      transport: okTransport(
        utf8.encode(
          metadata(
            version: '0.1.0',
            platform: 'windows',
            url: 'https://github.com/a/b.exe',
          ),
        ),
      ),
    );
    await service.initialize();
    await service.setSourceUrl('updates.example.com/feed.json');
    final restored = UpdateService();
    await restored.initialize();
    expect(restored.sourceMode, UpdateSourceMode.custom);
    expect(restored.sourceUrl, 'https://updates.example.com/feed.json');
    expect(restored.usesDefaultSource, isFalse);
    expect(
      (await service.check(currentVersion: '0.1.0', platform: 'windows')).state,
      UpdateState.upToDate,
    );
    service.dispose();
    restored.dispose();
  });

  test(
    'published docs feeds parse and same version reports upToDate',
    () async {
      for (final platform in ['windows', 'android']) {
        final file = File('docs/update-feed-$platform.json');
        expect(file.existsSync(), isTrue, reason: file.path);
        final text = file.readAsStringSync();
        final parsed = parseUpdateMetadata(text, platform: platform);
        expect(parsed.version, '0.3.1+4');
        expect(parsed.downloadUrl.host, 'github.com');
        expect(
          parsed.downloadUrl.path,
          contains('/034714/wordnest/releases/download/v0.3.1/'),
        );
        var calls = 0;
        SharedPreferences.setMockInitialValues({});
        final service = UpdateService(
          resolver: (_) async => [InternetAddress('8.8.8.8')],
          transport: okTransport(
            utf8.encode(text),
            onCall: (uri, _) {
              calls++;
              expect(
                uri.toString(),
                UpdateService.defaultSourceUrlFor(platform),
              );
            },
          ),
        );
        await service.initialize();
        final result = await service.check(
          currentVersion: '0.3.1+4',
          platform: platform,
        );
        expect(result.state, UpdateState.upToDate);
        expect(result.metadata?.downloadUrl.host, 'github.com');
        expect(calls, 1);
        service.dispose();
      }
    },
  );

  test('preferences opt in, persist, clear source and check feed', () async {
    SharedPreferences.setMockInitialValues({});
    final service = UpdateService();
    await service.initialize();
    expect(service.autoCheck, isFalse);
    await service.setSourceUrl('updates.example.com/feed.json');
    await service.setAutoCheck(true);
    final restored = UpdateService(
      resolver: (_) async => [InternetAddress('8.8.8.8')],
      transport: okTransport(
        utf8.encode(
          metadata(
            platform: 'windows',
            url: 'https://updates.example.com/app.msix',
          ),
        ),
      ),
    );
    await restored.initialize();
    expect(restored.autoCheck, isTrue);
    expect(restored.sourceUrl, 'https://updates.example.com/feed.json');
    expect(
      (await restored.check(
        currentVersion: '0.1.0',
        platform: 'windows',
      )).state,
      UpdateState.available,
    );
    await restored.setSourceUrl('');
    expect(
      (await restored.check(
        currentVersion: '0.1.0',
        platform: 'windows',
      )).state,
      UpdateState.noSource,
    );
    service.dispose();
    restored.dispose();
  });

  test(
    'DNS rebinding blocked before transport and each redirect resolved',
    () async {
      SharedPreferences.setMockInitialValues({});
      var resolutions = 0;
      var requests = 0;
      final service = UpdateService(
        resolver: (_) async => [
          InternetAddress(++resolutions == 1 ? '8.8.8.8' : '127.0.0.1'),
        ],
        proxyProbe: (_) async => null,
        transport: (uri, address) async {
          requests++;
          expect(uri.host, 'updates.example.com');
          expect(address.address, '8.8.8.8');
          return const FetchResponse(302, [], location: '/next.json');
        },
      );
      await service.initialize();
      await service.setSourceUrl('updates.example.com/feed.json');
      expect(
        (await service.check(
          currentVersion: '0.1.0',
          platform: 'android',
        )).state,
        UpdateState.invalid,
      );
      expect(requests, 1);
      expect(resolutions, 2);
      service.dispose();
    },
  );

  test('redirect restrictions, mixed DNS, HTTP failure and bounds', () async {
    for (final location in [
      'http://localhost/a',
      'http://example.com/a',
      '/again',
    ]) {
      SharedPreferences.setMockInitialValues({});
      var count = 0;
      final service = UpdateService(
        resolver: (_) async => [InternetAddress('8.8.8.8')],
        transport: (_, _) async {
          count++;
          return FetchResponse(302, const [], location: location);
        },
      );
      await service.initialize();
      await service.setSourceUrl('https://example.com/feed');
      expect(
        (await service.check(
          currentVersion: '0.1.0',
          platform: 'android',
        )).state,
        UpdateState.invalid,
      );
      expect(count, location == '/again' ? 4 : 1);
      service.dispose();
    }
    for (final status in [500, 200]) {
      SharedPreferences.setMockInitialValues({});
      final service = UpdateService(
        resolver: (_) async => [InternetAddress('8.8.8.8')],
        transport: (_, _) async => FetchResponse(
          status,
          List.filled(UpdateService.maxBodyBytes + 1, 32),
        ),
      );
      await service.initialize();
      await service.setSourceUrl('https://example.com/feed');
      expect(
        (await service.check(
          currentVersion: '0.1.0',
          platform: 'android',
        )).state,
        status == 500 ? UpdateState.error : UpdateState.invalid,
      );
      service.dispose();
    }
    SharedPreferences.setMockInitialValues({});
    final mixed = UpdateService(
      resolver: (_) async => [
        InternetAddress('8.8.8.8'),
        InternetAddress('10.0.0.1'),
      ],
      proxyProbe: (_) async => null,
      transport: (_, _) async => throw StateError('must not reach transport'),
    );
    await mixed.initialize();
    await mixed.setSourceUrl('https://example.com/feed');
    expect(
      (await mixed.check(currentVersion: '0.1.0', platform: 'android')).state,
      UpdateState.invalid,
    );
    mixed.dispose();
  });

  test(
    'timeout fails without HTTP and auto gate persists across restarts',
    () async {
      SharedPreferences.setMockInitialValues({});
      final slow = UpdateService(
        timeout: const Duration(milliseconds: 5),
        resolver: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return [InternetAddress('8.8.8.8')];
        },
        proxyProbe: (_) async => null,
        transport: (_, _) async => throw StateError('must not reach transport'),
      );
      await slow.initialize();
      await slow.setSourceUrl('https://example.com/feed');
      expect(
        (await slow.check(currentVersion: '0.1.0', platform: 'android')).state,
        UpdateState.error,
      );
      slow.dispose();

      SharedPreferences.setMockInitialValues({});
      var now = DateTime.utc(2026, 10, 11);
      var requests = 0;
      UpdateService create() => UpdateService(
        now: () => now,
        resolver: (_) async => [InternetAddress('8.8.8.8')],
        transport: (_, _) async {
          requests++;
          return FetchResponse(200, utf8.encode(metadata(version: '0.1.0')));
        },
      );
      final first = create();
      await first.initialize();
      await first.setSourceUrl('https://example.com/feed');
      expect(
        await first.checkAutomatically(
          currentVersion: '0.1.0',
          platform: 'android',
        ),
        isNull,
      );
      await first.setAutoCheck(true);
      expect(
        (await first.checkAutomatically(
          currentVersion: '0.1.0',
          platform: 'android',
        ))?.state,
        UpdateState.upToDate,
      );
      final second = create();
      await second.initialize();
      expect(
        await second.checkAutomatically(
          currentVersion: '0.1.0',
          platform: 'android',
        ),
        isNull,
      );
      expect(requests, 1);
      now = now.add(const Duration(days: 1));
      await second.checkAutomatically(
        currentVersion: '0.1.0',
        platform: 'android',
      );
      expect(requests, 2);
      await second.setSourceUrl('');
      await second.check(currentVersion: '0.1.0', platform: 'android');
      expect(requests, 2);
      first.dispose();
      second.dispose();
    },
  );

  test('proxy detection parses PAC directives and registry values', () {
    expect(
      firstProxyDirective('PROXY 127.0.0.1:7890; DIRECT'),
      '127.0.0.1:7890',
    );
    expect(firstProxyDirective('DIRECT'), isNull);
    expect(firstProxyDirective(''), isNull);
    expect(firstProxyDirective('SOCKS5 127.0.0.1:7890'), isNull);
    final pac = HttpClient.findProxyFromEnvironment(
      Uri.parse('https://example.com/feed.json'),
      environment: {'https_proxy': 'http://127.0.0.1:7890'},
    );
    expect(firstProxyDirective(pac), '127.0.0.1:7890');
    expect(proxyServerFromRegistry('127.0.0.1:7890'), '127.0.0.1:7890');
    expect(
      proxyServerFromRegistry('http=127.0.0.1:7891;https=127.0.0.1:7890'),
      '127.0.0.1:7890',
    );
    expect(proxyServerFromRegistry('  '), isNull);
    expect(isFakeIpAddress(InternetAddress('198.18.0.58')), isTrue);
    expect(isFakeIpAddress(InternetAddress('198.19.255.1')), isTrue);
    expect(isFakeIpAddress(InternetAddress('8.8.8.8')), isFalse);
    expect(isFakeIpAddress(InternetAddress('127.0.0.1')), isFalse);
    // ULA is genuinely private, not a proxy fake-ip pool: fail closed.
    expect(isFakeIpAddress(InternetAddress('fc00::1')), isFalse);
  });

  test('fake-ip DNS with system proxy succeeds through proxy path', () async {
    SharedPreferences.setMockInitialValues({});
    var pinned = 0;
    var probes = 0;
    String? usedProxy;
    Uri? proxiedTarget;
    final service = UpdateService(
      resolver: (_) async => [InternetAddress('198.18.0.58')],
      transport: (_, _) async {
        pinned++;
        throw StateError('pinned path must not be used');
      },
      proxyProbe: (uri) async {
        probes++;
        expect(uri.host, 'raw.githubusercontent.com');
        return '127.0.0.1:7890';
      },
      proxiedFetch: (uri, proxy) async {
        proxiedTarget = uri;
        usedProxy = proxy;
        return FetchResponse(
          200,
          utf8.encode(metadata(version: '0.2.0', platform: 'android')),
        );
      },
    );
    await service.initialize();
    final result = await service.check(
      currentVersion: '0.1.0',
      platform: 'android',
    );
    expect(result.state, UpdateState.available);
    expect(result.metadata?.version, '0.2.0');
    expect(pinned, 0);
    expect(probes, 1);
    expect(usedProxy, '127.0.0.1:7890');
    expect(
      proxiedTarget.toString(),
      UpdateService.defaultSourceUrlFor('android'),
    );
    service.dispose();
  });

  test('fake-ip DNS without proxy reports fake-ip guidance', () async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    final service = UpdateService(
      resolver: (_) async => [InternetAddress('198.18.0.58')],
      transport: (_, _) async {
        calls++;
        return const FetchResponse(200, []);
      },
      proxyProbe: (_) async => null,
      proxiedFetch: (_, _) async {
        calls++;
        return const FetchResponse(200, []);
      },
    );
    await service.initialize();
    final result = await service.check(
      currentVersion: '0.1.0',
      platform: 'android',
    );
    expect(result.state, UpdateState.error);
    expect(result.message, contains('fake-ip'));
    expect(result.message, contains('系统代理'));
    expect(calls, 0);
    service.dispose();
  });

  test('public DNS keeps pinned path and never probes proxy', () async {
    SharedPreferences.setMockInitialValues({});
    var pinned = 0;
    var probes = 0;
    var proxied = 0;
    final service = UpdateService(
      resolver: (_) async => [InternetAddress('8.8.8.8')],
      transport: (uri, address) async {
        pinned++;
        expect(address.address, '8.8.8.8');
        return FetchResponse(
          200,
          utf8.encode(metadata(version: '0.2.0', platform: 'android')),
        );
      },
      proxyProbe: (_) async {
        probes++;
        return '127.0.0.1:7890';
      },
      proxiedFetch: (_, _) async {
        proxied++;
        return const FetchResponse(200, []);
      },
    );
    await service.initialize();
    expect(
      (await service.check(currentVersion: '0.1.0', platform: 'android')).state,
      UpdateState.available,
    );
    expect(pinned, 1);
    expect(probes, 0);
    expect(proxied, 0);
    service.dispose();
  });

  test('redirect to private host rejected in pinned and proxy paths', () async {
    SharedPreferences.setMockInitialValues({});
    var proxied = 0;
    final pinnedService = UpdateService(
      resolver: (_) async => [InternetAddress('8.8.8.8')],
      transport: (_, _) async =>
          const FetchResponse(302, [], location: 'https://127.0.0.1/x.json'),
      proxyProbe: (_) async => '127.0.0.1:7890',
      proxiedFetch: (_, _) async {
        proxied++;
        return const FetchResponse(200, []);
      },
    );
    await pinnedService.initialize();
    expect(
      (await pinnedService.check(
        currentVersion: '0.1.0',
        platform: 'android',
      )).state,
      UpdateState.invalid,
    );
    expect(proxied, 0);
    pinnedService.dispose();

    SharedPreferences.setMockInitialValues({});
    var pinnedCalls = 0;
    final proxiedService = UpdateService(
      resolver: (_) async => [InternetAddress('198.18.0.58')],
      transport: (_, _) async {
        pinnedCalls++;
        throw StateError('pinned path must not be used');
      },
      proxyProbe: (_) async => '127.0.0.1:7890',
      proxiedFetch: (_, _) async =>
          const FetchResponse(302, [], location: 'https://10.0.0.1/x.json'),
    );
    await proxiedService.initialize();
    expect(
      (await proxiedService.check(
        currentVersion: '0.1.0',
        platform: 'android',
      )).state,
      UpdateState.invalid,
    );
    expect(pinnedCalls, 0);
    proxiedService.dispose();
  });
}
