import 'package:flutter/material.dart';

import '../domain/controller.dart';
import '../domain/models.dart';
import '../platform/appearance_service.dart';
import '../platform/desktop_service.dart';
import '../platform/update_service.dart';
import 'update_download_panel.dart';
import 'library_page.dart';
import 'shared_widgets.dart';

/// 设置页按功能分区：学习 / 生词本 / 提醒 / 外观 / 桌面 / 数据与关于。
///
/// 生词本与题型方向来自另一处并行落地的数据契约
/// （`AppSettings.notebookAutoAddErrors`、`notebookRemoveAfterCorrect`、
/// `questionDirection`）。这里用 `_readCompatSetting` / `_writeCompatSetting`
/// 做防御式读写：契约缺失时控件仍可渲染，保存时给出提示而不是让整页报错。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    required this.onPlatformChanged,
    required this.onTestNotification,
    required this.desktop,
    this.native = true,
    this.onCalendar,
    this.onCheckUpdates,
    this.onConfigureUpdates,
    this.updateStatus = '尚未检查更新',
    this.updates,
    this.onPickBackground,
    this.onDeleteBackground,
    this.onOpenNotebook,
  });

  final Future<String?> Function()? onPickBackground;
  final Future<void> Function(String asset)? onDeleteBackground;

  /// 保留参数以兼容应用外壳：复习日历导出入口已按需求整段移除，
  /// 不再在本页渲染（保留字段不产生未使用告警）。
  final Future<void> Function()? onCalendar, onCheckUpdates, onConfigureUpdates;

  /// 应用外壳切到「词书 → 生词本」时可注入此回调；未注入时
  /// 「打开生词本」按钮会把词书页作为新路由推入，保证按钮始终可用。
  final Future<void> Function()? onOpenNotebook;
  final String updateStatus;
  final UpdateService? updates;
  final bool native;
  final AppController controller;
  final Future<void> Function() onPlatformChanged;
  final Future<void> Function() onTestNotification;
  final DesktopService desktop;

  /// 提醒分区的可见性规则：Android 上系统提醒不可靠，整块隐藏；
  /// 其余平台（含 native:false 的测试环境）只保留最小实验分区。
  /// 抽成静态方法，便于测试直接校验这条守卫。
  static bool showReminderSection({
    required bool native,
    required bool android,
  }) => !(native && android);

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? _autoStart;
  bool _startupBusy = false;
  bool _backgroundBusy = false;

  static const _accentPresets = <int, String>{
    0xff23775d: '松绿',
    0xff366bb3: '湖蓝',
    0xff8056a6: '鸢紫',
    0xffb55b72: '蔷薇',
    0xffa76c27: '琥珀',
  };

  AppController get c => widget.controller;
  AppSettings get s => c.settings;

  @override
  void initState() {
    super.initState();
    _readAutoStart();
  }

  Future<void> _readAutoStart() async {
    if (!widget.native || !widget.desktop.startupSupported) {
      _autoStart = false;
      return;
    }
    final enabled = await widget.desktop.getAutoStart();
    if (mounted) setState(() => _autoStart = enabled);
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _update(
    void Function(AppSettings) update, {
    bool platform = false,
  }) async {
    final ok = await c.updateSettings(update);
    if (!ok || !mounted) return;
    if (platform && widget.native) await widget.onPlatformChanged();
    if (mounted) setState(() {});
  }

  /// 写入并行契约中的字段；契约缺失时保持原值并提示，不影响其余设置。
  Future<void> _updateCompat(String name, String label, Object value) async {
    final probe = AppSettings.fromJson(s.toJson());
    if (!_writeCompatSetting(probe, name, value)) {
      _message('「$label」在当前版本还不可用，已保持原值。');
      return;
    }
    await _update((settings) => _writeCompatSetting(settings, name, value));
  }

  Future<void> _toggleNotifications(bool enabled) async {
    if (enabled && widget.native) {
      final granted = await widget.desktop.requestNotifications();
      if (!granted) {
        _message(widget.desktop.lastError ?? '系统没有允许通知，请检查系统通知设置。');
        return;
      }
    }
    await _update(
      (settings) => settings.notifications = enabled,
      platform: true,
    );
  }

  Future<void> _pickExamDate() async {
    final initial =
        DateTime.tryParse(s.examDate) ??
        DateTime.now().add(const Duration(days: 30));
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(DateTime.now()) ? DateTime.now() : initial,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      helpText: '选择考试日期',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked == null) return;
    await _update((settings) => settings.examDate = picked.toIso8601String());
  }

  Future<void> _clearExamDate() async =>
      _update((settings) => settings.examDate = '');

  Future<void> _toggleStartup(bool enabled) async {
    if (!widget.native || !widget.desktop.startupSupported) return;
    setState(() => _startupBusy = true);
    await widget.desktop.setAutoStart(enabled);
    await _readAutoStart();
    if (mounted) {
      setState(() => _startupBusy = false);
      if (widget.desktop.lastError != null) _message(widget.desktop.lastError!);
    }
  }

  Future<void> _customAccent() async {
    final input = TextEditingController(
      text: '#${s.accentArgb.toRadixString(16).substring(2).toUpperCase()}',
    );
    final key = GlobalKey<FormState>();
    final accent = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义主题色'),
        content: Form(
          key: key,
          child: TextFormField(
            controller: input,
            autofocus: true,
            maxLength: 7,
            decoration: const InputDecoration(
              labelText: 'HEX 颜色',
              hintText: '#23775D',
              helperText: '输入六位 HEX 颜色，不支持透明色。',
            ),
            validator: (text) => parseAccentHex(text ?? '') == null
                ? '请输入 #RRGGBB 或 RRGGBB'
                : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (key.currentState!.validate()) {
                Navigator.pop(context, parseAccentHex(input.text));
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    input.dispose();
    if (accent != null) {
      await _update((settings) => settings.accentArgb = accent);
    }
  }

  Future<void> _discardBackground(String asset) async {
    try {
      await widget.onDeleteBackground?.call(asset);
    } catch (_) {
      // Failed cleanup must not undo saved settings.
    }
  }

  Future<void> _pickBackground() async {
    if (_backgroundBusy || widget.onPickBackground == null) return;
    setState(() => _backgroundBusy = true);
    String? chosen;
    var saved = false;
    try {
      chosen = await widget.onPickBackground!();
      if (chosen == null) return;
      if (!isValidBackgroundAsset(chosen) || chosen.isEmpty) {
        throw const FormatException('背景图片引用无效');
      }
      if (!mounted) return;
      final previous = s.backgroundAsset;
      saved = await c.updateSettings(
        (settings) => settings.backgroundAsset = chosen!,
      );
      if (saved) {
        if (previous != chosen) await _discardBackground(previous);
      } else {
        _message('背景未保存，原背景已保留。');
      }
    } catch (error) {
      _message('无法设置背景图片：$error');
    } finally {
      if (!saved && chosen != null && chosen != s.backgroundAsset) {
        await _discardBackground(chosen);
      }
      if (mounted) setState(() => _backgroundBusy = false);
    }
  }

  Future<void> _clearBackground() async {
    if (_backgroundBusy) return;
    final previous = s.backgroundAsset;
    final saved = await c.updateSettings(
      (settings) => settings.backgroundAsset = '',
    );
    if (saved) await _discardBackground(previous);
    if (mounted) setState(() {});
  }

  /// 打开生词本：优先使用外壳注入的切页回调；
  /// 未注入时把词书页作为路由推入，按钮在任何装配方式下都可用。
  Future<void> _openNotebook() async {
    final callback = widget.onOpenNotebook;
    if (callback != null) {
      await callback();
      return;
    }
    final navigator = Navigator.of(context);
    await navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('生词本'), leading: const BackButton()),
          body: SafeArea(child: LibraryPage(controller: c)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = DateTime.tryParse(s.examDate)?.toLocal();
    final desktopAvailable = widget.native && widget.desktop.isDesktop;
    // Android 上系统提醒不可靠：整块「提醒」分区隐藏。
    final showReminder = SettingsPage.showReminderSection(
      native: widget.native,
      android: widget.desktop.isAndroid,
    );
    final direction = _readCompatString(s, 'questionDirection', 'en2zh');
    final notebookAutoAdd = _readCompatBool(s, 'notebookAutoAddErrors', true);
    final notebookRemoveAfter = _readCompatInt(
      s,
      'notebookRemoveAfterCorrect',
      0,
    );
    final notebookCount = _readNotebookIds(c).length;

    return ContentShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PageHeading(
            title: '偏好设置',
            subtitle: '按功能分区的设置清单：先看概览，再按需调整每一块。',
          ),
          const SizedBox(height: 25),
          _overview(
            theme,
            direction: direction,
            notebookAutoAdd: notebookAutoAdd,
          ),
          _section(
            icon: Icons.school_outlined,
            title: '学习',
            subtitle: '每一轮的词数、顺序、题目形态和卡片显示内容。',
            children: [
              _SettingRow(
                title: '每轮词数',
                subtitle: '默认词数，也可以自定义 1–50；开始新一轮前还能临时调整。',
                trailing: RoundCountChips(
                  value: s.roundSize,
                  enabled: !c.saving,
                  onChanged: (value) =>
                      _update((settings) => settings.roundSize = value),
                ),
              ),
              _SettingRow(
                title: '学习顺序',
                subtitle: '决定新词加入队列时的顺序。',
                trailing: _ChoiceButtons<String>(
                  value: s.learningOrder,
                  values: learningOrderLabels.keys.toList(),
                  labels: learningOrderLabels.values.toList(),
                  onChanged: (value) =>
                      _update((settings) => settings.learningOrder = value),
                ),
              ),
              _SettingRow(
                title: '考试日期',
                subtitle: date == null
                    ? '设置后可在首页看到距离考试的时间。'
                    : '已设置为 ${date.year} 年 ${date.month} 月 ${date.day} 日。',
                trailing: Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: _pickExamDate,
                      child: Text(date == null ? '选择日期' : '修改日期'),
                    ),
                    if (date != null)
                      IconButton(
                        tooltip: '清除日期',
                        onPressed: _clearExamDate,
                        icon: const Icon(Icons.close_rounded),
                      ),
                  ],
                ),
              ),
              LabeledSwitch(
                title: '答对后自动进入下一题',
                subtitle: '仅答对后自动推进；答错时停留查看答案。',
                value: s.autoAdvance,
                onChanged: (value) =>
                    _update((settings) => settings.autoAdvance = value),
              ),
              _SettingRow(
                title: '选项数',
                subtitle: '四选一更有挑战，二选一更适合初次学习。',
                trailing: _ChoiceButtons<int>(
                  value: s.optionCount,
                  values: const [2, 3, 4],
                  labels: const ['2', '3', '4'],
                  onChanged: (value) =>
                      _update((settings) => settings.optionCount = value),
                ),
              ),
              _SettingRow(
                title: '答错重现间隔',
                subtitle: '答错的词在多久后重新进入复习队列。',
                trailing: _ChoiceButtons<int>(
                  value: s.errorMinutes,
                  values: const [5, 10, 20, 30],
                  labels: const ['5 分钟', '10 分钟', '20 分钟', '30 分钟'],
                  onChanged: (value) =>
                      _update((settings) => settings.errorMinutes = value),
                ),
              ),
              _SettingRow(
                title: '题型方向',
                subtitle: direction == 'zh2en'
                    ? '当前：看中选英，选项是英文单词。'
                    : '当前：看英选中，选项是中文释义。',
                trailing: _ChoiceButtons<String>(
                  value: direction == 'zh2en' ? 'zh2en' : 'en2zh',
                  values: const ['en2zh', 'zh2en'],
                  labels: const ['看英选中', '看中选英'],
                  onChanged: (value) =>
                      _updateCompat('questionDirection', '题型方向', value),
                ),
              ),
              _groupTitle(theme, '卡片显示内容'),
              _ToggleChips(
                enabled: !c.saving,
                options: [
                  _ToggleOption(
                    label: '中文释义',
                    value: s.showChinese,
                    onChanged: (value) =>
                        _update((settings) => settings.showChinese = value),
                  ),
                  _ToggleOption(
                    label: '音标',
                    value: s.showPhonetic,
                    onChanged: (value) =>
                        _update((settings) => settings.showPhonetic = value),
                  ),
                  _ToggleOption(
                    label: '例句',
                    value: s.showExample,
                    onChanged: (value) =>
                        _update((settings) => settings.showExample = value),
                  ),
                  _ToggleOption(
                    label: '词根',
                    value: s.showRoot,
                    onChanged: (value) =>
                        _update((settings) => settings.showRoot = value),
                  ),
                  _ToggleOption(
                    label: '近义词',
                    value: s.showSynonyms,
                    onChanged: (value) =>
                        _update((settings) => settings.showSynonyms = value),
                  ),
                  _ToggleOption(
                    label: '笔记',
                    value: s.showNotes,
                    onChanged: (value) =>
                        _update((settings) => settings.showNotes = value),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 6),
                child: Text(
                  '关闭只影响学习卡片和选项中的展示，不会删除已有数据。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              LabeledSwitch(
                title: '自动朗读',
                subtitle: '切换词条时朗读一次，关闭后仍可手动播放。',
                value: s.autoTts,
                onChanged: (value) => _update(
                  (settings) => settings.autoTts = value,
                  platform: true,
                ),
              ),
              LabeledSwitch(
                title: '英文朗读入口',
                subtitle: '优先词典词音频；首次需联网，缓存后可离线。系统朗读仅作备用。',
                value: s.tts,
                onChanged: (value) =>
                    _update((settings) => settings.tts = value, platform: true),
              ),
              if (widget.native)
                ListenableBuilder(
                  listenable: widget.desktop,
                  builder: (context, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.desktop.isAndroid)
                        _SettingRow(
                          title: '系统朗读引擎',
                          subtitle: '选择仅本次运行生效；安装/启用引擎后可刷新并重试。',
                          trailing: Wrap(
                            spacing: 8,
                            children: [
                              for (final engine in widget.desktop.ttsEngines)
                                ChoiceChip(
                                  label: Text(engine),
                                  selected:
                                      widget.desktop.selectedTtsEngine ==
                                      engine,
                                  onSelected: (_) =>
                                      widget.desktop.retryTts(engine: engine),
                                ),
                              TextButton(
                                onPressed: widget.desktop.refreshTtsEngines,
                                child: const Text('刷新引擎'),
                              ),
                            ],
                          ),
                        ),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: () => widget.desktop.retryTts(),
                            child: const Text('重试系统备用朗读'),
                          ),
                          OutlinedButton(
                            onPressed: s.tts
                                ? () => widget.desktop.speak('hello')
                                : null,
                            child: const Text('试听词音频'),
                          ),
                          TextButton(
                            onPressed: () => widget.desktop.openTtsSettings(),
                            child: const Text('打开系统语音设置'),
                          ),
                          if (widget.desktop.isAndroid)
                            TextButton(
                              onPressed: () => widget.desktop.openTtsSettings(
                                installData: true,
                              ),
                              child: const Text('安装系统语音数据'),
                            ),
                        ],
                      ),
                      Text(
                        widget.desktop.audioError ??
                            '有道公开 HTTPS 词音频优先，不依赖系统 TTS；未缓存的词需联网，服务不可用时尝试系统备用。',
                      ),
                      const Text(
                        '在线仅发送当前单个英语词，不发送释义或个人笔记。成功下载的 MP3 存在应用本地，清除应用数据会移除缓存。',
                      ),
                      const Text(
                        '备用指导：Android 系统文字转语音设置中选择引擎并安装英语语音数据；Windows 设置 → 时间和语言 → 语音 → 管理声音 → 添加英语语音。安装后返回重试。系统引擎是否联网由其自身设置决定。',
                      ),
                    ],
                  ),
                ),
              LabeledSwitch(
                title: '输入提示',
                subtitle: '输入题中允许逐步显示首字母提示。',
                value: s.typingReveal,
                onChanged: (value) =>
                    _update((settings) => settings.typingReveal = value),
              ),
              LabeledSwitch(
                title: '键盘与提示音效',
                subtitle: '键盘输入点击声与答对提示音；不影响系统通知。',
                value: s.sound,
                onChanged: (value) => _update(
                  (settings) => settings.sound = value,
                  platform: true,
                ),
              ),
              _SettingRow(
                title: '音效套装',
                subtitle: 'Android：三套离线声音，一键切换；试听不改变开关。Windows 暂用系统提示音。',
                trailing: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final pack in AppSettings.soundPackLabels.entries)
                      ChoiceChip(
                        label: Text(pack.value),
                        selected: s.soundPack == pack.key,
                        onSelected: c.saving
                            ? null
                            : (_) => _update(
                                (settings) => settings.soundPack = pack.key,
                                platform: true,
                              ),
                      ),
                    for (final sound in const {
                      'key': '试听键盘',
                      'correct': '试听答对',
                      'incorrect': '试听答错',
                    }.entries)
                      TextButton(
                        onPressed: widget.native
                            ? () => widget.desktop.playStudySound(
                                sound.key,
                                pack: s.soundPack,
                                preview: true,
                              )
                            : null,
                        child: Text(sound.value),
                      ),
                  ],
                ),
              ),
            ],
          ),
          _section(
            icon: Icons.collections_bookmark_outlined,
            title: '生词本',
            subtitle: '自动收集答错的词，熟悉之后也可以自动移除。',
            children: [
              LabeledSwitch(
                title: '答错自动加入',
                subtitle: notebookAutoAdd
                    ? '正式题答错后，这个词会自动进入生词本，方便集中复习。'
                    : '关闭后只有你手动加入的词会进入生词本。',
                value: notebookAutoAdd,
                onChanged: (value) =>
                    _updateCompat('notebookAutoAddErrors', '答错自动加入', value),
              ),
              _SettingRow(
                title: '答对几次后自动移除',
                subtitle: notebookRemoveAfter == 0
                    ? '当前不自动移除；词会一直留在生词本里，直到你手动处理。'
                    : '连续答对 $notebookRemoveAfter 次后自动移出生词本。',
                trailing: _ChoiceButtons<int>(
                  value: notebookRemoveAfter.clamp(0, 10),
                  values: const [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
                  labels: [
                    for (var count = 0; count <= 10; count++)
                      count == 0 ? '不自动移除' : '$count 次',
                  ],
                  onChanged: (value) => _updateCompat(
                    'notebookRemoveAfterCorrect',
                    '答对几次后自动移除',
                    value,
                  ),
                ),
              ),
              _SettingRow(
                title: '查看与打开',
                subtitle: notebookCount == 0
                    ? '生词本还是空的；答错正式题后会自动收录（可在上方关闭）。'
                    : '生词本里现在有 $notebookCount 个词。',
                trailing: FilledButton.tonalIcon(
                  onPressed: _openNotebook,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                  label: const Text('打开生词本'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  '生词本只保存在本机数据库，不会上传；需要带走时，请到「我的词书」使用「导出完整备份」。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
          if (showReminder)
            _section(
              icon: Icons.notifications_none_rounded,
              title: '提醒',
              subtitle: '实验性功能：只做最小验证，不保证通知按时送达。',
              children: [
                LabeledSwitch(
                  title: '实验性复习提醒（Windows）',
                  subtitle: s.notifications
                      ? '已请求系统通知权限；横幅仍可能被免打扰或系统设置隐藏。'
                      : '默认关闭。开启只会向系统请求通知权限，不改变本地学习数据。',
                  value: s.notifications,
                  onChanged: (value) => _toggleNotifications(value),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Windows 通知仍在验证中，可能不出现或被系统拦截；Android 上不提供提醒，'
                    '因此这一分区在 Android 会被隐藏。提醒间隔与时间段沿用已保存的规则，'
                    '本页不再提供调整入口。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.55,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: widget.native ? widget.onTestNotification : null,
                    icon: const Icon(Icons.notifications_active_outlined),
                    label: const Text('发送测试通知'),
                  ),
                ),
              ],
            ),
          _section(
            icon: Icons.palette_outlined,
            title: '外观',
            subtitle: '颜色、材质、背景和字号；只影响本机显示。',
            children: [
              _SettingRow(
                title: '主题色',
                subtitle: '选择预设颜色，也可以输入不透明的 HEX 颜色。',
                trailing: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final preset in _accentPresets.entries)
                      ChoiceChip(
                        avatar: CircleAvatar(
                          backgroundColor: Color(preset.key),
                          radius: 8,
                        ),
                        label: Text(preset.value),
                        selected: s.accentArgb == preset.key,
                        onSelected: c.saving
                            ? null
                            : (_) => _update(
                                (settings) => settings.accentArgb = preset.key,
                              ),
                      ),
                    ActionChip(
                      label: Text(
                        _accentPresets.containsKey(s.accentArgb)
                            ? '自定义 HEX'
                            : '#${s.accentArgb.toRadixString(16).substring(2).toUpperCase()}',
                      ),
                      onPressed: c.saving ? null : _customAccent,
                    ),
                  ],
                ),
              ),
              _SettingRow(
                title: '主题',
                subtitle: '系统模式会跟随操作系统的浅色或深色外观。',
                trailing: _ChoiceButtons<String>(
                  value: s.theme,
                  values: const ['light', 'dark', 'system'],
                  labels: const ['浅色', '深色', '跟随系统'],
                  onChanged: (value) =>
                      _update((settings) => settings.theme = value),
                ),
              ),
              _SettingRow(
                title: '文字大小',
                subtitle: '页面会即时使用新的字号比例。',
                trailing: _ChoiceButtons<double>(
                  value: s.fontScale,
                  values: const [.9, 1, 1.15, 1.3],
                  labels: const ['小', '标准', '大', '更大'],
                  onChanged: (value) =>
                      _update((settings) => settings.fontScale = value),
                ),
              ),
              _SettingRow(
                title: '表面材质',
                subtitle: '玻璃效果由应用内模糊合成，不依赖系统 Mica；文字保持不透明。',
                trailing: _ChoiceButtons<String>(
                  value: s.materialMode,
                  values: const ['solid', 'glass'],
                  labels: const ['纯色', '玻璃'],
                  onChanged: (value) =>
                      _update((settings) => settings.materialMode = value),
                ),
              ),
              _SettingRow(
                title: '背景图片',
                subtitle: s.backgroundAsset.isEmpty
                    ? '静态 PNG / JPEG，最大 10 MB、1600 万像素。图片复制到本机，不随备份导出。'
                    : '已使用本地背景图片；原文件移动不影响背景，换机后需重新选择。',
                trailing: Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('pick-background'),
                      onPressed:
                          !_backgroundBusy &&
                              !c.saving &&
                              widget.onPickBackground != null
                          ? _pickBackground
                          : null,
                      icon: const Icon(Icons.image_outlined),
                      label: Text(_backgroundBusy ? '正在处理…' : '选择图片'),
                    ),
                    if (s.backgroundAsset.isNotEmpty)
                      TextButton(
                        onPressed: !_backgroundBusy && !c.saving
                            ? _clearBackground
                            : null,
                        child: const Text('清除图片'),
                      ),
                  ],
                ),
              ),
              _SettingRow(
                title: '背景图片不透明度',
                subtitle: '只调整图片，不影响文字；背景保留护眼遮罩。',
                trailing: _OpacitySlider(
                  key: const ValueKey('background-opacity'),
                  value: s.backgroundOpacity,
                  min: 0,
                  enabled: !c.saving && s.backgroundAsset.isNotEmpty,
                  onPreview: (value) => backgroundOpacityPreview.value = value,
                  onChangeEnd: (value) =>
                      _update((settings) => settings.backgroundOpacity = value),
                ),
              ),
              _SettingRow(
                title: '表面不透明度',
                subtitle: '卡片和导航表面的不透明度；低值会更明显地透出背景。',
                trailing: _OpacitySlider(
                  key: const ValueKey('surface-opacity'),
                  value: s.surfaceOpacity,
                  min: .2,
                  enabled: !c.saving,
                  onPreview: (value) => surfaceOpacityPreview.value = value,
                  onChangeEnd: (value) =>
                      _update((settings) => settings.surfaceOpacity = value),
                ),
              ),
              LabeledSwitch(
                title: '悬浮底栏',
                subtitle: '关闭时宽屏侧栏/窄屏底栏自适应；开启后使用悬浮底栏，输入时自动隐藏。',
                value: s.navigationStyle == 'floating',
                onChanged: (value) => _update(
                  (settings) => settings.navigationStyle = value
                      ? 'floating'
                      : 'adaptive',
                ),
              ),
              if (s.navigationStyle == 'floating')
                _SettingRow(
                  title: '底栏两侧留白',
                  subtitle: '0–48：数值越大，悬浮底栏越窄、离屏幕边缘越远。',
                  trailing: _NumberStepper(
                    value: s.navigationInset,
                    min: 0,
                    max: 48,
                    step: 4,
                    onChanged: (value) =>
                        _update((settings) => settings.navigationInset = value),
                  ),
                ),
              if (s.navigationStyle == 'floating')
                _SettingRow(
                  title: '底栏圆角',
                  subtitle: '0–48：控制悬浮底栏的圆角弧度。',
                  trailing: _NumberStepper(
                    value: s.navigationRadius,
                    min: 0,
                    max: 48,
                    step: 4,
                    onChanged: (value) => _update(
                      (settings) => settings.navigationRadius = value,
                    ),
                  ),
                ),
              _SettingRow(
                title: '文案风格',
                subtitle: '简洁风格保持原有表达；趣味风格只调整少量学习提示，不改变统计和错误说明。',
                trailing: _ChoiceButtons<String>(
                  value: s.copyStyle,
                  values: const ['plain', 'cute'],
                  labels: const ['简洁', '有趣'],
                  onChanged: (value) =>
                      _update((settings) => settings.copyStyle = value),
                ),
              ),
            ],
          ),
          if (desktopAvailable)
            _section(
              icon: Icons.desktop_windows_outlined,
              title: '桌面',
              subtitle: '桌面服务已连接，可以使用快捷键、托盘和小窗。',
              children: [
                _SettingRow(
                  title: '全局快捷键',
                  subtitle: '在其他应用中也可以快速打开一轮学习。',
                  trailing: DropdownButton<String>(
                    isExpanded: true,
                    value: s.globalHotkey,
                    items: const [
                      DropdownMenuItem(
                        value: 'Ctrl+Alt+W',
                        child: Text(
                          'Ctrl + Alt + W',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'Ctrl+Alt+Space',
                        child: Text(
                          'Ctrl + Alt + Space',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(value: 'Disabled', child: Text('不设置')),
                    ],
                    onChanged: desktopAvailable
                        ? (value) {
                            if (value != null) {
                              _update(
                                (settings) => settings.globalHotkey = value,
                                platform: true,
                              );
                            }
                          }
                        : null,
                  ),
                ),
                LabeledSwitch(
                  title: '启用全局快捷键',
                  subtitle: '快捷键注册失败时会在页面顶部显示实际错误。',
                  value: s.hotkeyEnabled,
                  enabled: desktopAvailable,
                  onChanged: (value) => _update(
                    (settings) => settings.hotkeyEnabled = value,
                    platform: true,
                  ),
                ),
                LabeledSwitch(
                  title: '关闭窗口时最小化到托盘',
                  subtitle: '仅 Windows 且托盘初始化成功时可用；关闭后会直接退出窗口。',
                  value: s.closeToTray,
                  enabled: desktopAvailable,
                  onChanged: (value) => _update(
                    (settings) => settings.closeToTray = value,
                    platform: true,
                  ),
                ),
                LabeledSwitch(
                  title: '小窗置顶',
                  subtitle: '开启后，桌面小窗会保持在其他窗口上方。',
                  value: s.widgetTop,
                  enabled: desktopAvailable,
                  onChanged: (value) => _update(
                    (settings) => settings.widgetTop = value,
                    platform: true,
                  ),
                ),
                LabeledSwitch(
                  title: '小窗自动轮播',
                  subtitle: '小窗模式下按间隔自动切换下一个词。',
                  value: s.widgetAuto,
                  enabled: desktopAvailable,
                  onChanged: (value) => _update(
                    (settings) => settings.widgetAuto = value,
                    platform: true,
                  ),
                ),
                _SettingRow(
                  title: '小窗轮播间隔',
                  subtitle: '自动轮播的间隔，范围为 5 到 300 秒。',
                  trailing: _NumberStepper(
                    value: s.widgetSeconds,
                    min: 5,
                    max: 300,
                    step: 5,
                    onChanged: (value) => _update(
                      (settings) => settings.widgetSeconds = value,
                      platform: true,
                    ),
                  ),
                ),
                _SettingRow(
                  title: '登录时启动',
                  subtitle: _autoStart == null
                      ? '正在读取系统状态…'
                      : _autoStart!
                      ? '已向系统注册登录启动。'
                      : '未注册登录启动。',
                  trailing: Switch(
                    value: _autoStart ?? false,
                    onChanged: desktopAvailable && !_startupBusy
                        ? _toggleStartup
                        : null,
                  ),
                ),
                if (widget.desktop.status.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(
                      '桌面状态：${widget.desktop.status}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          _section(
            icon: Icons.shield_outlined,
            title: '数据与关于',
            subtitle: '本地备份说明、开源许可、版本和更新检查。',
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  '没有账号系统，也不会自动同步到云端。你可以在「我的词书」中导出完整备份，换机时手动恢复；CSV 导出适合编辑词条，完整备份会保留学习进度。',
                  style: TextStyle(height: 1.6),
                ),
              ),
              Row(
                children: [
                  Icon(
                    Icons.lock_outline_rounded,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      '数据留在这台设备上，由你决定何时导出或删除。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: '词栖',
                  applicationVersion: '0.3.3',
                  applicationLegalese: '本地优先的轻量记词工具',
                ),
                icon: const Icon(Icons.menu_book_outlined),
                label: const Text('查看开源许可'),
              ),
              const Divider(height: 30),
              _SettingRow(
                title: '应用更新',
                subtitle: widget.updateStatus,
                trailing: Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: widget.onCheckUpdates,
                      child: const Text('检查更新'),
                    ),
                    TextButton(
                      onPressed: widget.onConfigureUpdates,
                      child: const Text('更新来源'),
                    ),
                  ],
                ),
              ),
              if (widget.native && widget.updates != null)
                UpdateDownloadPanel(updates: widget.updates!),
              const SizedBox(height: 10),
              Text('词栖 · 0.3.3', style: theme.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '词栖会在每次修改后保存设置。${c.saving ? '正在保存…' : '当前设置已保存。'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部的紧凑概览：一眼看清当前配置，再去下面的分区里修改。
  Widget _overview(
    ThemeData theme, {
    required String direction,
    required bool notebookAutoAdd,
  }) {
    final chips = <String>[
      '每轮 ${s.roundSize} 词',
      '顺序：${learningOrderLabels[s.learningOrder] ?? s.learningOrder}',
      '方向：${direction == 'zh2en' ? '看中选英' : '看英选中'}',
      '主题：${_themeLabel(s.theme)}',
      '字号：${_fontScaleLabel(s.fontScale)}',
      '材质：${s.materialMode == 'glass' ? '玻璃' : '纯色'}',
      '生词本：${notebookAutoAdd ? '错题自动收录' : '手动收录'}',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: SurfaceCard(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.dashboard_customize_outlined,
                  size: 19,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 9),
                const Text(
                  '当前概览',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final chip in chips)
                  Chip(
                    label: Text(chip),
                    visualDensity: VisualDensity.compact,
                    side: BorderSide.none,
                    backgroundColor: theme.colorScheme.primaryContainer
                        .withValues(alpha: .35),
                  ),
              ],
            ),
            const SizedBox(height: 9),
            Text(
              '下面的分区按功能划分，可直接修改；所有设置都只保存在本机。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _themeLabel(String theme) => switch (theme) {
    'dark' => '深色',
    'system' => '跟随系统',
    _ => '浅色',
  };

  String _fontScaleLabel(double scale) {
    if (scale <= .95) return '小';
    if (scale >= 1.25) return '更大';
    if (scale > 1) return '大';
    return '标准';
  }

  Widget _groupTitle(ThemeData theme, String title) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 8),
    child: Row(
      children: [
        Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Divider(
            height: 1,
            color: theme.dividerColor.withValues(alpha: .5),
          ),
        ),
      ],
    ),
  );

  Widget _section({
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Widget> children,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: SurfaceCard(
        padding: const EdgeInsets.fromLTRB(22, 21, 22, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionTitle(title: title, subtitle: subtitle, icon: icon),
            const Divider(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// 读取并行契约字段；字段不存在时返回 null，页面照常渲染。
Object? _readCompatSetting(AppSettings settings, String name) {
  final dynamic target = settings;
  try {
    final Object? value = switch (name) {
      'notebookAutoAddErrors' => target.notebookAutoAddErrors,
      'notebookRemoveAfterCorrect' => target.notebookRemoveAfterCorrect,
      'questionDirection' => target.questionDirection,
      _ => null,
    };
    return value;
  } catch (_) {
    return null;
  }
}

/// 写入并行契约字段；字段不存在或类型不符时返回 false，由调用方提示。
bool _writeCompatSetting(AppSettings settings, String name, Object value) {
  final dynamic target = settings;
  try {
    switch (name) {
      case 'notebookAutoAddErrors':
        target.notebookAutoAddErrors = value;
        break;
      case 'notebookRemoveAfterCorrect':
        target.notebookRemoveAfterCorrect = value;
        break;
      case 'questionDirection':
        target.questionDirection = value;
        break;
      default:
        return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

bool _readCompatBool(AppSettings settings, String name, bool fallback) {
  final value = _readCompatSetting(settings, name);
  return value is bool ? value : fallback;
}

int _readCompatInt(AppSettings settings, String name, int fallback) {
  final value = _readCompatSetting(settings, name);
  return value is int ? value : fallback;
}

String _readCompatString(AppSettings settings, String name, String fallback) {
  final value = _readCompatSetting(settings, name);
  return value is String && value.isNotEmpty ? value : fallback;
}

/// 防御式读取 `AppController.notebookIds` / `notebookEntries`；
/// 契约缺失时返回空列表，页面显示空态而不是崩溃。
List<String> _readNotebookIds(AppController controller) {
  final value = _readControllerMember(controller, 'notebookIds');
  if (value is Iterable) return value.map((id) => '$id').toList();
  final entries = _readControllerMember(controller, 'notebookEntries');
  if (entries is Iterable) {
    final ids = <String>[
      for (final item in entries)
        if (item is WordEntry) item.id else if (item is String) item,
    ];
    if (ids.isNotEmpty || entries.isEmpty) return ids;
  }
  return const [];
}

/// 读取控制器成员：getter 或零参方法都可以；不存在时返回 null。
Object? _readControllerMember(AppController controller, String name) {
  final dynamic target = controller;
  try {
    final Object? value = switch (name) {
      'notebookIds' => target.notebookIds,
      'notebookEntries' => target.notebookEntries,
      _ => null,
    };
    if (value is Function) return Function.apply(value, const []);
    return value;
  } catch (_) {
    return null;
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.title,
    required this.subtitle,
    required this.trailing,
  });
  final String title;
  final String subtitle;
  final Widget trailing;
  @override
  Widget build(BuildContext context) {
    final description = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.4),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [description, const SizedBox(height: 9), trailing],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: description),
                    const SizedBox(width: 18),
                    Flexible(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: trailing,
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _ToggleOption {
  const _ToggleOption({
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
}

/// 紧凑的开关组：一个标签一个开关，适合「显示内容」这类并列选项。
class _ToggleChips extends StatelessWidget {
  const _ToggleChips({required this.options, required this.enabled});
  final List<_ToggleOption> options;
  final bool enabled;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 7,
    runSpacing: 7,
    children: [
      for (final option in options)
        FilterChip(
          label: Text(option.label),
          selected: option.value,
          onSelected: enabled ? option.onChanged : null,
        ),
    ],
  );
}

class _ChoiceButtons<T> extends StatelessWidget {
  const _ChoiceButtons({
    required this.value,
    required this.values,
    required this.labels,
    required this.onChanged,
  });
  final T value;
  final List<T> values;
  final List<String> labels;
  final ValueChanged<T> onChanged;
  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 5,
      children: [
        for (var i = 0; i < values.length; i++)
          ChoiceChip(
            label: Text(labels[i]),
            selected: value == values[i],
            onSelected: (_) => onChanged(values[i]),
          ),
      ],
    );
  }
}

class _OpacitySlider extends StatefulWidget {
  const _OpacitySlider({
    super.key,
    required this.value,
    required this.min,
    required this.enabled,
    required this.onChangeEnd,
    this.onPreview,
  });

  final double value, min;
  final bool enabled;
  final Future<void> Function(double) onChangeEnd;
  final ValueChanged<double?>? onPreview;

  @override
  State<_OpacitySlider> createState() => _OpacitySliderState();
}

class _OpacitySliderState extends State<_OpacitySlider> {
  double? _draft;
  bool _dragging = false;
  bool _committing = false;

  @override
  void didUpdateWidget(covariant _OpacitySlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging && !_committing) _draft = null;
  }

  Future<void> _commit(double next) async {
    if (_committing) return;
    final preview = widget.onPreview;
    final messenger = ScaffoldMessenger.of(context);
    final controller = context
        .findAncestorWidgetOfExactType<SettingsPage>()!
        .controller;
    final background = widget.key == const ValueKey('background-opacity');
    setState(() {
      _dragging = false;
      _committing = true;
      _draft = next;
    });
    preview?.call(next);
    var saved = false;
    try {
      await widget.onChangeEnd(next);
      // The parent callback returns void even on a rejected save. Wait for
      // its stored value to reach this widget before retiring the preview.
      await WidgetsBinding.instance.endOfFrame;
      final stored = background
          ? controller.settings.backgroundOpacity
          : controller.settings.surfaceOpacity;
      saved = controller.error == null && (stored - next).abs() < .000001;
    } catch (_) {
      saved = false;
    } finally {
      preview?.call(null);
      if (mounted) {
        setState(() {
          _committing = false;
          _draft = null;
        });
      }
      if (!saved && messenger.mounted) {
        messenger.showSnackBar(const SnackBar(content: Text('不透明度未保存，已恢复原值。')));
      }
    }
  }

  @override
  void dispose() {
    // A pending commit owns the preview until it finishes, even after leaving
    // settings. An interrupted gesture has nothing to persist.
    if (!_committing && _draft != null) {
      final preview = widget.onPreview;
      WidgetsBinding.instance.addPostFrameCallback((_) => preview?.call(null));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = _draft ?? widget.value;
    return SizedBox(
      width: 280,
      child: Row(
        children: [
          Expanded(
            child: Slider(
              value: value,
              min: widget.min,
              max: 1,
              divisions: ((1 - widget.min) * 100).round(),
              label: '${(value * 100).round()}%',
              onChangeStart: widget.enabled && !_committing
                  ? (_) => _dragging = true
                  : null,
              onChanged: (widget.enabled || _dragging) && !_committing
                  ? (next) {
                      widget.onPreview?.call(next);
                      setState(() => _draft = next);
                    }
                  : null,
              onChangeEnd: (widget.enabled || _dragging) && !_committing
                  ? _commit
                  : null,
            ),
          ),
          SizedBox(width: 40, child: Text('${(value * 100).round()}%')),
        ],
      ),
    );
  }
}

class _NumberStepper extends StatelessWidget {
  const _NumberStepper({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = 1,
  });
  final int value;
  final int min;
  final int max;
  final int step;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '减少',
          onPressed: value > min
              ? () => onChanged((value - step).clamp(min, max))
              : null,
          icon: const Icon(Icons.remove_rounded, size: 18),
        ),
        Text('$value', style: const TextStyle(fontWeight: FontWeight.w700)),
        IconButton(
          tooltip: '增加',
          onPressed: value < max
              ? () => onChanged((value + step).clamp(min, max))
              : null,
          icon: const Icon(Icons.add_rounded, size: 18),
        ),
      ],
    ),
  );
}
