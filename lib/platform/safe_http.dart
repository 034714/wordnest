import 'dart:async';
import 'dart:io';

/// Shared hardened HTTP primitives for update and catalog downloads.
///
/// Rules: http/https only with public DNS answers connected by numeric address
/// (no second resolution, no DNS rebinding); HTTPS keeps the original URI host
/// for certificate/SNI. Only exact trusted GitHub hosts may use a system proxy
/// when DNS fails or every answer is in the IPv4 benchmark fake-ip range. Other
/// non-public or mixed answers are rejected even with a proxy configured. The
/// proxy resolves trusted targets itself; every redirect repeats URL and DNS
/// validation. Strict body and time bounds; no installer downloads/execution.
typedef AddressResolver = Future<List<InternetAddress>> Function(String host);

typedef PinnedFetch = Future<FetchResponse> Function(
  Uri uri,
  InternetAddress address,
);

/// Returns a `host:port` proxy endpoint, or null when no proxy is available.
typedef ProxyProbe = Future<String?> Function(Uri uri);

/// Performs a request through the given proxy endpoint without pinning.
typedef ProxiedFetch = Future<FetchResponse> Function(Uri uri, String proxy);

const Set<int> redirectStatusCodes = {301, 302, 303, 307, 308};

// Only these exact public source hosts may delegate destination DNS to a proxy.
// User-supplied update hosts and subdomains do not inherit this exception.
const Set<String> _trustedProxyHosts = {
  'raw.githubusercontent.com',
  'github.com',
  'release-assets.githubusercontent.com',
  'objects.githubusercontent.com',
  'api.github.com',
};

class FetchResponse {
  const FetchResponse(this.statusCode, this.body, {this.location});
  final int statusCode;
  final List<int> body;
  final String? location;
  bool get isRedirect => redirectStatusCodes.contains(statusCode);
}

/// Local DNS answered with proxy fake-ip virtual addresses while no system
/// proxy could be detected, so no safe route exists.
class FakeIpDnsException implements Exception {
  const FakeIpDnsException();
  static const message = '检测到本机代理的虚拟 IP 解析；请在代理中关闭 fake-ip 或改用系统代理模式';
  @override
  String toString() => message;
}

/// Rejects non-public destinations before any network access. This is only a
/// syntax/address gate, NOT a DNS or transport security boundary.
Uri validatePublicHttpUrl(String input) {
  final value = input.trim();
  if (value.isEmpty || RegExp(r'[\s\\]').hasMatch(value)) {
    throw const FormatException('更新地址为空或包含无效字符');
  }
  final uri = Uri.parse(value.contains('://') ? value : 'https://$value');
  if (!{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      (uri.hasPort && uri.port != 80 && uri.port != 443)) {
    throw const FormatException('仅支持公共 HTTP/HTTPS 地址，不允许凭据、片段或非标准端口');
  }
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal') ||
      host.contains('%')) {
    throw const FormatException('不能使用本机或内部地址');
  }
  final address = InternetAddress.tryParse(host);
  if (address != null) {
    if (!isPublicAddress(address)) {
      throw const FormatException('不能使用私有、环回或保留地址');
    }
  } else {
    // Reject legacy integer/octal/hex IPv4 notation and single-label hosts.
    if (!RegExp(
      r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$',
    ).hasMatch(host)) {
      throw const FormatException('必须使用有效的公共域名');
    }
  }
  return uri;
}

