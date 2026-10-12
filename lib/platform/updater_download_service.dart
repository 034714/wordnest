import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'safe_http.dart';
import 'update_service.dart';

/// Unsigned feeds without a digest may only name the bundled release source.
void validateInstallerHop(Uri uri, UpdateMetadata metadata) {
  validatePublicHttpUrl(uri.toString());
  if (uri.scheme != 'https') {
    throw const FormatException('安装包必须使用 HTTPS');
  }
  if (metadata.sha256 == null) {
    final host = uri.host.toLowerCase();
    final ownedRelease =
        host == 'github.com' &&
        uri.path.startsWith('/034714/wordnest/releases/download/');
    if (!ownedRelease &&
        !{
          'release-assets.githubusercontent.com',
          'objects.githubusercontent.com',
        }.contains(host)) {
      throw const FormatException('无 SHA256 的安装包仅允许词栖官方 GitHub Release');
    }
  }
}

class UpdateDownloadCancelled implements Exception {
  @override
  String toString() => '下载已取消';
}

/// Streams into a file without buffering an installer in memory.
Future<int> writeBoundedInstaller(
  Stream<List<int>> stream,
  File file, {
  required int maxBytes,
  required Duration idleTimeout,
  int? expectedBytes,
  required void Function() checkCancellation,
  required void Function(int) onProgress,
}) async {
  var received = 0;
  final output = await file.open(mode: FileMode.write);
  try {
    await for (final chunk in stream.timeout(idleTimeout)) {
      checkCancellation();
      received += chunk.length;
      if (received > maxBytes ||
          (expectedBytes != null && received > expectedBytes)) {
        throw const FormatException('安装包超过大小限制');
      }
      await output.writeFrom(chunk);
      onProgress(received);
    }
  } finally {
    await output.close();
  }
  checkCancellation();
  if (received == 0 || (expectedBytes != null && received != expectedBytes)) {
    throw const FormatException('安装包不完整');
  }
  return received;
}

Future<String> verifyInstallerDigest(File file, String? expected) async {
  final digest = (await sha256.bind(file.openRead()).first).toString();
  if (expected != null && digest != expected) {
    throw const FormatException('SHA256 不匹配，已删除安装包');
  }
  return digest;
}

class UpdaterDownloadService extends ChangeNotifier {
  UpdaterDownloadService({
    AddressResolver? resolver,
    ProxyProbe? proxyProbe,
    this.timeout = const Duration(minutes: 15),
    this.idleTimeout = const Duration(seconds: 30),
  }) : _resolver = resolver ?? InternetAddress.lookup,
       // ignore: prefer_initializing_formals
       _proxyProbe = proxyProbe;
  static const maxBytes = 512 * 1024 * 1024;
  static const channel = MethodChannel('io.wordnest/updater');
  final AddressResolver _resolver;
  final ProxyProbe? _proxyProbe;
  final Duration timeout, idleTimeout;
  bool busy = false;
  bool _cancelled = false;
  bool _disposed = false;
  int received = 0;
  int? total;
  String status = '';
  File? installer;
  UpdateMetadata? _metadata;
  String? _verifiedDigest;
  HttpClient? _client;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  void _checkCancellation() {
    if (_cancelled) throw UpdateDownloadCancelled();
  }

  Future<String?> _proxy(Uri uri) async {
    if (_proxyProbe != null) return _proxyProbe(uri);
    if (Platform.isAndroid) {
      return channel.invokeMethod<String>('systemProxy', {
        'url': uri.toString(),
      });
    }
    return defaultSystemProxy(uri);
  }

