import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'safe_http.dart';

export 'safe_http.dart'
    show
        AddressResolver,
        FakeIpDnsException,
        FetchResponse,
        PinnedFetch,
        ProxiedFetch,
        ProxyProbe,
        defaultSystemProxy,
        firstProxyDirective,
        isFakeIpAddress,
        isPublicAddress,
        proxyServerFromRegistry,
        validatePublicHttpUrl;

/// Kept for existing callers; same as [validatePublicHttpUrl].
Uri validateUpdateUrl(String input) => validatePublicHttpUrl(input);

/// Kept for existing callers; same as [isPublicAddress].
bool isPublicUpdateAddress(InternetAddress address) => isPublicAddress(address);

enum UpdateState { noSource, upToDate, available, invalid, error }

/// Lifecycle of the update source setting. `builtin` means the user never
/// configured a source, so the bundled GitHub feed for the platform is used.
/// `disabled` is an explicit user choice and must stay empty even though a
/// builtin default exists.
enum UpdateSourceMode { builtin, custom, disabled }

class UpdateCheckResult {
  const UpdateCheckResult(this.state, this.message, {this.metadata});
  final UpdateState state;
  final String message;
  final UpdateMetadata? metadata;
}

class UpdateMetadata {
  const UpdateMetadata(this.version, this.platform, this.downloadUrl);
  final String version;
  final String platform;
  final Uri downloadUrl;
}

List<int> _version(String value) {
  if (!RegExp(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\+(0|[1-9]\d*))?$')
          .hasMatch(value) ||
      value.length > 64) {
    throw const FormatException('版本必须为 major.minor.patch[+build]');
  }
  final parts = value.split(RegExp(r'[.+]')).map(int.parse).toList();
  if (parts.length == 3) {
    parts.add(0);
  }
  return parts;
}

int compareUpdateVersions(String a, String b) {
  final left = _version(a), right = _version(b);
  for (var i = 0; i < 4; i++) {
    final comparison = left[i].compareTo(right[i]);
    if (comparison != 0) {
      return comparison;
    }
  }
  return 0;
}

UpdateMetadata parseUpdateMetadata(String body, {required String platform}) {
  if (utf8.encode(body).length > UpdateService.maxBodyBytes) {
    throw const FormatException('更新元数据过大');
  }
  if (!{'android', 'windows'}.contains(platform)) {
    throw const FormatException('不支持此更新平台');
  }
  final data = jsonDecode(body);
  if (data is! Map<String, dynamic> ||
      data['version'] is! String ||
      data['platform'] != platform ||
      data['downloadUrl'] is! String) {
    throw const FormatException('元数据必须包含版本、匹配的平台与下载地址');
  }
  final version = data['version'] as String;
  _version(version);
  final url = validatePublicHttpUrl(data['downloadUrl'] as String);
  final expected = platform == 'android' ? ['.apk'] : ['.exe', '.msix', '.zip'];
  if (!expected.any(
    (extension) => url.path.toLowerCase().endsWith(extension),
  )) {
    throw const FormatException('下载文件类型与平台不匹配');
  }
  return UpdateMetadata(version, platform, url);
}

/// Fetches metadata only; never downloads or executes installers.
class UpdateService extends ChangeNotifier {
  UpdateService({
    AddressResolver? resolver,
    PinnedFetch? transport,
    ProxyProbe? proxyProbe,
    ProxiedFetch? proxiedFetch,
    DateTime Function()? now,
    this.timeout = requestTimeout,
  }) : _resolver = resolver ?? InternetAddress.lookup,
       // Public named parameters cannot be private initializing formals.
       // ignore: prefer_initializing_formals
       _transport = transport,
       // ignore: prefer_initializing_formals
       _proxyProbe = proxyProbe,
       // ignore: prefer_initializing_formals
       _proxiedFetch = proxiedFetch,
       _now = now ?? DateTime.now;

  static const maxBodyBytes = 64 * 1024;
  static const requestTimeout = Duration(seconds: 10);
  static const maxRedirects = 3;
  static const autoInterval = Duration(days: 1);
  static const _urlKey = 'wordnest.update.source.v1';
  static const _autoKey = 'wordnest.update.auto.v1';
  static const _lastAutoKey = 'wordnest.update.lastAuto.v1';
  static const _modeKey = 'wordnest.update.source.mode.v1';

