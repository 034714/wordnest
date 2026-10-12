import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../domain/models.dart';
import 'native_platform.dart';
import 'safe_http.dart';
import 'word_audio_service.dart';

/// Data-only reminder input for one Android scheduled notification.
class AndroidReminderWord {
  const AndroidReminderWord({
    required this.word,
    required this.meaning,
    required this.payload,
    required this.isNew,
    required this.scheduledAt,
  });

  final String word;
  final String meaning;
  final String payload;
  final bool isNew;
  final DateTime scheduledAt;
}

/// Native platform services used by the desktop and Android shells.
///
/// The service is deliberately optional: unsupported platforms expose their
/// capability state and retain the last error in [status] instead of throwing
/// from ordinary no-op calls. Notification permission is never requested by
/// [initialize]; call [requestNotifications] after the user opts in.
class DesktopService extends ChangeNotifier with TrayListener, WindowListener {
  DesktopService({
    FlutterLocalNotificationsPlugin? notifications,
    this.onAudioError,
    WordAudioService? wordAudio,
  }) : _wordAudio = wordAudio ?? WordAudioService(),
       _notifications = notifications ?? FlutterLocalNotificationsPlugin() {
    _nativeTtsChannel.setMethodCallHandler((call) async {
      if (call.method == 'error') {
        _ttsInitialization = null;
        _audioError('朗读失败：${call.arguments}');
      }
    });
  }

  final ValueChanged<String>? onAudioError;
  Future<void>? _ttsInitialization;
  String? _reportedAudioError;
  static const _soundChannel = MethodChannel('io.wordnest/sound');

  void _audioError(String message) {
    audioError = message;
    _setError(message);
    // Avoid flooding the user on every key when audio is unavailable.
    if (_reportedAudioError != message) {
      _reportedAudioError = message;
      onAudioError?.call(message);
    }
  }

  String? audioError;
  List<String> ttsEngines = [];
  String? selectedTtsEngine;
  bool _nativeTts = false;
  static const _nativeTtsChannel = MethodChannel('io.wordnest/tts');

  Future<void> playStudySound(
    String sound, {
    String? pack,
    bool preview = false,
  }) async {
    if (!preview && _settings?.sound == false) return;
    if (!const ['key', 'correct', 'incorrect'].contains(sound)) return;
    try {
      if (isAndroid) {
        await _soundChannel.invokeMethod<void>('play', {
          'sound': sound,
          'pack': pack ?? _settings?.soundPack ?? 'classic',
        });
      } else if (isWindows) {
        // Windows' system alert is audible; Android uses bundled PCM instead.
        await SystemSound.play(SystemSoundType.alert);
      }
    } catch (_) {
      _audioError('键盘音效无法播放，请检查媒体音量或重新打开应用。');
    }
  }

  Future<void> _ensureTts() async {
    try {
      await (_ttsInitialization ??= _initializeTts()).timeout(
        const Duration(seconds: 12),
      );
    } catch (_) {
      _ttsInitialization = null;
      rethrow;
    }
  }

  Future<void> refreshTtsEngines() async {
    if (!isAndroid) return;
    try {
      final values = await _tts.getEngines.timeout(const Duration(seconds: 12));
      ttsEngines = (values as List).whereType<String>().toSet().toList();
      notifyListeners();
    } catch (error) {
      _audioError('无法读取系统朗读引擎：$error');
    }
  }

  Future<bool> retryTts({String? engine}) async {
    try {
      await stopSpeech();
      if (engine != null) {
        if (!ttsEngines.contains(engine)) throw StateError('该引擎已不可用，请刷新');
        // flutter_tts 4.2.5 setEngine deliberately returns void, not a code.
        await _tts.setEngine(engine).timeout(const Duration(seconds: 12));
        selectedTtsEngine = engine;
      }
      _nativeTts = false;
      _ttsInitialization = null;
      await _ensureTts();
      audioError = null;
      _reportedAudioError = null;
      notifyListeners();
      return true;
    } catch (error) {
      _audioError('朗读初始化失败：$error。可切换引擎或安装英语语音数据后重试。');
      return false;
    }
  }