  Future<void> download(UpdateMetadata metadata) async {
    if (busy) return;
    busy = true;
    _cancelled = false;
    received = 0;
    total = metadata.sizeBytes;
    installer = null;
    _verifiedDigest = null;
    status = '正在下载 ${metadata.version}';
    _notify();
    Directory? work;
    try {
      if (metadata.platform != (Platform.isAndroid ? 'android' : 'windows') ||
          (!Platform.isAndroid && !Platform.isWindows)) {
        throw const FormatException('当前平台不支持安装');
      }
      final extension = metadata.platform == 'android' ? '.apk' : '.exe';
      if (!metadata.downloadUrl.path.toLowerCase().endsWith(extension)) {
        throw const FormatException('在线安装仅支持 APK / setup EXE');
      }
      // Require the FIRST URL to be the owned release, not an arbitrary asset.
      if (metadata.sha256 == null &&
          (metadata.downloadUrl.host != 'github.com' ||
              !metadata.downloadUrl.path.startsWith(
                '/034714/wordnest/releases/download/',
              ))) {
        throw const FormatException('无 SHA256 时必须使用官方 Release 地址');
      }
      final root = Platform.isAndroid
          ? Directory((await channel.invokeMethod<String>('cacheDirectory'))!)
          : await getTemporaryDirectory();
      work = await Directory(p.join(root.path, 'wordnest-updates'))
          .create(recursive: true);
      work = await work.createTemp('download-');
      _checkCancellation();
      final partial = File(p.join(work.path, 'installer.part'));
      final response = await safeHttpGet(
        uri: metadata.downloadUrl,
        resolver: _resolver,
        timeout: timeout,
        maxBodyBytes: maxBytes,
        proxyProbe: _proxy,
        validateHop: (uri) {
          _checkCancellation();
          validateInstallerHop(uri, metadata);
        },
        exchange: (client, uri) async {
          _client = client;
          _checkCancellation();
          final request = await client.getUrl(uri).timeout(idleTimeout);
          request.followRedirects = false;
          request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
          final response = await request.close().timeout(idleTimeout);
          if (response.statusCode != 200) {
            return FetchResponse(
              response.statusCode,
              const [],
              location: response.headers.value(HttpHeaders.locationHeader),
            );
          }
          final length = response.contentLength;
          if (length > maxBytes ||
              (metadata.sizeBytes != null &&
                  length >= 0 &&
                  length != metadata.sizeBytes) ||
              (response.headers.value(HttpHeaders.contentEncodingHeader) ??
                      'identity') !=
                  'identity') {
            throw const FormatException('安装包大小或编码不符合要求');
          }
          total = metadata.sizeBytes ?? (length >= 0 ? length : null);
          await writeBoundedInstaller(
            response,
            partial,
            maxBytes: maxBytes,
            idleTimeout: idleTimeout,
            expectedBytes: total,
            checkCancellation: _checkCancellation,
            onProgress: (bytes) {
              received = bytes;
              _notify();
            },
          );
          return const FetchResponse(200, []);
        },
      );
      if (response.statusCode != 200) {
        throw HttpException('下载响应 ${response.statusCode}');
      }
      status = '正在校验安装包';
      _notify();
      final digest = await verifyInstallerDigest(partial, metadata.sha256);
      _checkCancellation();
      final complete = await partial.rename(
        p.join(work.path, 'installer$extension'),
      );
      if (Platform.isAndroid) {
        await channel.invokeMethod<void>('validateApk', {
          'path': complete.path,
        });
      }
      _checkCancellation();
      installer = complete;
      _metadata = metadata;
      _verifiedDigest = digest;
      status =
          '下载与校验完成；请主动点击安装${metadata.sha256 == null ? '（来源未提供 SHA256）' : ''}';
      work =
          null; // retain only a verified file for the explicit install action
    } catch (error) {
      status = _cancelled ? '下载已取消' : '下载失败：$error';
    } finally {
      _client = null;
      if (work != null && await work.exists()) {
        await work.delete(recursive: true);
      }
      busy = false;
      _notify();
    }
  }

  /// Invoked exclusively by the separate user install button, never download.
  Future<void> install() async {
    if (busy || installer == null || _metadata == null) return;
    busy = true;
    _notify();
    try {
      final file = installer!;
      if ((await sha256.bind(file.openRead()).first).toString() !=
          _verifiedDigest) {
        installer = null;
        throw const FormatException('下载文件已被修改，请重新下载');
      }
      if (Platform.isAndroid) {
        final result = await channel.invokeMethod<String>('installApk', {
          'path': file.path,
        });
        status = result == 'permission'
            ? '请允许安装未知应用；返回后再次点击安装（不会自动安装）。'
            : '已打开系统安装确认；取消不会影响现有学习数据。';
      } else if (Platform.isWindows) {
        await Process.start(
          file.path,
          const [],
          runInShell: false,
          mode: ProcessStartMode.detached,
        );
        status = '已启动安装向导；若提示文件占用，请保存后退出词栖（含托盘）。';
      }
    } catch (error) {
      status = '无法启动安装：$error';
    } finally {
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}