  /// Bundled public feeds. They resolve once the matching GitHub release
  /// assets exist; until then a configured feed simply reports its version.
  static const defaultSourceUrls = <String, String>{
    'windows': 'https://raw.githubusercontent.com/034714/wordnest/main/docs/update-feed-windows.json',
    'android': 'https://raw.githubusercontent.com/034714/wordnest/main/docs/update-feed-android.json',
  };

  static String? defaultSourceUrlFor(String platform) =>
      defaultSourceUrls[platform];

  final AddressResolver _resolver;
  final PinnedFetch? _transport;
  final ProxyProbe? _proxyProbe;
  final ProxiedFetch? _proxiedFetch;
  final DateTime Function() _now;
  final Duration timeout;
  SharedPreferences? _prefs;
  String _customSourceUrl = '';
  UpdateSourceMode _sourceMode = UpdateSourceMode.builtin;
  bool _autoCheck = false;
  UpdateCheckResult? _lastResult;
  Future<UpdateCheckResult>? _checking;
  Future<UpdateCheckResult?>? _automatic;
  Timer? _autoTimer;
  bool _disposed = false;

  /// Stored custom URL; empty while the builtin default or the disabled state
  /// is active.
  String get sourceUrl => _customSourceUrl;
  bool get autoCheck => _autoCheck;
  UpdateSourceMode get sourceMode => _sourceMode;
  bool get usesDefaultSource => _sourceMode == UpdateSourceMode.builtin;
  bool get sourceDisabled => _sourceMode == UpdateSourceMode.disabled;
  UpdateCheckResult? get lastResult => _lastResult;

  /// URL the next check would actually fetch for [platform].
  String effectiveSourceUrlFor(String platform) {
    switch (_sourceMode) {
      case UpdateSourceMode.custom:
        return _customSourceUrl;
      case UpdateSourceMode.builtin:
        return defaultSourceUrlFor(platform) ?? '';
      case UpdateSourceMode.disabled:
        return '';
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> initialize() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    _customSourceUrl = prefs.getString(_urlKey) ?? '';
    _autoCheck = prefs.getBool(_autoKey) ?? false;
    final mode = prefs.getString(_modeKey);
    if (mode != null && UpdateSourceMode.values.any((e) => e.name == mode)) {
      _sourceMode = UpdateSourceMode.values.firstWhere((e) => e.name == mode);
    } else {
      // Migration: a stored URL means custom; a never-configured install gets
      // the bundled default instead of the old implicit "disabled" state.
      _sourceMode = _customSourceUrl.isEmpty
          ? UpdateSourceMode.builtin
          : UpdateSourceMode.custom;
    }
    _notify();
  }

  /// Empty input explicitly disables checking; use [useDefaultSource] to
  /// return to the bundled default.
  Future<void> setSourceUrl(String value) async {
    final url = value.trim().isEmpty
        ? ''
        : validatePublicHttpUrl(value).toString();
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    if (!await prefs.setString(_urlKey, url)) {
      throw StateError('无法保存更新地址');
    }
    final mode = url.isEmpty
        ? UpdateSourceMode.disabled
        : UpdateSourceMode.custom;
    if (!await prefs.setString(_modeKey, mode.name)) {
      throw StateError('无法保存更新地址状态');
    }
    _customSourceUrl = url;
    _sourceMode = mode;
    _notify();
  }

  Future<void> useDefaultSource() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    if (!await prefs.setString(_urlKey, '') ||
        !await prefs.setString(_modeKey, UpdateSourceMode.builtin.name)) {
      throw StateError('无法保存更新地址状态');
    }
    _customSourceUrl = '';
    _sourceMode = UpdateSourceMode.builtin;
    _notify();
  }