/// Public, non-reserved global-unicast check used for every DNS answer before
/// connecting. Unknown/odd address families fail closed.
bool isPublicAddress(InternetAddress address) {
  final b = address.rawAddress;
  if (b.length == 4) {
    final a = b[0], c = b[1], d = b[2];
    return !(a == 0 ||
        a == 10 ||
        a == 127 ||
        a >= 224 ||
        (a == 100 && c >= 64 && c <= 127) ||
        (a == 169 && c == 254) ||
        (a == 172 && c >= 16 && c <= 31) ||
        (a == 192 &&
            (c == 168 ||
                c == 0 ||
                (c == 88 && d == 99) ||
                c == 2 ||
                (c == 31 && d == 196) ||
                (c == 52 && d == 193) ||
                (c == 175 && d == 48))) ||
        (a == 198 && (c == 18 || c == 19 || (c == 51 && d == 100))) ||
        (a == 203 && c == 0 && d == 113));
  }
  // Fail closed: only ordinary global-unicast 2000::/3. Exclude all
  // 2001::/23 special assignments, documentation, 6to4 translation and the
  // special AS112 range. This also rejects mapped IPv4, ULA, link-local,
  // multicast and NAT64.
  return b.length == 16 &&
      (b[0] & 0xe0) == 0x20 &&
      !(b[0] == 0x20 && b[1] == 0x01 && b[2] < 2) &&
      !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) &&
      !(b[0] == 0x20 && b[1] == 0x02) &&
      !(b[0] == 0x26 &&
          b[1] == 0x20 &&
          b[2] == 0 &&
          b[3] == 0x4f &&
          b[4] == 0x80 &&
          b[5] == 0) &&
      !(b[0] == 0x3f && b[1] == 0xff && (b[2] & 0xf0) == 0);
}

/// True only for IPv4 benchmark 198.18.0.0/15, used by proxy fake-ip DNS.
/// IPv6 ULA is genuinely private, not a safe proxy-fallback signal. Benchmark
/// literals are still rejected by [validatePublicHttpUrl]; DNS fake-ip alone
/// never authorizes a proxy request to an untrusted host.
bool isFakeIpAddress(InternetAddress address) {
  final b = address.rawAddress;
  return b.length == 4 && b[0] == 198 && (b[1] == 18 || b[1] == 19);
}

/// First usable PROXY directive of a PAC string; null when the result is
/// DIRECT only or uses unsupported directive types.
String? firstProxyDirective(String pac) {
  for (final raw in pac.split(';')) {
    final directive = raw.trim();
    if (directive.isEmpty) {
      continue;
    }
    final upper = directive.toUpperCase();
    if (upper.startsWith('PROXY ')) {
      final endpoint = directive.substring(6).trim();
      if (endpoint.isNotEmpty) {
        return endpoint;
      }
    }
  }
  return null;
}

/// Parses the Windows `ProxyServer` value: bare `host:port` or a
/// `scheme=host:port;...` list (prefers https, then http).
String? proxyServerFromRegistry(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  if (!trimmed.contains('=')) {
    return trimmed;
  }
  final entries = <String, String>{};
  for (final part in trimmed.split(';')) {
    final index = part.indexOf('=');
    if (index <= 0) {
      continue;
    }
    final endpoint = part.substring(index + 1).trim();
    if (endpoint.isNotEmpty) {
      entries[part.substring(0, index).trim().toLowerCase()] = endpoint;
    }
  }
  if (entries.isEmpty) {
    return null;
  }
  return entries['https'] ?? entries['http'] ?? entries.values.first;
}

/// System proxy lookup: environment variables first (the same rules as
/// [HttpClient.findProxyFromEnvironment]); when no proxy environment exists at
/// all on Windows, falls back to the per-user Internet Settings registry value
/// that the OS "system proxy" toggle writes. `DIRECT` means no proxy.
Future<String?> defaultSystemProxy(Uri uri) async {
  final fromEnvironment = firstProxyDirective(
    HttpClient.findProxyFromEnvironment(uri),
  );
  if (fromEnvironment != null) {
    return fromEnvironment;
  }
  const proxyKeys = [
    'http_proxy',
    'https_proxy',
    'all_proxy',
    'HTTP_PROXY',
    'HTTPS_PROXY',
    'ALL_PROXY',
    'no_proxy',
    'NO_PROXY',
  ];
  final hasProxyEnvironment = proxyKeys.any(
    (key) => (Platform.environment[key] ?? '').isNotEmpty,
  );
  if (hasProxyEnvironment || !Platform.isWindows) {
    return null;
  }
  return _windowsRegistryProxy();
}

Future<String?> _windowsRegistryProxy() async {
  try {
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final reg = '$systemRoot\\System32\\reg.exe';
    const path =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    final enabled = await Process.run(reg, [
      'query',
      path,
      '/v',
      'ProxyEnable',
    ], runInShell: false);
    if (enabled.exitCode != 0 ||
        !RegExp(r'0x1\b').hasMatch(enabled.stdout.toString())) {
      return null;
    }
    final server = await Process.run(reg, [
      'query',
      path,
      '/v',
      'ProxyServer',
    ], runInShell: false);
    if (server.exitCode != 0) {
      return null;
    }
    final match = RegExp(r'ProxyServer\s+REG_SZ\s+(.+)')
        .firstMatch(server.stdout.toString());
    if (match == null) {
      return null;
    }
    return proxyServerFromRegistry(match.group(1)!);
  } catch (_) {
    return null;
  }
}

