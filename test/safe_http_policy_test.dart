import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/platform/safe_http.dart';

const _trustedHosts = [
  'raw.githubusercontent.com',
  'github.com',
  'release-assets.githubusercontent.com',
  'objects.githubusercontent.com',
  'api.github.com',
];

class _PolicyHarness {
  _PolicyHarness({
    required this.resolver,
    this.proxy = '127.0.0.1:7890',
    this.pinnedFetch,
    this.proxiedFetch,
  });

  final AddressResolver resolver;
  final String? proxy;
  final PinnedFetch? pinnedFetch;
  final ProxiedFetch? proxiedFetch;
  final resolvedHosts = <String>[];
  final pinnedUris = <Uri>[];
  final pinnedAddresses = <InternetAddress>[];
  final proxyProbes = <Uri>[];
  final proxiedUris = <Uri>[];
  final proxyEndpoints = <String>[];

  Future<FetchResponse> get([
    String url = 'https://raw.githubusercontent.com/owner/repo/main/feed.json',
  ]) => safeHttpGet(
    uri: Uri.parse(url),
    resolver: (host) async {
      resolvedHosts.add(host);
      return await resolver(host);
    },
    timeout: const Duration(seconds: 5),
    maxBodyBytes: 1024,
    transport: (uri, address) async {
      pinnedUris.add(uri);
      pinnedAddresses.add(address);
      return await pinnedFetch?.call(uri, address) ??
          const FetchResponse(200, []);
    },
    proxyProbe: (uri) async {
      proxyProbes.add(uri);
      return proxy;
    },
    proxiedFetch: (uri, endpoint) async {
      proxiedUris.add(uri);
      proxyEndpoints.add(endpoint);
      return await proxiedFetch?.call(uri, endpoint) ??
          const FetchResponse(200, []);
    },
  );

  void expectNoTransportOrProxy() {
    expect(pinnedUris, isEmpty);
    expect(proxyProbes, isEmpty);
    expect(proxiedUris, isEmpty);
  }
}