  Future<void> _initializeTts() async {
    _tts.setErrorHandler((message) {
      _ttsInitialization = null;
      _audioError('朗读失败：$message。请检查系统文字转语音引擎和英语语音数据。');
    });
    try {
      bool available;
      if (isWindows) {
        // Windows plugin has getLanguages, but no isLanguageAvailable API.
        final languages = await _tts.getLanguages;
        available =
            languages is List &&
            languages.any(
              (value) =>
                  value.toString().toLowerCase().replaceAll('_', '-') ==
                  'en-us',
            );
      } else {
        available = await _tts.isLanguageAvailable('en-US') == true;
      }
      if (!available) throw StateError('系统没有可用的英语语音，请安装英语离线语音数据');
      // Plugin normalizes Android language success to 1 (NOT native LANG_*).
      // Other backends can complete setters with null; don't treat that as failure.
      final language = await _tts.setLanguage('en-US');
      if (language == 0 ||
          language == false ||
          (language is num && language < 0)) {
        throw StateError('无法设置英语朗读语言');
      }
      await _tts.setSpeechRate(0.45);
      try {
        await _tts.setVolume(1.0);
      } on MissingPluginException {
        // Optional setter: some desktop backends use system media volume only.
      } on PlatformException {
        // A volume setter failure does not mean there is no speech engine.
      }
      _nativeTts = false;
    } catch (error) {
      if (!isAndroid) rethrow;
      // Local Android fallback only: no text/notes sent to a web service.
      try {
        await _nativeTtsChannel
            .invokeMethod<void>('initialize', {'engine': selectedTtsEngine})
            .timeout(const Duration(seconds: 10));
        _nativeTts = true;
      } catch (nativeError) {
        throw StateError('$error；原生朗读也不可用：$nativeError');
      }
    }
  }

  final FlutterLocalNotificationsPlugin _notifications;
  final FlutterTts _tts = FlutterTts();
  final HotKeyManager _hotkeys = HotKeyManager.instance;

  Future<void> Function(String payload, String action)? _onNotification;
  Future<void> Function()? _onBeforeExit;
  Future<void>? _exitFuture;
  VoidCallback? _onQuick;
  VoidCallback? _onWidget;
  VoidCallback? _onOpen;
  HotKey? _registeredHotKey;
  String? _registeredHotKeySpec;
  AppSettings? _settings;
  Rect? _normalBounds;
  bool _notificationsInitialized = false;
  bool _windowInitialized = false;
  bool _trayInitialized = false;
  bool _paused = false;
  bool _pausedByUser = false;
  bool _closing = false;
  String _status = 'Not initialized';
  String? _lastError;
  bool _compact = false;
  String? _notificationError;
  Future<void> _reminderOperation = Future<void>.value();
  static const _calendarChannel = MethodChannel('io.wordnest/calendar');

  String? get notificationError => _notificationError;
  bool get calendarSupported => isAndroid || isWindows;

  // Serialize cancellation and scheduling so obsolete schedules cannot survive
  // a later cancellation/configuration call.
  Future<T> _serializeReminders<T>(Future<T> Function() operation) {
    final next = _reminderOperation.then((_) => operation());
    _reminderOperation = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return next;
  }

  void _setNotificationError(String value) {
    _notificationError = value;
    _setError(value);
  }

  void _clearNotificationError() {
    _notificationError = null;
    notifyListeners();
  }

  final WordAudioService _wordAudio;
  int _speechGeneration = 0;

  /// Opens a public http(s) URL in the system browser. Returns true when the
  /// OS accepted the handoff; never reads the page. Invalid/private URLs are
  /// rejected before any process or intent is created.
  Future<bool> openUrl(String url) async {
    try {
      final uri = validatePublicHttpUrl(url);
      if (isAndroid) {
        await _calendarChannel.invokeMethod<void>('openUrl', {
          'url': uri.toString(),
        });
      } else if (isWindows) {
        final system = Platform.environment['SystemRoot'] ?? r'C:\Windows';
        final result = await Process.run('$system\\System32\\rundll32.exe', [
          'url.dll,FileProtocolHandler',
          uri.toString(),
        ], runInShell: false);
        if (result.exitCode != 0) throw StateError('系统没有可用的浏览器关联');
      } else {
        throw StateError('当前平台不支持打开外部链接');
      }
      return true;
    } catch (error) {
      _setError('无法打开链接：$error');
      return false;
    }
  }

  Future<void> openTtsSettings({bool installData = false}) async {
    try {
      if (isAndroid) {
        await _nativeTtsChannel.invokeMethod<void>(
          installData ? 'installVoiceData' : 'openTtsSettings',
          {'engine': selectedTtsEngine},
        );
      } else if (isWindows) {
        final system = Platform.environment['SystemRoot'] ?? r'C:\Windows';
        final result = await Process.run('$system\\System32\\rundll32.exe', [
          'url.dll,FileProtocolHandler',
          'ms-settings:speech',
        ], runInShell: false);
        if (result.exitCode != 0) throw StateError('系统设置启动失败');
      }
    } catch (error) {
      _audioError('无法打开语音设置：$error。请手动进入系统设置的文字转语音/语音，安装英语语音；不装也能用，词音频由有道提供。');
    }
  }