/// Resolves every address and requires all of them to be public. Used for
/// best-effort checks; transport routing lives in [safeHttpGet].
Future<InternetAddress> resolveValidatedAddress(
  String host,
  AddressResolver resolver,
  Duration timeout,
) async {
  final addresses = await lookupHost(host, resolver, timeout);
  if (addresses.isEmpty ||
      addresses.any((address) => !isPublicAddress(address))) {
    throw const FormatException('域名解析到私有、保留地址或没有有效地址');
  }
  return addresses.first;
}

/// Raw lookup for a hostname or literal IP (literal bypasses the resolver).
Future<List<InternetAddress>> lookupHost(
  String host,
  AddressResolver resolver,
  Duration timeout,
) async {
  final normalized = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  final literal = InternetAddress.tryParse(normalized);
  if (literal != null) {
    return [literal];
  }
  return await resolver(normalized).timeout(timeout);
}

Future<FetchResponse> _exchange(
  HttpClient client,
  Uri uri,
  int maxBodyBytes,
) async {
  final request = await client.getUrl(uri);
  request.followRedirects = false;
  request.headers.set(
    HttpHeaders.acceptHeader,
    'application/json, text/plain, */*',
  );
  request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
  final response = await request.close();
  final location = response.headers.value(HttpHeaders.locationHeader);
  if (response.statusCode != HttpStatus.ok) {
    return FetchResponse(response.statusCode, const [], location: location);
  }
  if (response.contentLength > maxBodyBytes ||
      (response.headers.value(HttpHeaders.contentEncodingHeader) ??
              'identity') !=
          'identity') {
    throw const FormatException('响应过大或使用不支持的压缩编码');
  }
  final bytes = <int>[];
  await for (final chunk in response) {
    if (bytes.length + chunk.length > maxBodyBytes) {
      throw const FormatException('响应内容超过大小限制');
    }
    bytes.addAll(chunk);
  }
  return FetchResponse(response.statusCode, bytes);
}

/// One pinned socket per hop. The URI host is never replaced by the IP, so
/// Host, TLS certificate validation and SNI remain the original hostname.
/// The local SDK http_impl.dart does not add TLS around custom factories, so
/// HTTPS is wrapped explicitly here with no certificate override.
Future<FetchResponse> fetchPinned(
  Uri uri,
  InternetAddress address, {
  required Duration timeout,
  required int maxBodyBytes,
}) async {
  final client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionTimeout = timeout
    ..autoUncompress = false;
  var active = true;
  final watchdog = Timer(timeout, () {
    active = false;
    client.close(force: true);
  });
  ConnectionTask<Socket>? task;
  Socket? liveSocket;
  client.connectionFactory = (target, proxyHost, proxyPort) async {
    if (!active || target != uri || proxyHost != null || proxyPort != null) {
      throw const SocketException('更新连接目标或代理无效');
    }
    final pending = await Socket.startConnect(address, uri.port);
    task = pending;
    if (!active) {
      pending.cancel();
      throw const SocketException('更新连接已取消');
    }
    final socketFuture = pending.socket.then<Socket>((socket) async {
      liveSocket = socket;
      if (!active) {
        socket.destroy();
        throw const SocketException('更新连接已取消');
      }
      if (uri.scheme == 'https') {
        final secure = await SecureSocket.secure(socket, host: uri.host);
        liveSocket = secure;
        if (!active) {
          secure.destroy();
          throw const SocketException('更新连接已取消');
        }
        return secure;
      }
      return socket;
    });
    return ConnectionTask.fromSocket(socketFuture, () {
      pending.cancel();
      liveSocket?.destroy();
    });
  };
  try {
    return await _exchange(client, uri, maxBodyBytes).timeout(timeout);
  } finally {
    watchdog.cancel();
    active = false;
    task?.cancel();
    liveSocket?.destroy();
    client.close(force: true);
  }
}