void main() {
  test('only benchmark IPv4 DNS answers count as fake-ip', () {
    for (final address in [
      '198.18.0.0',
      '198.18.255.255',
      '198.19.0.0',
      '198.19.255.255',
    ]) {
      expect(
        isFakeIpAddress(InternetAddress(address)),
        isTrue,
        reason: address,
      );
      expect(
        isPublicAddress(InternetAddress(address)),
        isFalse,
        reason: address,
      );
    }
    for (final address in [
      '198.17.255.255',
      '198.20.0.0',
      '198.51.100.1',
      '8.8.8.8',
      '127.0.0.1',
      'fc00::1',
      'fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff',
      '::ffff:198.18.0.1',
    ]) {
      expect(
        isFakeIpAddress(InternetAddress(address)),
        isFalse,
        reason: address,
      );
    }
  });

  test('URL gate rejects unsafe targets before DNS or proxy lookup', () async {
    for (final url in [
      'file:///etc/passwd',
      'ftp://github.com/feed.json',
      'http://localhost/feed.json',
      'https://child.localhost/feed.json',
      'https://127.0.0.1/feed.json',
      'https://198.18.0.1/feed.json',
      'https://198.19.255.255/feed.json',
      'https://[fc00::1]/feed.json',
      'https://user:pass@github.com/feed.json',
    ]) {
      final harness = _PolicyHarness(
        resolver: (_) async => [InternetAddress('8.8.8.8')],
      );
      await expectLater(harness.get(url), throwsFormatException, reason: url);
      expect(harness.resolvedHosts, isEmpty);
      harness.expectNoTransportOrProxy();
    }
  });

  test(
    'private, loopback, link-local and reserved DNS reject a proxy',
    () async {
      for (final host in ['raw.githubusercontent.com', 'updates.example.com']) {
        for (final address in [
          '0.0.0.0',
          '10.0.0.1',
          '127.0.0.1',
          '100.64.0.1',
          '169.254.169.254',
          '172.16.0.1',
          '192.168.1.1',
          '192.0.2.1',
          '198.51.100.1',
          '203.0.113.1',
          '224.0.0.1',
          '::1',
          'fc00::1',
          'fd00::1',
          'fe80::1',
          '2001:db8::1',
          '::ffff:127.0.0.1',
        ]) {
          final harness = _PolicyHarness(
            resolver: (_) async => [InternetAddress(address)],
          );
          await expectLater(
            harness.get('https://$host/feed.json'),
            throwsFormatException,
            reason: '$host -> $address',
          );
          harness.expectNoTransportOrProxy();
        }
      }
    },
  );

  test('mixed DNS answers fail before probing even a trusted proxy', () async {
    for (final addresses in [
      ['8.8.8.8', '127.0.0.1'],
      ['10.0.0.1', '8.8.8.8'],
      ['8.8.8.8', '198.18.0.1'],
      ['198.19.0.1', '8.8.8.8'],
      ['198.18.0.1', '10.0.0.1'],
      ['198.18.0.1', 'fc00::1'],
      ['2606:4700:4700::1111', 'fd00::1'],
    ]) {
      final harness = _PolicyHarness(
        resolver: (_) async => addresses.map(InternetAddress.new).toList(),
      );
      await expectLater(
        harness.get(),
        throwsFormatException,
        reason: addresses.join(', '),
      );
      harness.expectNoTransportOrProxy();
    }
  });

  test(
    'untrusted hosts cannot delegate failed or fake DNS to a proxy',
    () async {
      for (final host in [
        'updates.example.com',
        'raw.githubusercontent.com.evil.example',
        'sub.raw.githubusercontent.com',
        'github.com.evil.example',
        'objects.github.com',
      ]) {
        const error = SocketException('DNS lookup failed');
        final failed = _PolicyHarness(resolver: (_) async => throw error);
        await expectLater(
          failed.get('https://$host/feed.json'),
          throwsA(same(error)),
          reason: host,
        );
        failed.expectNoTransportOrProxy();

        for (final answers in [
          <InternetAddress>[],
          [InternetAddress('198.18.0.1'), InternetAddress('198.19.255.255')],
        ]) {
          final harness = _PolicyHarness(resolver: (_) async => answers);
          await expectLater(
            harness.get('https://$host/feed.json'),
            throwsFormatException,
            reason: host,
          );
          harness.expectNoTransportOrProxy();
        }
      }
    },
  );

  test('exact trusted source hosts can use all-benchmark fake-ip', () async {
    for (final host in _trustedHosts) {
      final harness = _PolicyHarness(
        resolver: (_) async => [
          InternetAddress('198.18.0.1'),
          InternetAddress('198.19.255.255'),
        ],
      );
      final response = await harness.get('https://$host/feed.json');
      expect(response.statusCode, 200);
      expect(harness.resolvedHosts, [host]);
      expect(harness.pinnedUris, isEmpty);
      expect(harness.proxyProbes.single.host, host);
      expect(harness.proxiedUris.single.host, host);
      // A loopback system proxy is transport, not the URL destination.
      expect(harness.proxyEndpoints, ['127.0.0.1:7890']);
    }
  });

  test('only exact trusted hosts can proxy failed or empty DNS', () async {
    for (final host in _trustedHosts) {
      for (final resolver in <AddressResolver>[
        (_) async => throw const SocketException('DNS lookup failed'),
        (_) async => [],
      ]) {
        final harness = _PolicyHarness(resolver: resolver);
        expect((await harness.get('https://$host/feed.json')).statusCode, 200);
        expect(harness.pinnedUris, isEmpty);
        expect(harness.proxyProbes.single.host, host);
        expect(harness.proxiedUris.single.host, host);
      }
    }
  });

  test(
    'trusted host comparison normalizes case and one trailing dot',
    () async {
      final harness = _PolicyHarness(
        resolver: (_) async => [InternetAddress('198.18.0.1')],
      );
      expect(
        (await harness.get('https://RAW.GITHUBUSERCONTENT.COM./feed.json'))
            .statusCode,
        200,
      );
      expect(harness.resolvedHosts, ['raw.githubusercontent.com']);
      expect(harness.proxiedUris, hasLength(1));
    },
  );

  test('trusted fake-ip without proxy reports guidance, never pins', () async {
    final harness = _PolicyHarness(
      resolver: (_) async => [InternetAddress('198.18.0.1')],
      proxy: null,
    );
    await expectLater(harness.get(), throwsA(isA<FakeIpDnsException>()));
    expect(harness.proxyProbes, hasLength(1));
    expect(harness.pinnedUris, isEmpty);
    expect(harness.proxiedUris, isEmpty);
  });

  test('trusted DNS failure without proxy preserves the DNS error', () async {
    const error = SocketException('DNS lookup failed');
    final harness = _PolicyHarness(
      resolver: (_) async => throw error,
      proxy: null,
    );
    await expectLater(harness.get(), throwsA(same(error)));
    expect(harness.proxyProbes, hasLength(1));
    expect(harness.pinnedUris, isEmpty);
    expect(harness.proxiedUris, isEmpty);
  });

  test('all-public DNS pins the first address, never probes a proxy', () async {
    for (final host in ['raw.githubusercontent.com', 'updates.example.com']) {
      for (final addresses in [
        ['8.8.8.8', '2606:4700:4700::1111'],
        ['2606:4700:4700::1111', '8.8.8.8'],
      ]) {
        final harness = _PolicyHarness(
          resolver: (_) async => addresses.map(InternetAddress.new).toList(),
        );
        expect((await harness.get('https://$host/feed.json')).statusCode, 200);
        expect(harness.pinnedUris.single.host, host);
        expect(harness.pinnedAddresses.single.address, addresses.first);
        expect(harness.resolvedHosts, [host]);
        expect(harness.proxyProbes, isEmpty);
        expect(harness.proxiedUris, isEmpty);
      }
    }
  });

  test('pinned transport failure never broadens proxy fallback', () async {
    const error = SocketException('connection failed');
    final harness = _PolicyHarness(
      resolver: (_) async => [InternetAddress('8.8.8.8')],
      pinnedFetch: (_, _) async => throw error,
    );
    await expectLater(harness.get(), throwsA(same(error)));
    expect(harness.pinnedUris, hasLength(1));
    expect(harness.proxyProbes, isEmpty);
    expect(harness.proxiedUris, isEmpty);
  });

  test('proxy redirects cannot bypass private or mixed DNS policy', () async {
    for (final addresses in [
      ['127.0.0.1'],
      ['10.0.0.1'],
      ['fc00::1'],
      ['fd00::1'],
      ['8.8.8.8', '10.0.0.1'],
      ['198.18.0.1', 'fc00::1'],
    ]) {
      final harness = _PolicyHarness(
        resolver: (host) async => host == 'raw.githubusercontent.com'
            ? [InternetAddress('198.18.0.1')]
            : addresses.map(InternetAddress.new).toList(),
        proxiedFetch: (_, _) async => const FetchResponse(
          302,
          [],
          location: 'https://github.com/redirect.json',
        ),
      );
      await expectLater(
        harness.get(),
        throwsFormatException,
        reason: addresses.join(', '),
      );
      expect(harness.resolvedHosts, [
        'raw.githubusercontent.com',
        'github.com',
      ]);
      expect(harness.pinnedUris, isEmpty);
      expect(harness.proxyProbes, hasLength(1));
      expect(harness.proxiedUris, hasLength(1));
    }
  });

  test('proxy redirects reject untrusted failed or fake DNS', () async {
    for (final failsDns in [true, false]) {
      final harness = _PolicyHarness(
        resolver: (host) async {
          if (host == 'updates.example.com' && failsDns) {
            throw const SocketException('redirect DNS lookup failed');
          }
          return [InternetAddress('198.18.0.1')];
        },
        proxiedFetch: (_, _) async => const FetchResponse(
          302,
          [],
          location: 'https://updates.example.com/redirect.json',
        ),
      );
      await expectLater(
        harness.get(),
        failsDns ? throwsA(isA<SocketException>()) : throwsFormatException,
      );
      expect(harness.resolvedHosts, [
        'raw.githubusercontent.com',
        'updates.example.com',
      ]);
      expect(harness.pinnedUris, isEmpty);
      expect(harness.proxyProbes, hasLength(1));
      expect(harness.proxiedUris, hasLength(1));
    }
  });

  test(
    'proxy redirects still reject unsafe literals, schemes and downgrade',
    () async {
      for (final location in [
        'https://localhost/redirect.json',
        'https://127.0.0.1/redirect.json',
        'https://198.18.0.1/redirect.json',
        'https://[fc00::1]/redirect.json',
        'file:///etc/passwd',
        'http://github.com/redirect.json',
      ]) {
        final harness = _PolicyHarness(
          resolver: (_) async => [InternetAddress('198.18.0.1')],
          proxiedFetch: (_, _) async =>
              FetchResponse(302, [], location: location),
        );
        await expectLater(
          harness.get(),
          throwsFormatException,
          reason: location,
        );
        expect(harness.resolvedHosts, ['raw.githubusercontent.com']);
        expect(harness.pinnedUris, isEmpty);
        expect(harness.proxyProbes, hasLength(1));
        expect(harness.proxiedUris, hasLength(1));
      }
    },
  );

  test('same-host redirects repeat DNS validation on either route', () async {
    for (final firstAddress in ['8.8.8.8', '198.18.0.1']) {
      var resolutions = 0;
      const redirect = FetchResponse(302, [], location: '/redirect.json');
      final harness = _PolicyHarness(
        resolver: (_) async => [
          InternetAddress(++resolutions == 1 ? firstAddress : '127.0.0.1'),
        ],
        pinnedFetch: (_, _) async => redirect,
        proxiedFetch: (_, _) async => redirect,
      );
      await expectLater(harness.get(), throwsFormatException);
      expect(harness.resolvedHosts, [
        'raw.githubusercontent.com',
        'raw.githubusercontent.com',
      ]);
      expect(harness.pinnedUris.length + harness.proxiedUris.length, 1);
      expect(harness.proxyProbes.length, firstAddress == '8.8.8.8' ? 0 : 1);
    }
  });

  test(
    'trusted redirect with public DNS switches from proxy to pinning',
    () async {
      final harness = _PolicyHarness(
        resolver: (host) async => [
          InternetAddress(host == 'github.com' ? '8.8.8.8' : '198.18.0.1'),
        ],
        proxiedFetch: (_, _) async => const FetchResponse(
          302,
          [],
          location: 'https://github.com/redirect.json',
        ),
      );
      expect((await harness.get()).statusCode, 200);
      expect(harness.resolvedHosts, [
        'raw.githubusercontent.com',
        'github.com',
      ]);
      expect(harness.proxyProbes, hasLength(1));
      expect(harness.proxiedUris.single.host, 'raw.githubusercontent.com');
      expect(harness.pinnedUris.single.host, 'github.com');
      expect(harness.pinnedAddresses.single.address, '8.8.8.8');
    },
  );
}
