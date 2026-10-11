import 'dart:async';
import 'dart:io';

/// Shared hardened HTTP primitives for update and catalog downloads.
///
/// Rules: http/https only with public DNS answers only; each hop is resolved
/// again and connected to by numeric address (no second resolution, no DNS
/// rebinding); HTTPS keeps the original URI host for certificate/SNI; proxies
/// are disabled; redirects are followed manually with revalidation; strict
/// body and time bounds. Nothing here downloads or executes installers.
typedef AddressResolver = Future<List<InternetAddress>> Function(String host);

typedef PinnedFetch = Future<FetchResponse> Function(
  Uri uri,
  InternetAddress address,
);

const Set<int> redirectStatusCodes = {301, 302, 303, 307, 308};

class FetchResponse {
  const FetchResponse(this.statusCode, this.body, {this.location});
  final int statusCode;
  final List<int> body;
  final String? location;
  bool get isRedirect => redirectStatusCodes.contains(statusCode);
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

/// Resolves every address and requires all of them to be public.
Future<InternetAddress> resolveValidatedAddress(
  String host,
  AddressResolver resolver,
  Duration timeout,
) async {
  final normalized = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  final literal = InternetAddress.tryParse(normalized);
  final addresses = literal != null
      ? [literal]
      : await resolver(normalized).timeout(timeout);
  if (addresses.isEmpty ||
      addresses.any((address) => !isPublicAddress(address))) {
    throw const FormatException('域名解析到私有、保留地址或没有有效地址');
  }
  return addresses.first;
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
    return await (() async {
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
    })().timeout(timeout);
  } finally {
    watchdog.cancel();
    active = false;
    task?.cancel();
    liveSocket?.destroy();
    client.close(force: true);
  }
}

/// Manual redirect loop with per-hop address validation and a single overall
/// deadline. HTTPS may not be downgraded. Body is bounded by [maxBodyBytes].
Future<FetchResponse> safeHttpGet({
  required Uri uri,
  required AddressResolver resolver,
  required Duration timeout,
  required int maxBodyBytes,
  PinnedFetch? transport,
  int maxRedirects = 3,
}) async {
  final deadline = DateTime.now().add(timeout);
  Duration remaining() {
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) throw TimeoutException('下载超时');
    return left;
  }

  var current = validatePublicHttpUrl(uri.toString());
  for (var hop = 0; hop <= maxRedirects; hop++) {
    final address = await resolveValidatedAddress(
      current.host,
      resolver,
      remaining(),
    );
    final fetched = transport != null
        ? await transport(current, address).timeout(remaining())
        : await fetchPinned(
            current,
            address,
            timeout: remaining(),
            maxBodyBytes: maxBodyBytes,
          );
    if (!fetched.isRedirect) return fetched;
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
