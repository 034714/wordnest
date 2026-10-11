import 'package:flutter/material.dart';

import '../domain/controller.dart';
import '../domain/models.dart';
import '../platform/desktop_service.dart';
import 'shared_widgets.dart';

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
  });

  final Future<void> Function()? onCalendar, onCheckUpdates, onConfigureUpdates;
  final String updateStatus;
  final bool native;
  final AppController controller;
  final Future<void> Function() onPlatformChanged;
  final Future<void> Function() onTestNotification;
  final DesktopService desktop;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? _autoStart;
  bool _startupBusy = false;

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = DateTime.tryParse(s.examDate)?.toLocal();
    final desktopAvailable = widget.native && widget.desktop.isDesktop;
    return ContentShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PageHeading(title: '偏好设置', subtitle: '调整学习节奏和桌面体验，让词栖更贴近你的日常。'),
          const SizedBox(height: 25),
          _section(
            icon: Icons.tune_rounded,
            title: '通用',
            subtitle: '这些设置会影响新一轮学习和复习队列。',
            children: [
              _SettingRow(
                title: '每轮词数',
                subtitle: '默认词数，也可在开始新一轮前调整。',
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
            ],
          ),
          _section(
            icon: Icons.visibility_outlined,
            title: '学习内容',
            subtitle: '控制学习卡片中呈现的辅助信息。',
            children: [
              LabeledSwitch(
                title: '显示中文释义',
                subtitle: '在学习卡片和选项中显示中文释义。',
                value: s.showChinese,
                onChanged: (value) =>
                    _update((settings) => settings.showChinese = value),
              ),
              LabeledSwitch(
                title: '显示音标',
                subtitle: '显示英式或美式音标，并保留朗读入口。',
                value: s.showPhonetic,
                onChanged: (value) =>
                    _update((settings) => settings.showPhonetic = value),
              ),
              LabeledSwitch(
                title: '显示例句',
                subtitle: '在答案背面展示原词书例句和译文。',
                value: s.showExample,
                onChanged: (value) =>
                    _update((settings) => settings.showExample = value),
              ),
              LabeledSwitch(
                title: '显示词根词源',
                subtitle: '如果词条提供了词根或词源，显示在答案背面。',
                value: s.showRoot,
                onChanged: (value) =>
                    _update((settings) => settings.showRoot = value),
              ),
              LabeledSwitch(
                title: '显示近义词',
                subtitle: '显示词条导入数据中的近义词信息。',
                value: s.showSynonyms,
                onChanged: (value) =>
                    _update((settings) => settings.showSynonyms = value),
              ),
              LabeledSwitch(
                title: '显示我的笔记',
                subtitle: '在学习卡片背面展示你为词条写下的笔记。',
                value: s.showNotes,
                onChanged: (value) =>
                    _update((settings) => settings.showNotes = value),
              ),
              _SettingRow(
                title: '正式题选项数',
                subtitle: '四选一更有挑战，二选一更适合初次学习。',
                trailing: _ChoiceButtons<int>(
                  value: s.optionCount,
                  values: const [2, 3, 4],
                  labels: const ['2', '3', '4'],
                  onChanged: (value) =>
                      _update((settings) => settings.optionCount = value),
                ),
              ),
              LabeledSwitch(
                title: '答对后自动进入下一词',
                subtitle: '仅答对后自动推进；答错时停留查看答案。',
                value: s.autoAdvance,
                onChanged: (value) =>
                    _update((settings) => settings.autoAdvance = value),
              ),
              LabeledSwitch(
                title: '输入题显示答案提示',
                subtitle: '输入题中允许逐步显示首字母提示。',
                value: s.typingReveal,
                onChanged: (value) =>
                    _update((settings) => settings.typingReveal = value),
              ),
              LabeledSwitch(
                title: '键盘与提示音效',
                subtitle: '键盘输入点击声与答对提示音；不影响系统通知。',
                value: s.sound,
                onChanged: (value) =>
                    _update((settings) => settings.sound = value),
              ),
              LabeledSwitch(
                title: '英文朗读',
                subtitle: '在学习页面提供英语发音按钮；是否播放由系统音频状态决定。',
                value: s.tts,
                onChanged: (value) =>
                    _update((settings) => settings.tts = value, platform: true),
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
              _SettingRow(
                title: '答错后重试间隔',
                subtitle: '答错的词在多久后重新进入复习队列。',
                trailing: _ChoiceButtons<int>(
                  value: s.errorMinutes,
                  values: const [5, 10, 20, 30],
                  labels: const ['5 分钟', '10 分钟', '20 分钟', '30 分钟'],
                  onChanged: (value) =>
                      _update((settings) => settings.errorMinutes = value),
                ),
              ),
            ],
          ),
          _section(
            icon: Icons.notifications_none_rounded,
            title: '提醒',
            subtitle: '提醒只根据本地学习进度安排，不会上传词书或学习记录。',
            children: [
              LabeledSwitch(
                title: '开启复习提醒',
                subtitle: s.notifications
                    ? '已开启；系统可能仍会受勿扰模式和系统权限影响。'
                    : '关闭后不会向系统请求复习通知权限。',
                value: s.notifications,
                onChanged: (value) => _toggleNotifications(value),
              ),
              _SettingRow(
                title: '提醒间隔',
                subtitle: '两次系统提醒之间至少间隔的时间。',
                trailing: _ChoiceButtons<int>(
                  value: s.reminderMinutes,
                  values: const [15, 30, 60, 120],
                  labels: const ['15 分', '30 分', '1 小时', '2 小时'],
                  onChanged: (value) =>
                      _update((settings) => settings.reminderMinutes = value),
                ),
              ),
              _SettingRow(
                title: '提醒时间段',
                subtitle: '只在这个时间范围内请求下一条复习提醒。',
                trailing: Wrap(
                  spacing: 7,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _HourDropdown(
                      value: s.startHour,
                      onChanged: (value) =>
                          _update((settings) => settings.startHour = value),
                    ),
                    const Text('至'),
                    _HourDropdown(
                      value: s.endHour,
                      maxEnd: true,
                      onChanged: (value) =>
                          _update((settings) => settings.endHour = value),
                    ),
                  ],
                ),
              ),
              LabeledSwitch(
                title: '提醒中显示中文',
                subtitle: '通知正文显示中文释义；关闭时只显示单词和提醒类型。',
                value: s.reviewNotificationChinese,
                onChanged: (value) => _update(
                  (settings) => settings.reviewNotificationChinese = value,
                ),
              ),
              if (s.notifications)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: widget.native ? widget.onTestNotification : null,
                    icon: const Icon(Icons.notifications_active_outlined),
                    label: const Text('发送一条测试提醒'),
                  ),
                ),
            ],
          ),
          _section(
            icon: Icons.event_outlined,
            title: '日历与更新',
            subtitle: '由你主动导出日历或检查更新，不会自动上传学习内容。',
            children: [
              _SettingRow(
                title: '复习日历',
                subtitle: '导出日历文件后可手动导入日历应用。',
                trailing: OutlinedButton(
                  onPressed: widget.onCalendar,
                  child: const Text('导出复习日历'),
                ),
              ),
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
                      child: const Text('更新设置'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          _section(
            icon: Icons.palette_outlined,
            title: '外观',
            subtitle: '选择适合你环境的颜色和文字大小。',
            children: [
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
            ],
          ),
          if (desktopAvailable)
            _section(
              icon: Icons.desktop_windows_outlined,
              title: '桌面体验',
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
            title: '本地数据与备份',
            subtitle: '词栖使用本地数据库保存词书、笔记、卡片和学习记录。',
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
                  applicationName: '词栖 WordNest',
                  applicationVersion: '0.1.0',
                  applicationLegalese: '本地优先的轻量记词工具',
                ),
                icon: const Icon(Icons.menu_book_outlined),
                label: const Text('查看开源许可'),
              ),
            ],
          ),
          const SizedBox(height: 12),
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

class _HourDropdown extends StatelessWidget {
  const _HourDropdown({
    required this.value,
    required this.onChanged,
    this.maxEnd = false,
  });
  final int value;
  final bool maxEnd;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => DropdownButton<int>(
    value: value,
    items: [
      for (var hour = 0; hour <= (maxEnd ? 24 : 23); hour++)
        DropdownMenuItem(
          value: hour,
          child: Text('${hour.toString().padLeft(2, '0')}:00'),
        ),
    ],
    onChanged: (next) {
      if (next != null) onChanged(next);
    },
  );
}