/// Unpinned proxy transport; callers must authorize the target through
/// [safeHttpGet] first. The proxy performs its own name resolution, which
/// cannot be locally pinned or checked. TLS still verifies the original host;
/// redirects are returned for per-hop policy checks. A loopback/private proxy
/// endpoint is allowed as transport, never as the destination URL.
Future<FetchResponse> fetchViaProxy(
  Uri uri, {
  required String proxy,
  required Duration timeout,
  required int maxBodyBytes,
}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..autoUncompress = false
    ..findProxy = ((_) => 'PROXY $proxy');
  final watchdog = Timer(timeout, () => client.close(force: true));
  try {
    return await _exchange(client, uri, maxBodyBytes).timeout(timeout);
  } finally {
    watchdog.cancel();
    client.close(force: true);
  }
}

/// Manual redirect loop with per-hop URL/DNS validation, public-DNS pinning,
/// a bounded body and a single overall deadline. HTTPS may not be downgraded.
/// Proxy fallback is limited to [_trustedProxyHosts] after DNS failure/empty
/// answers or all-benchmark IPv4 fake-ip answers. Every other non-public or
/// mixed answer fails before proxy lookup. Trusted fake-ip without a system
/// proxy reports explicit guidance instead of connecting to the virtual IP.
Future<FetchResponse> safeHttpGet({
  required Uri uri,
  required AddressResolver resolver,
  required Duration timeout,
  required int maxBodyBytes,
  PinnedFetch? transport,
  ProxyProbe? proxyProbe,
  ProxiedFetch? proxiedFetch,
  int maxRedirects = 3,
}) async {
  final deadline = DateTime.now().add(timeout);
  Duration remaining() {
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) {
      throw TimeoutException('下载超时');
    }
    return left;
  }

  var current = validatePublicHttpUrl(uri.toString());
  for (var hop = 0; hop <= maxRedirects; hop++) {
    List<InternetAddress> answers = const [];
    Object? resolveError;
    StackTrace? resolveStack;
    try {
      answers = await lookupHost(current.host, resolver, remaining());
    } catch (error, stack) {
      resolveError = error;
      resolveStack = stack;
    }
    final allPublic = answers.isNotEmpty && answers.every(isPublicAddress);
    final allFakeIp = answers.isNotEmpty && answers.every(isFakeIpAddress);
    if (answers.isNotEmpty && !allPublic && !allFakeIp) {
      throw const FormatException('域名解析包含私有、保留或混合地址，已拒绝连接');
    }

    FetchResponse fetched;
    if (allPublic) {
      fetched = transport != null
          ? await transport(current, answers.first).timeout(remaining())
          : await fetchPinned(
              current,
              answers.first,
              timeout: remaining(),
              maxBodyBytes: maxBodyBytes,
            );
    } else {
      final host = current.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
      if (!_trustedProxyHosts.contains(host)) {
        if (resolveError != null) {
          Error.throwWithStackTrace(resolveError, resolveStack!);
        }
        throw const FormatException('未经公共 DNS 验证的域名不允许使用代理');
      }
      final proxy = await (proxyProbe ?? defaultSystemProxy)(current)
          .timeout(remaining());
      if (proxy == null) {
        if (allFakeIp) {
          throw const FakeIpDnsException();
        }
        if (resolveError != null) {
          Error.throwWithStackTrace(resolveError, resolveStack!);
        }
        throw const FormatException('域名没有可用地址');
      }
      fetched = proxiedFetch != null
          ? await proxiedFetch(current, proxy).timeout(remaining())
          : await fetchViaProxy(
              current,
              proxy: proxy,
              timeout: remaining(),
              maxBodyBytes: maxBodyBytes,
            );
    }

    if (!fetched.isRedirect) {
      return fetched;
    }
    if (hop == maxRedirects) {
      throw const FormatException('重定向过多');
    }
    final location = fetched.location;
    if (location == null || location.isEmpty) {
      throw const FormatException('重定向缺少目标地址');
    }
    final next = validatePublicHttpUrl(current.resolve(location).toString());
    if (current.scheme == 'https' && next.scheme != 'https') {
      throw const FormatException('不允许 HTTPS 降级重定向');
    }
    current = next;
  }
  throw const FormatException('重定向过多');
}