  Future<void> stopSpeech() async {
    _speechGeneration++;
    try {
      await _wordAudio.stop();
    } catch (_) {
      /* TTS stop must remain independent of audio stop. */
    }
    try {
      await _tts.stop().timeout(const Duration(seconds: 2));
    } catch (error) {
      // A broken system engine must never block dictionary audio.
    }
    try {
      if (isAndroid) {
        await _nativeTtsChannel
            .invokeMethod<void>('stop')
            .timeout(const Duration(seconds: 2));
      }
    } catch (error) {
      _setError('停止朗读失败：$error');
    }
  }

  /// Independent diagnostic: never depends on a word, pause or study settings.
  /// Delivery success means the plugin accepted it, not that the OS displayed it.
  Future<bool> sendDiagnosticNotification() async {
    if (!_notificationsInitialized) {
      _setNotificationError('测试通知不可用：通知服务尚未初始化。');
      return false;
    }
    try {
      if (isAndroid) {
        final plugin = _notifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        if (await plugin?.areNotificationsEnabled() != true) {
          _setNotificationError('测试通知不可用：系统通知权限未开启。');
          return false;
        }
      }
      await _notifications.show(
        id: 99999,
        title: '词栖 · 测试通知',
        body: '这是固定测试通知，不会改变学习记录。',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'wordnest_diagnostic',
            '词栖通知诊断',
            channelDescription: '用户主动发送的固定测试通知',
            icon: 'ic_stat_wordnest',
            importance: Importance.defaultImportance,
          ),
          windows: WindowsNotificationDetails(),
        ),
      );
      _clearNotificationError();
      _setStatus('测试通知已交给系统；若未显示，请检查系统通知设置。');
      return true;
    } catch (error) {
      _setNotificationError('测试通知发送失败：$error');
      return false;
    }
  }

  /// Opens a user-confirmed calendar editor/importer; never reads calendars.
  /// A true result means OS handoff only, NOT that the user saved the event.
  Future<bool> addCalendarEvent({
    required String title,
    required DateTime start,
    required DateTime end,
    String description = '',
  }) async {
    if (!calendarSupported || title.trim().isEmpty || !end.isAfter(start)) {
      _setError('日历不可用，或事件标题/时间无效。');
      return false;
    }
    try {
      if (isAndroid) {
        await _calendarChannel.invokeMethod<void>('insertEvent', {
          'title': title.trim(),
          'description': description,
          'startMillis': start.millisecondsSinceEpoch,
          'endMillis': end.millisecondsSinceEpoch,
        });
      } else {
        String escape(String text) => text
            .replaceAll('\\', '\\\\')
            .replaceAll('\r\n', '\n')
            .replaceAll('\r', '\n')
            .replaceAll('\n', r'\n')
            .replaceAll(';', r'\;')
            .replaceAll(',', r'\,');
        String date(DateTime value) {
          final utc = value.toUtc();
          String pad(int n, int width) => n.toString().padLeft(width, '0');
          return '${pad(utc.year, 4)}${pad(utc.month, 2)}${pad(utc.day, 2)}T${pad(utc.hour, 2)}${pad(utc.minute, 2)}${pad(utc.second, 2)}Z';
        }

        // Fold by UTF-8 octets (RFC 5545), not UTF-16 code units.
        String fold(String line) {
          final output = StringBuffer();
          var bytes = 0;
          for (final rune in line.runes) {
            final char = String.fromCharCode(rune);
            final count = utf8.encode(char).length;
            if (bytes + count > 75) {
              output.write('\r\n ');
              bytes = 1;
            }
            output.write(char);
            bytes += count;
          }
          return output.toString();
        }

        final directory = await Directory.systemTemp.createTemp(
          'wordnest-calendar-',
        );
        final file = File(
          '${directory.path}${Platform.pathSeparator}reminder.ics',
        );
        await file.writeAsString(
          [
            'BEGIN:VCALENDAR',
            'VERSION:2.0',
            'PRODID:-//WordNest//Calendar//EN',
            'BEGIN:VEVENT',
            'UID:${DateTime.now().microsecondsSinceEpoch}@wordnest',
            'DTSTAMP:${date(DateTime.now())}',
            'DTSTART:${date(start)}',
            'DTEND:${date(end)}',
            'SUMMARY:${escape(title.trim())}',
            'DESCRIPTION:${escape(description)}',
            'END:VEVENT',
            'END:VCALENDAR',
            '',
          ].map(fold).join('\r\n'),
          flush: true,
        );
        // Absolute system executable and a separate argument: no cmd shell or
        // user-controlled process command. Leave the temp file for OS import.
        final windows = Platform.environment['SystemRoot'] ?? r'C:\Windows';
        final result = await Process.run('$windows\\System32\\rundll32.exe', [
          'url.dll,FileProtocolHandler',
          file.path,
        ], runInShell: false);
        if (result.exitCode != 0) throw StateError('系统没有可用的日历文件关联');
      }
      _setStatus('已打开系统日历，请在日历中确认保存。');
      return true;
    } catch (error) {
      _setError('打开日历失败：$error');
      return false;
    }
  }

  TargetPlatform get _target =>
      kIsWeb ? TargetPlatform.fuchsia : defaultTargetPlatform;
  bool get isWindows => !kIsWeb && _target == TargetPlatform.windows;
  bool get isDesktop =>
      !kIsWeb &&
      (_target == TargetPlatform.windows ||
          _target == TargetPlatform.linux ||
          _target == TargetPlatform.macOS);
  bool get isAndroid => !kIsWeb && _target == TargetPlatform.android;
  bool get notificationsReady => _notificationsInitialized;
  bool get trayReady => _trayInitialized;
  String get status => _status;
  String? get lastError => _lastError;
  bool get compact => _compact;
  bool get paused => _paused;
  bool get startupSupported => isDesktop;

  Future<void> initialize({
    required Future<void> Function(String payload, String action)
    onNotification,
    required VoidCallback onQuick,
    required VoidCallback onWidget,
    required VoidCallback onOpen,
    Future<void> Function()? onBeforeExit,
  }) async {
    _onBeforeExit = onBeforeExit;
    _onNotification = onNotification;
    _onQuick = onQuick;
    _onWidget = onWidget;
    _onOpen = onOpen;
    _setStatus('Initializing native platform services');

    if (isDesktop) {
      await _initializeWindow();
      if (isWindows) {
        await _initializeTray();
      }
      await _initializeHotkey();
      await _initializeStartup();
    }

    if (isAndroid || isWindows) {
      await _initializeNotifications();
    }

    if (_lastError == null) {
      _setStatus('Native platform services ready');
    }
  }

  Future<void> configure(AppSettings settings) async {
    _settings = settings;
    _setPaused(!settings.notifications || _pausedByUser, notify: false);

    if (isDesktop) {
      await _configureWindow(settings);
      if (isWindows) {
        await _configureTray(settings);
      }
      await _configureHotkey(settings);
      await _configureStartup(settings);
    }

    if (isAndroid || isDesktop) {
      await _configureTts(settings);
      if (!settings.notifications) {
        await cancelNotifications();
      }
    }
  }

  Future<bool> requestNotifications() async {
    if (!_notificationsInitialized) {
      _setNotificationError(
        'Notifications are unavailable until initialize completes',
      );
      return false;
    }
    try {
      if (isAndroid) {
        final plugin = _notifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        final granted = await plugin?.requestNotificationsPermission();
        final ready = granted ?? false;
        if (ready) {
          _clearNotificationError();
          _setStatus('Android notifications enabled');
        } else {
          _setNotificationError('Android notifications permission denied');
        }
        return ready;
      }
      if (_target == TargetPlatform.iOS || _target == TargetPlatform.macOS) {
        final plugin = _notifications
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
        final granted = await plugin?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
        final ready = granted ?? false;
        _setStatus(
          ready
              ? 'Apple notifications enabled'
              : 'Apple notifications permission denied',
        );
        return ready;
      }
      _setStatus('Notifications enabled');
      return true;
    } catch (error) {
      _setNotificationError('Notification permission failed: $error');
      return false;
    }
  }

  Future<bool> notifyWord({
    required int id,
    required String word,
    required String meaning,
    required bool isNew,
    required String payload,
    required AppSettings settings,
  }) async {
    if (_paused || !settings.notifications) return false;
    if (!_notificationsInitialized) {
      _setNotificationError('Cannot notify: notifications are not initialized');
      return false;
    }

    final title = isNew ? '新词 · $word' : '复习 · $word';
    final showMeaning = isNew || settings.reviewNotificationChinese;
    final body = showMeaning && meaning.trim().isNotEmpty
        ? '$word  ·  $meaning'
        : word;
    try {
      final details = _notificationDetails(
        settings: settings,
        isNew: isNew,
        payload: payload,
      );
      await _notifications.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: details,
        payload: _platformNotificationPayload(payload),
      );
      _clearNotificationError();
      return true;
    } catch (error) {
      _setNotificationError('Notification failed: $error');
      return false;
    }
  }

  Future<bool> scheduleAndroidQueue({
    required List<AndroidReminderWord> words,
    required AppSettings settings,
  }) => _serializeReminders(() async {
    if (!isAndroid || !_notificationsInitialized) {
      _setNotificationError('后台提醒不可用：通知服务未就绪。');
      return false;
    }
    try {
      await _notifications.cancelAllPendingNotifications();
      if (!settings.notifications || words.isEmpty) return true;
      final plugin = _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (await plugin?.areNotificationsEnabled() != true) {
        _setNotificationError('系统未允许通知，未安排后台提醒。');
        return false;
      }
      tz_data.initializeTimeZones();
      final zone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(zone.identifier));
      final now = DateTime.now();
      var sent = 0;
      for (final word in words) {
        if (!word.scheduledAt.isAfter(now) ||
            word.scheduledAt.isAfter(now.add(const Duration(hours: 24)))) {
          continue;
        }
        final showMeaning = word.isNew || settings.reviewNotificationChinese;
        await _notifications.zonedSchedule(
          id: 100000 + sent,
          scheduledDate: tz.TZDateTime.from(word.scheduledAt, tz.local),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          title: '${word.isNew ? '新词' : '复习'} · ${word.word}',
          body: showMeaning ? '${word.word} · ${word.meaning}' : word.word,
          notificationDetails: _notificationDetails(
            settings: settings,
            isNew: word.isNew,
            payload: word.payload,
          ),
          payload: word.payload,
        );
        sent++;
      }
      _clearNotificationError();
      _setStatus('已安排 $sent 条非精确后台提醒（未来24小时内）');
      return true;
    } catch (error) {
      try {
        await _notifications.cancelAllPendingNotifications();
      } catch (cleanupError) {
        _setNotificationError('后台提醒安排失败：$error；清理失败：$cleanupError');
        return false;
      }
      _setNotificationError('后台提醒安排失败：$error');
      return false;
    }
  });

  Future<void> cancelPendingReminders() => _serializeReminders(() async {
    if (isAndroid && _notificationsInitialized) {
      try {
        await _notifications.cancelAllPendingNotifications();
        _clearNotificationError();
      } catch (error) {
        _setNotificationError('取消后台提醒失败：$error');
      }
    }
  });

  Future<void> setCompact(bool enabled, {bool top = true}) async {
    if (_compact == enabled && (!enabled || _normalBounds != null)) return;
    if (!isDesktop) {
      _compact = enabled;
      notifyListeners();
      _setStatus('Compact window is supported on desktop only');
      return;
    }
    try {
      if (enabled) {
        _normalBounds ??= await windowManager.getBounds();
        await windowManager.setMinimumSize(const Size(440, 520));
        await windowManager.setSize(const Size(480, 600));
        await windowManager.setAlwaysOnTop(top);
      } else {
        await windowManager.setMinimumSize(const Size(720, 520));
        final bounds = _normalBounds;
        if (bounds != null) {
          await windowManager.setBounds(bounds);
        }
        await windowManager.setAlwaysOnTop(false);
        _normalBounds = null;
      }
      _compact = enabled;
      notifyListeners();
    } catch (error) {
      _setError('Compact window failed: $error');
    }
  }

  bool _wordAudioExplained = false;

  Future<void> speak(String word) async {
    if (word.trim().isEmpty || _settings?.tts == false) return;
    await stopSpeech();
    final token = _speechGeneration;
    // Dictionary recordings are independent of installed TTS engines. Try
    // cache/network first rather than waiting for a broken system engine.
    Object? dictionaryError;
    if (isAndroid || isWindows) {
      try {
        WordAudioService.normalizeWord(word);
        if (!_wordAudioExplained) {
          _wordAudioExplained = true;
          onAudioError?.call(
            '词音频首次播放需要联网：仅将当前英语词发送到有道公开词音频服务，不上传笔记；成功缓存后可离线重播。',
          );
        }
        await _wordAudio.play(word);
        if (token != _speechGeneration) return;
        audioError = null;
        _reportedAudioError = null;
        notifyListeners();
        return;
      } catch (error) {
        dictionaryError = error;
      }
    }
    if (token != _speechGeneration) return;
    try {
      await _ensureTts();
      if (token != _speechGeneration) return;
      if (_nativeTts) {
        await _nativeTtsChannel.invokeMethod<void>('speak', {
          'text': word.trim(),
        });
      } else {
        await _tts.stop();
        if (await _tts.speak(word.trim()) != 1) {
          if (!isAndroid) throw StateError('语音引擎拒绝朗读请求');
          try {
            await _nativeTtsChannel.invokeMethod<void>('initialize', {
              'engine': selectedTtsEngine,
            });
            _nativeTts = true;
            await _nativeTtsChannel.invokeMethod<void>('speak', {
              'text': word.trim(),
            });
          } catch (error) {
            throw StateError('语音引擎拒绝朗读请求；原生备用失败：$error');
          }
        }
      }
      audioError = null;
      _reportedAudioError = null;
      notifyListeners();
    } catch (error) {
      if (token != _speechGeneration) return;
      _ttsInitialization = null;
      _audioError(
        '词音频不可用：$dictionaryError；系统备用朗读失败：$error。未缓存的词需要联网，请检查网络和媒体音量；也可从朗读设置安装系统英语语音。',
      );
    }
  }

  Future<void> setAutoStart(bool enabled) async {
    if (!startupSupported) {
      _setError('Login startup is unsupported on this platform');
      return;
    }
    try {
      await _setupStartupIfNeeded();
      final ok = enabled
          ? await launchAtStartup.enable()
          : await launchAtStartup.disable();
      if (!ok) {
        _setError(
          'Login startup could not be ${enabled ? 'enabled' : 'disabled'}',
        );
      } else {
        _setStatus(
          enabled ? 'Login startup enabled' : 'Login startup disabled',
        );
      }
    } catch (error) {
      _setError('Login startup failed: $error');
    }
  }

  Future<bool> getAutoStart() async {
    if (!startupSupported) return false;
    try {
      await _setupStartupIfNeeded();
      return await launchAtStartup.isEnabled();
    } catch (error) {
      _setError('Reading login startup failed: $error');
      return false;
    }
  }

  Future<void> bringToFront() async {
    if (!isDesktop || !_windowInitialized) return;
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (error) {
      _setError('Bring to front failed: $error');
    }
  }

  Future<void> exitApp() => _exitFuture ??= _exit();

  Future<void> _exit() async {
    _closing = true;
    try {
      await _onBeforeExit?.call();
      if (isDesktop && _windowInitialized) {
        await cancelNotifications();
        await windowManager.destroy();
      } else if (isAndroid) {
        await SystemNavigator.pop();
      }
    } catch (error) {
      _closing = false;
      _exitFuture = null;
      _setError('退出失败，窗口保留：$error');
    }
  }

  Future<void> cancelNotifications() => _serializeReminders(() async {
    if (!_notificationsInitialized) return;
    try {
      await _notifications.cancelAll();
      _clearNotificationError();
      _setStatus('Notifications cancelled');
    } catch (error) {
      _setNotificationError('Cancelling notifications failed: $error');
    }
  });

  Future<void> disposeService() async {
    await stopSpeech();
    try {
      await _unregisterHotkey();
      if (isWindows && _trayInitialized) {
        await trayManager.destroy();
        trayManager.removeListener(this);
      }
      if (isDesktop) {
        windowManager.removeListener(this);
      }
      _notifications
          .resolvePlatformSpecificImplementation<
            FlutterLocalNotificationsWindows
          >()
          ?.dispose();
    } catch (error) {
      _setError('Disposing platform services failed: $error');
    }
  }

  void setPaused(bool value) {
    _pausedByUser = value;
    _setPaused(value || _settings?.notifications == false);
    if (isWindows && _trayInitialized) unawaited(_setTrayMenu());
  }

  Future<void> _initializeWindow() async {
    try {
      await windowManager.ensureInitialized();
      windowManager.addListener(this);
      await windowManager.setMinimumSize(const Size(720, 520));
      await windowManager.setPreventClose(true);
      _windowInitialized = true;
    } catch (error) {
      _setError('Window initialization failed: $error');
    }
  }

  Future<void> _configureWindow(AppSettings settings) async {
    try {
      await windowManager.setPreventClose(true);
      if (!settings.closeToTray && _compact) {
        await setCompact(false);
      }
    } catch (error) {
      _setError('Window configuration failed: $error');
    }
  }

  Future<void> _initializeTray() async {
    try {
      trayManager.addListener(this);
      await trayManager.setIcon('assets/tray.ico');
      await trayManager.setToolTip('词栖 WordNest');
      await _setTrayMenu();
      _trayInitialized = true;
      notifyListeners();
    } catch (error) {
      _trayInitialized = false;
      _setError('Windows tray unavailable; close-to-tray disabled: $error');
    }
  }

  Future<void> _configureTray(AppSettings settings) async {
    if (!_trayInitialized) return;
    try {
      await _setTrayMenu();
      await windowManager.setPreventClose(true);
    } catch (error) {
      _setError('Tray configuration failed: $error');
    }
  }

  Future<void> _setTrayMenu() async {
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'open', label: '打开词栖'),
          MenuItem(key: 'quick', label: '快速复习'),
          MenuItem(key: 'widget', label: '显示小组件'),
          MenuItem.checkbox(key: 'pause', label: '暂停通知', checked: _paused),
          MenuItem.separator(),
          MenuItem(key: 'exit', label: '退出'),
        ],
      ),
    );
  }

  Future<void> _initializeHotkey() async {
    // Registration is deferred until configure, because AppSettings owns the
    // user-selected shortcut and the safe default can be disabled by config.
  }

  Future<void> _configureHotkey(AppSettings settings) async {
    final spec = settings.hotkeyEnabled ? settings.globalHotkey : 'Disabled';
    if (_registeredHotKeySpec == spec) return;
    await _unregisterHotkey();
    if (!settings.hotkeyEnabled ||
        settings.globalHotkey.toLowerCase() == 'disabled') {
      _registeredHotKeySpec = spec;
      return;
    }
    if (!isDesktop) return;

    final hotKey = _parseHotKey(settings.globalHotkey);

    if (hotKey == null) {
      _setError('Unsupported global hotkey: ${settings.globalHotkey}');
      return;
    }
    try {
      await _hotkeys.register(hotKey, keyDownHandler: (_) => _onQuick?.call());
      _registeredHotKey = hotKey;
      _registeredHotKeySpec = spec;
      _setStatus('Global hotkey registered: ${settings.globalHotkey}');
    } catch (error) {
      _setError('Global hotkey registration failed: $error');
    }
  }

  Future<void> _unregisterHotkey() async {
    final hotKey = _registeredHotKey;
    if (hotKey == null) return;
    try {
      await _hotkeys.unregister(hotKey);
    } catch (error) {
      _setError('Global hotkey cleanup failed: $error');
    } finally {
      _registeredHotKey = null;
      _registeredHotKeySpec = null;
    }
  }

  HotKey? _parseHotKey(String value) {
    final normalized = value.replaceAll(' ', '').toLowerCase();
    final modifiers = <HotKeyModifier>[];
    if (normalized.contains('ctrl')) modifiers.add(HotKeyModifier.control);
    if (normalized.contains('alt')) modifiers.add(HotKeyModifier.alt);
    if (normalized.contains('shift')) modifiers.add(HotKeyModifier.shift);
    if (modifiers.isEmpty) return null;

    if (normalized.endsWith('w')) {
      return HotKey(
        key: LogicalKeyboardKey.keyW,
        modifiers: modifiers,
        scope: HotKeyScope.system,
      );
    }
    if (normalized.endsWith('space')) {
      return HotKey(
        key: LogicalKeyboardKey.space,
        modifiers: modifiers,
        scope: HotKeyScope.system,
      );
    }
    return null;
  }

  Future<void> _initializeStartup() async {
    if (!startupSupported) return;
    try {
      await _setupStartupIfNeeded();
    } catch (error) {
      _setError('Login startup setup failed: $error');
    }
  }

  Future<void> _configureStartup(AppSettings settings) async {
    if (!startupSupported) return;
    // Startup is opt-in. This only changes the registration when the caller
    // explicitly invokes setAutoStart; configure never enables it implicitly.
    if (!settings.notifications) return;
  }

  Future<void> _setupStartupIfNeeded() async {
    launchAtStartup.setup(
      appName: 'WordNest',
      appPath: nativeExecutablePath,
      args: const <String>[],
    );
  }

  Future<void> _initializeNotifications() async {
    if (_notificationsInitialized) return;
    try {
      final iconPath = notificationIconPath();
      final settings = InitializationSettings(
        android: const AndroidInitializationSettings('ic_stat_wordnest'),
        windows: WindowsInitializationSettings(
          appName: '词栖 WordNest',
          appUserModelId: 'io.wordnest.wordnest',
          guid: 'c67a3f0b-42e8-4a3f-a5d6-5d30c9cbf3a0',
          iconPath: iconPath.isEmpty ? null : iconPath,
        ),
      );
      final initialized = await _notifications.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: _handleNotificationResponse,
      );
      _notificationsInitialized = initialized ?? true;
      if (!_notificationsInitialized) {
        _setNotificationError(
          'Notification plugin initialization returned false',
        );
        return;
      }

      final launch = await _notifications.getNotificationAppLaunchDetails();
      final response = launch?.notificationResponse;
      if (launch?.didNotificationLaunchApp == true && response != null) {
        await _dispatchNotification(response.payload, response.actionId);
      }
    } catch (error) {
      _setNotificationError('Notification initialization failed: $error');
    }
  }

  Future<void> _configureTts(AppSettings settings) async {
    // Online/cache playback must not be delayed by unavailable system TTS.
    // The engine is initialized only for explicit retry or dictionary failure.
    if (!settings.tts) await stopSpeech();
  }

  String _platformNotificationPayload(String payload) {
    if (!isWindows) return payload;
    return jsonEncode(<String, String>{'payload': payload, 'action': 'open'});
  }

  NotificationDetails _notificationDetails({
    required AppSettings settings,
    required bool isNew,
    required String payload,
  }) {
    final actionNames = isNew
        ? const <String>['remember', 'pass']
        : const <String>['known', 'verify'];
    final actionLabels = <String, String>{
      'remember': '记住了',
      'pass': '稍后再看',
      'known': '已掌握',
      'verify': '验证',
    };
    final androidActions = actionNames
        .map(
          (action) => AndroidNotificationAction(
            action,
            actionLabels[action]!,
            showsUserInterface: true,
          ),
        )
        .toList(growable: false);
    final windowsActions = actionNames
        .map(
          (action) => WindowsAction(
            content: actionLabels[action]!,
            arguments: jsonEncode(<String, String>{
              'payload': payload,
              'action': action,
            }),
          ),
        )
        .toList(growable: false);
    return NotificationDetails(
      android: AndroidNotificationDetails(
        'wordnest_recall',
        '词栖复习提醒',
        icon: 'ic_stat_wordnest',
        channelDescription: '用于词汇复习提醒',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        playSound: true,
        enableVibration: true,
        actions: androidActions,
      ),
      windows: WindowsNotificationDetails(actions: windowsActions),
    );
  }

  Future<void> _handleNotificationResponse(NotificationResponse response) {
    return _dispatchNotification(response.payload, response.actionId);
  }

  Future<void> _dispatchNotification(String? payload, String? action) async {
    if (payload == null || payload.isEmpty) return;
    var opaquePayload = payload;
    var callbackAction = action ?? 'open';
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map) {
        final wrappedPayload = decoded['payload'];
        final wrappedAction = decoded['action'];
        if (wrappedPayload is String) opaquePayload = wrappedPayload;
        if (wrappedAction is String) callbackAction = wrappedAction;
      }
    } catch (_) {
      // The parent owns the payload format; raw payloads remain valid.
    }
    if (callbackAction == 'review_known') callbackAction = 'known';
    await _onNotification?.call(opaquePayload, callbackAction);
  }

  void _setPaused(bool value, {bool notify = true}) {
    _paused = value;
    if (notify) notifyListeners();
  }

  void _setStatus(String value) {
    _status = value;
    _lastError = null;
    notifyListeners();
  }

  void _setError(String value) {
    _status = value;
    _lastError = value;
    notifyListeners();
  }

  @override
  void onTrayIconMouseDown() {
    _onOpen?.call();
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        _onOpen?.call();
      case 'quick':
        _onQuick?.call();
      case 'widget':
        _onWidget?.call();
      case 'pause':
        setPaused(!_pausedByUser);
      case 'exit':
        unawaited(exitApp());
    }
  }

  @override
  void onWindowClose() {
    unawaited(_handleWindowClose());
  }

  Future<void> _handleWindowClose() async {
    if (_closing) return;
    if (!_trayInitialized || _settings?.closeToTray != true) {
      await exitApp();
      return;
    }
    await windowManager.hide();
  }

  @override
  void dispose() {
    unawaited(disposeService());
    super.dispose();
  }
}