  Future<void> setAutoCheck(bool value) async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    if (!await prefs.setBool(_autoKey, value)) {
      throw StateError('无法保存自动检查设置');
    }
    _autoCheck = value;
    _notify();
  }

  Future<UpdateCheckResult> check({
    required String currentVersion,
    required String platform,
  }) {
    return _checking ??=
        _check(currentVersion: currentVersion, platform: platform).whenComplete(
          () {
            _checking = null;
          },
        );
  }

  Future<UpdateCheckResult> _check({
    required String currentVersion,
    required String platform,
  }) async {
    final source = effectiveSourceUrlFor(platform);
    UpdateCheckResult result;
    if (source.isEmpty) {
      result = UpdateCheckResult(
        UpdateState.noSource,
        sourceDisabled ? '更新来源已关闭；不会发起任何网络请求。' : '当前平台没有可用的默认更新来源，尚未配置更新源。',
      );
    } else {
      try {
        final uri = validatePublicHttpUrl(source);
        _version(currentVersion);
        if (!{'android', 'windows'}.contains(platform)) {
          throw const FormatException('不支持此更新平台');
        }
        final response = await safeHttpGet(
          uri: uri,
          resolver: _resolver,
          timeout: timeout,
          maxBodyBytes: maxBodyBytes,
          maxRedirects: maxRedirects,
          transport: _transport,
          proxyProbe: _proxyProbe,
          proxiedFetch: _proxiedFetch,
        );
        final responseStatus = response.statusCode;
        if (responseStatus != HttpStatus.ok) {
          throw HttpException('更新服务器响应 $responseStatus');
        }
        if (response.body.length > maxBodyBytes) {
          throw const FormatException('更新元数据过大');
        }
        final metadata = parseUpdateMetadata(
          utf8.decode(response.body),
          platform: platform,
        );
        // Best-effort download-host check. Future downloads revalidate through
        // the same hardened path; fake-ip proxy environments resolve to
        // benchmark ranges here and must not fail the metadata check.
        try {
          await resolveValidatedAddress(
            metadata.downloadUrl.host,
            _resolver,
            timeout,
          ).timeout(timeout);
        } catch (_) {
          // Hostname/literal rules were already enforced by the metadata
          // parser; DNS-level routing is decided at download time.
        }
        final newer =
            compareUpdateVersions(metadata.version, currentVersion) > 0;
        result = UpdateCheckResult(
          newer ? UpdateState.available : UpdateState.upToDate,
          newer ? '发现新版本 ${metadata.version}；请自行确认下载来源。' : '当前已是最新版本。',
          metadata: metadata,
        );
      } on FakeIpDnsException catch (error) {
        result = UpdateCheckResult(UpdateState.error, error.toString());
      } on FormatException catch (error) {
        result = UpdateCheckResult(UpdateState.invalid, '更新配置或元数据无效：$error');
      } catch (error) {
        result = UpdateCheckResult(UpdateState.error, '更新检查失败：$error');
      }
    }
    _lastResult = result;
    _notify();
    return result;
  }

  /// Startup/resume hook; opt-in, persisted at most one attempt per 24 hours.
  /// Failures count too, preventing retry loops on broken feeds.
  Future<UpdateCheckResult?> checkAutomatically({
    required String currentVersion,
    required String platform,
  }) {
    return _automatic ??= _auto(currentVersion, platform).whenComplete(() {
      _automatic = null;
    });
  }

  Future<UpdateCheckResult?> _auto(String version, String platform) async {
    if (!_autoCheck || _disposed || effectiveSourceUrlFor(platform).isEmpty) {
      return null;
    }
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    final now = _now().millisecondsSinceEpoch;
    final last = prefs.getInt(_lastAutoKey);
    if (last != null && now - last < autoInterval.inMilliseconds) {
      return null;
    }
    if (!await prefs.setInt(_lastAutoKey, now)) {
      throw StateError('无法保存更新检查时间');
    }
    return check(currentVersion: version, platform: platform);
  }

  /// Parent calls after initialize. Startup check plus hourly daily-gate poll.
  void startAutoChecks({
    required String currentVersion,
    required String platform,
  }) {
    _autoTimer?.cancel();
    void attempt() {
      unawaited(
        checkAutomatically(
          currentVersion: currentVersion,
          platform: platform,
        ).catchError((Object error) {
          _lastResult = UpdateCheckResult(UpdateState.error, '自动更新检查失败：$error');
          _notify();
          return null;
        }),
      );
    }

    if (_disposed) {
      return;
    }
    attempt();
    _autoTimer = Timer.periodic(const Duration(hours: 1), (_) => attempt());
  }

  @override
  void dispose() {
    _disposed = true;
    _autoTimer?.cancel();
    super.dispose();
  }
}
