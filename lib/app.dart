import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'domain/controller.dart';
import 'domain/reminder_plan.dart';
import 'features/home_page.dart';
import 'features/study_page.dart';
import 'features/library_page.dart';
import 'features/stats_page.dart';
import 'features/settings_page.dart';
import 'platform/desktop_service.dart';
import 'platform/update_service.dart';

class WordNestApp extends StatefulWidget {
  const WordNestApp({super.key, required this.controller, this.native = true});
  final AppController controller;
  final bool native;
  @override
  State<WordNestApp> createState() => _WordNestAppState();
}

class _WordNestAppState extends State<WordNestApp> with WidgetsBindingObserver {
  final desktop = DesktopService();
  final updates = UpdateService();
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  int page = 0;
  String mode = 'quick';
  int sessionGeneration = 0;
  bool compact = false, paused = false, _notifying = false;
  Timer? reminder, carousel;
  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.native) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _initializeNative());
    }
  }

  Future<void> _initializeNative() async {
    try {
      await desktop.initialize(
        onBeforeExit: c.flush,
        onNotification: _notificationAction,
        onQuick: () {
          unawaited(_openStudy('quick'));
        },
        onWidget: () {
          unawaited(_toggleCompact());
        },
        onOpen: () {
          unawaited(_showMain());
        },
      );
      await desktop.configure(c.settings);
      await updates.initialize();
      updates.startAutoChecks(
        currentVersion: '0.2.0',
        platform: desktop.isAndroid ? 'android' : 'windows',
      );
      if (!mounted) return;
      if (desktop.isAndroid) {
        await desktop.cancelPendingReminders();
      } else {
        reminder = Timer.periodic(
          const Duration(seconds: 30),
          (_) => _notifyNext(),
        );
      }
    } catch (e) {
      _message('桌面增强暂不可用，基础学习不受影响：$e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      c.refreshClock();
      if (widget.native && desktop.isAndroid) {
        unawaited(desktop.cancelPendingReminders());
      }
    } else if (state == AppLifecycleState.paused &&
        widget.native &&
        desktop.isAndroid) {
      unawaited(_scheduleAndroid());
    }
  }

  Future<void> _scheduleAndroid() async {
    if (_notifying || !desktop.notificationsReady) return;
    _notifying = true;
    try {
      await c.flush();
      final slots = reminderSlots(DateTime.now(), c.settings, count: 96);
      final ids = c.queue('quick', limit: slots.length);
      final words = <AndroidReminderWord>[];
      for (var i = 0; i < slots.length && i < ids.length; i++) {
        final entry = c.state.entries[ids[i]]!;
        final payload = await c.recordNotification(
          entry.id,
          scheduledAt: slots[i],
        );
        if (payload == null) break;
        words.add(
          AndroidReminderWord(
            word: entry.word,
            meaning: entry.coreMeaning,
            payload: payload,
            isNew: !c.card(entry.id).seen,
            scheduledAt: slots[i],
          ),
        );
      }
      await desktop.scheduleAndroidQueue(words: words, settings: c.settings);
    } catch (error) {
      _message('后台提醒未安排，学习进度已保留：$error');
    } finally {
      _notifying = false;
    }
  }

  void _message(String text) =>
      messengerKey.currentState?.showSnackBar(SnackBar(content: Text(text)));
  Future<void> _showMain() async {
    if (compact) {
      await desktop.setCompact(false);
    }
    if (!mounted) return;
    setState(() {
      compact = false;
    });
    if (widget.native) await desktop.bringToFront();
  }

  Future<void> _openStudy(
    String nextMode, {
    List<String>? ids,
    bool fresh = false,
    int? limit,
  }) async {
    final ok = await c.begin(nextMode, resume: !fresh, ids: ids, limit: limit);
    if (!ok || !mounted) return;
    setState(() {
      page = 1;
      mode = nextMode;
      sessionGeneration++;
    });
    if (widget.native) await desktop.bringToFront();
  }

  Future<void> _toggleCompact() async {
    if (compact) {
      await _showMain();
      carousel?.cancel();
      return;
    }
    if (!c.resumable || c.sessionMode != 'quick') await c.begin('quick');
    if (!mounted) return;
    await desktop.setCompact(true, top: c.settings.widgetTop);
    setState(() {
      compact = true;
      page = 1;
      mode = 'quick';
      sessionGeneration++;
    });
    _configureCarousel();
  }

  void _configureCarousel() {
    carousel?.cancel();
    if (compact && c.settings.widgetAuto) {
      carousel = Timer.periodic(Duration(seconds: c.settings.widgetSeconds), (
        _,
      ) async {
        if (paused || c.saving || !c.resumable || mode != 'quick') return;
        await c.advance();
      });
    }
  }

  Future<void> _configure() async {
    await desktop.configure(c.settings);
    _configureCarousel();
    if (!c.settings.notifications) await desktop.cancelNotifications();
  }

  Future<void> _notifyNext({bool test = false}) async {
    if (_notifying ||
        (!test && (!c.mayNotify || desktop.paused)) ||
        !desktop.notificationsReady) {
      return;
    }
    final ids = c.queue('quick', limit: 1);
    if (ids.isEmpty) {
      if (test) _message('当前没有新词或到期任务，先导入词书或调整每日目标。');
      return;
    }
    _notifying = true;
    try {
      final e = c.state.entries[ids.first]!;
      final payload = await c.recordNotification(e.id);
      if (payload == null) return;
      final sent = await desktop.notifyWord(
        id: e.id.hashCode & 0x7fffffff,
        word: e.word,
        meaning: e.coreMeaning,
        isNew: !c.card(e.id).seen,
        payload: payload,
        settings: c.settings,
      );
      if (test) {
        _message(
          sent
              ? '已向系统请求发送；免打扰或通知设置可能隐藏横幅。'
              : '通知未发送：${desktop.lastError ?? desktop.status}',
        );
      }
    } catch (e) {
      _message('通知发送失败：$e');
    } finally {
      _notifying = false;
    }
  }

  Future<void> _checkUpdates() async {
    final result = await updates.check(
      currentVersion: '0.2.0',
      platform: desktop.isAndroid ? 'android' : 'windows',
    );
    if (mounted) _message(result.message);
  }

  Future<void> _calendar() async {
    final start = DateTime.now().add(const Duration(hours: 1));
    final ok = await desktop.addCalendarEvent(
      title: '词栖 · 复习单词',
      start: start,
      end: start.add(const Duration(minutes: 15)),
      description: '打开词栖，完成一小轮复习。',
    );
    if (mounted) {
      _message(ok ? '已交给日历应用，请确认时间并保存。' : desktop.lastError ?? '无法打开日历应用。');
    }
  }

  Future<void> _configureUpdates() async {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    final platform = desktop.isAndroid ? 'android' : 'windows';
    final input = TextEditingController(
      text: updates.usesDefaultSource ? '' : updates.sourceUrl,
    );
    var automatic = updates.autoCheck;
    var useDefault = updates.usesDefaultSource;
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('更新来源'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '默认使用词栖 GitHub 仓库的版本清单；也可以关闭检查或填写自己的可信来源。不会自动下载或执行安装包。',
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('使用默认 GitHub 版本清单'),
                  subtitle: Text(
                    UpdateService.defaultSourceUrlFor(platform) ?? '当前平台无默认来源',
                  ),
                  value: useDefault,
                  onChanged: (value) =>
                      setDialogState(() => useDefault = value),
                ),
                TextField(
                  controller: input,
                  enabled: !useDefault,
                  decoration: const InputDecoration(
                    labelText: '自定义版本清单 URL（留空表示关闭检查）',
                    helperText: '只接受公共 HTTPS 地址；留空保存后不会发起任何请求。',
                  ),
                ),
                SwitchListTile(
                  title: const Text('启动时自动检查'),
                  subtitle: const Text('每天最多尝试一次，只检查版本，不自动安装。'),
                  value: automatic,
                  onChanged: (value) => setDialogState(() => automatic = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (save == true) {
      try {
        if (useDefault) {
          await updates.useDefaultSource();
        } else {
          await updates.setSourceUrl(input.text.trim());
        }
        await updates.setAutoCheck(automatic);
        if (mounted) _message('更新来源已保存。自动检查每天最多尝试一次，安装仍需主动操作。');
      } catch (error) {
        if (mounted) _message('来源未保存：$error');
      }
    }
    input.dispose();
  }

  Future<void> _testNotification() async {
    final sent = await desktop.sendDiagnosticNotification();
    if (mounted) {
      _message(
        sent
            ? '已向系统请求测试通知；是否显示由系统设置决定。'
            : '测试通知失败：${desktop.notificationError ?? desktop.status}',
      );
    }
  }

  Future<void> _notificationAction(String payload, String action) async {
    if (!mounted) return;
    final request = c.validateNotification(payload);
    if (request == null) {
      _message('这条提醒已处理或过期，已保留最新进度。');
      return;
    }
    if (action == 'verify') {
      final event = c.state.entries[request.entryId];
      if (event == null) return;
      final handled = await c.review(
        event.id,
        kind: 'notification_verified_request',
        action: 'verify',
        idempotencyKey: 'handled-${request.id}',
        advanceSession: false,
      );
      if (handled) await _openStudy('formal', ids: [event.id]);
      return;
    }
    if (['remember', 'pass', 'known'].contains(action)) {
      await c.review(
        request.entryId,
        kind: 'self',
        familiar: action != 'pass',
        action: action,
        idempotencyKey: 'handled-${request.id}',
        advanceSession: false,
      );
    } else {
      await _showMain();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    reminder?.cancel();
    carousel?.cancel();
    updates.dispose();
    if (widget.native) unawaited(desktop.disposeService());
    super.dispose();
  }

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff23775d),
      brightness: brightness,
      surface: dark ? const Color(0xff171e1b) : Colors.white,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark
          ? const Color(0xff111813)
          : const Color(0xfff6f7f3),
      fontFamily: 'Microsoft YaHei',
      textTheme: ThemeData(brightness: brightness).textTheme.apply(
        fontFamily: 'Microsoft YaHei',
        bodyColor: dark ? const Color(0xffe5ede6) : const Color(0xff23332a),
        displayColor: dark ? const Color(0xffe5ede6) : const Color(0xff23332a),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 19),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: dark ? const Color(0xff2c3930) : const Color(0xffe6ebe3),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        isDense: true,
        fillColor: dark ? const Color(0xff26342b) : const Color(0xfff5f7f3),
        contentPadding: const EdgeInsets.all(16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer.withValues(alpha: .6),
        selectedIconTheme: IconThemeData(color: scheme.primary),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([c, desktop, updates]),
    builder: (context, _) => MaterialApp(
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      title: '词栖 WordNest',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: switch (c.settings.theme) {
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        _ => ThemeMode.light,
      },
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(c.settings.fontScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) {
          final body = switch (page) {
            0 => HomePage(
              controller: c,
              onStart: (m) => _openStudy(m),
              onStartRound: (m, {required resume, limit}) =>
                  _openStudy(m, fresh: !resume, limit: limit),
              onLibrary: () => setState(() => page = 2),
              onWidget: _toggleCompact,
              desktop: desktop,
            ),
            1 => StudyPage(
              key: ValueKey('$sessionGeneration-$mode'),
              controller: c,
              mode: mode,
              compact: compact,
              paused: paused,
              onPause: () => setState(() => paused = !paused),
              onBack: () async {
                if (compact) await _showMain();
                if (mounted) setState(() => page = 0);
              },
              onRestart: () => _openStudy(mode, fresh: true),
              onSpeak: desktop.speak,
              onStopSpeech: desktop.stopSpeech,
              onStartRound: (m, {required resume, limit}) =>
                  _openStudy(m, fresh: !resume, limit: limit),
              onToggleCompact: _toggleCompact,
            ),
            2 => LibraryPage(controller: c, onSpeak: desktop.speak),
            3 => StatsPage(controller: c),
            _ => SettingsPage(
              native: widget.native,
              controller: c,
              desktop: desktop,
              onPlatformChanged: _configure,
              onTestNotification: _testNotification,
              onCalendar: _calendar,
              onCheckUpdates: _checkUpdates,
              onConfigureUpdates: _configureUpdates,
              updateStatus:
                  updates.lastResult?.message ??
                  (updates.sourceDisabled
                      ? '更新检查已关闭。'
                      : '使用默认 GitHub 版本清单，可随时检查更新。'),
            ),
          };
          if (!c.ready) {
            return Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(c.error ?? '正在打开词栖…'),
                ),
              ),
            );
          }
          if (compact) return Scaffold(body: SafeArea(child: body));
          return PopScope<Object?>(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              unawaited(_handleBack());
            },
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide =
                    constraints.maxWidth >= 850 && constraints.maxHeight >= 700;
                return Scaffold(
                  bottomNavigationBar: wide
                      ? null
                      : NavigationBar(
                          selectedIndex: page,
                          onDestinationSelected: _selectPage,
                          destinations: const [
                            NavigationDestination(
                              icon: Icon(Icons.space_dashboard_outlined),
                              label: '今日',
                            ),
                            NavigationDestination(
                              icon: Icon(Icons.style_outlined),
                              label: '学习',
                            ),
                            NavigationDestination(
                              icon: Icon(Icons.auto_stories_outlined),
                              label: '词书',
                            ),
                            NavigationDestination(
                              icon: Icon(Icons.bar_chart_rounded),
                              label: '记录',
                            ),
                            NavigationDestination(
                              icon: Icon(Icons.tune_rounded),
                              label: '设置',
                            ),
                          ],
                        ),
                  body: SafeArea(
                    child: Row(
                      children: [
                        if (wide) _sidebar(context),
                        Expanded(
                          child: Column(
                            children: [
                              if (c.error != null)
                                MaterialBanner(
                                  content: Text(c.error!),
                                  actions: [
                                    TextButton(
                                      onPressed: c.clearError,
                                      child: const Text('知道了'),
                                    ),
                                  ],
                                ),
                              Expanded(
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 160),
                                  child: KeyedSubtree(
                                    key: ValueKey('$page-$sessionGeneration'),
                                    child: body,
                                  ),
                                ),
                              ),
                              if (c.saving)
                                const LinearProgressIndicator(minHeight: 2),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    ),
  );

  DateTime? _lastBackAt;

  Future<void> _handleBack() async {
    if (compact) {
      await _showMain();
      return;
    }
    if (page != 0) {
      setState(() => page = 0);
      return;
    }
    final now = DateTime.now();
    final recent =
        _lastBackAt != null &&
        now.difference(_lastBackAt!) < const Duration(seconds: 2);
    if (recent) {
      if (widget.native) {
        await desktop.exitApp();
      } else {
        await SystemNavigator.pop();
      }
      return;
    }
    _lastBackAt = now;
    _message('再按一次返回键退出词栖。');
  }

  void _selectPage(int value) {
    if (value == 1 && !c.resumable) {
      unawaited(_openStudy('quick'));
      return;
    }
    if (value == 1) mode = c.sessionMode;
    setState(() => page = value);
  }

  Widget _sidebar(BuildContext context) => Container(
    width: 224,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border(
        right: BorderSide(
          color: Theme.of(context).dividerColor.withValues(alpha: .10),
        ),
      ),
    ),
    padding: const EdgeInsets.fromLTRB(18, 30, 18, 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.spa_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 11),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '词栖',
                    style: TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 3,
                    ),
                  ),
                  Text(
                    'WORDNEST',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 2,
                      color: Color(0xff7d8b81),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 42),
        for (final (i, label, icon) in [
          (0, '今日', Icons.space_dashboard_outlined),
          (1, '专注学习', Icons.style_outlined),
          (2, '我的词书', Icons.auto_stories_outlined),
          (3, '学习记录', Icons.bar_chart_rounded),
          (4, '偏好设置', Icons.tune_rounded),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: Material(
              color: page == i
                  ? Theme.of(context).colorScheme.primaryContainer
                        .withValues(alpha: .5)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(13),
              child: InkWell(
                borderRadius: BorderRadius.circular(13),
                onTap: () => _selectPage(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 15,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        icon,
                        size: 21,
                        color: page == i
                            ? Theme.of(context).colorScheme.primary
                            : const Color(0xff7d8b81),
                      ),
                      const SizedBox(width: 13),
                      Text(
                        label,
                        style: TextStyle(
                          fontWeight: page == i
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        const Spacer(),
        if (desktop.isDesktop)
          OutlinedButton.icon(
            onPressed: _toggleCompact,
            icon: const Icon(Icons.picture_in_picture_alt_rounded, size: 18),
            label: const Text('桌面小窗'),
          ),
        const SizedBox(height: 20),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.offline_pin_outlined,
                    size: 15,
                    color: Color(0xff7d8b81),
                  ),
                  SizedBox(width: 7),
                  Text(
                    '数据只在本地',
                    style: TextStyle(fontSize: 12, color: Color(0xff7d8b81)),
                  ),
                ],
              ),
              SizedBox(height: 6),
              Text(
                '一点空闲，一点进步。',
                style: TextStyle(fontSize: 11, color: Color(0xff7d8b81)),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
