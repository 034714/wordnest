import 'package:flutter/material.dart';

import '../domain/controller.dart';
import '../platform/desktop_service.dart';
import 'shared_widgets.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.controller,
    required this.onStart,
    required this.onLibrary,
    required this.onWidget,
    required this.desktop,
    this.onStartRound,
  });
  final AppController controller;
  final Future<void> Function(String) onStart;
  final VoidCallback onLibrary;
  final Future<void> Function() onWidget;
  final DesktopService desktop;
  final StartRoundCallback? onStartRound;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String selectedMode = 'quick';
  int? count;

  bool _resumeFor(AppController c, String mode) => c.resumableInMode(mode);
  AppController get controller => widget.controller;
  DesktopService get desktop => widget.desktop;
  VoidCallback get onLibrary => widget.onLibrary;
  Future<void> Function() get onWidget => widget.onWidget;
  Future<void> onStart(String mode, {bool resume = false}) async {
    if (widget.onStartRound != null) {
      await widget.onStartRound!(
        mode,
        resume: resume,
        limit: resume ? null : count ?? controller.settings.roundSize,
      );
    } else {
      await controller.begin(
        mode,
        resume: resume,
        limit: resume ? null : count ?? controller.settings.roundSize,
      );
      await widget.onStart(mode);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final copy = AppCopy(c.settings.copyStyle == 'cute');
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final date = DateTime.now();
    return SingleChildScrollView(
      padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 20 : 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1060),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${date.month} 月 ${date.day} 日 · ${['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'][date.weekday - 1]}',
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          copy.hero,
                          style: const TextStyle(
                            fontSize: 27,
                            fontWeight: FontWeight.w700,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (MediaQuery.sizeOf(context).width > 600)
                    Chip(
                      avatar: Icon(
                        Icons.wifi_off_rounded,
                        size: 15,
                        color: theme.colorScheme.primary,
                      ),
                      label: const Text(
                        '离线也能学',
                        style: TextStyle(fontSize: 12),
                      ),
                      backgroundColor: theme.colorScheme.surface,
                      side: BorderSide(
                        color: theme.dividerColor.withValues(alpha: .1),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 28),
              Container(
                width: double.infinity,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  color: dark
                      ? const Color(0xff233e2e)
                      : const Color(0xffe7efdd),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      right: -30,
                      bottom: -72,
                      child: Container(
                        width: 260,
                        height: 260,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: theme.colorScheme.primary.withValues(
                            alpha: .06,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 45,
                      top: 22,
                      child: Transform.rotate(
                        angle: -.22,
                        child: Icon(
                          Icons.spa_rounded,
                          size: 125,
                          color: theme.colorScheme.primary.withValues(
                            alpha: .10,
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(30),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            c.book == null
                                ? '从一本词书开始'
                                : c.resumable
                                ? '你的上次进度，留在这里'
                                : '碎片时间，也能慢慢记住',
                            style: TextStyle(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            c.book == null
                                ? '带上你的词书，\n开始轻松记词。'
                                : '一小轮，${count ?? c.settings.roundSize} 个词。\n刚好适合现在。',
                            style: const TextStyle(
                              fontSize: 32,
                              height: 1.45,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            c.book == null
                                ? '支持 JSON / TXT / CSV，保留原书顺序。\n也可以用自编的 24 个演示词，先试一试。'
                                : '新词先认识，复习再回忆。随时停下，进度会自动保留。',
                            style: TextStyle(
                              height: 1.8,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 24),
                          if (c.book != null) ...[
                            Wrap(
                              spacing: 8,
                              children: [
                                for (final item in const {
                                  'quick': '轻量记词',
                                  'formal': '回忆验证',
                                  'typing': '键盘强化',
                                }.entries)
                                  ChoiceChip(
                                    label: Text(item.value),
                                    selected: selectedMode == item.key,
                                    onSelected: c.saving
                                        ? null
                                        : (_) => setState(
                                            () => selectedMode = item.key,
                                          ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            RoundCountChips(
                              value: count ?? c.settings.roundSize,
                              enabled: !c.saving,
                              onChanged: (value) =>
                                  setState(() => count = value),
                            ),
                            const SizedBox(height: 18),
                          ],
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              FilledButton.icon(
                                onPressed: c.saving
                                    ? null
                                    : c.book == null
                                    ? onLibrary
                                    : () => onStart(selectedMode, resume: true),
                                icon: Icon(
                                  c.book == null
                                      ? Icons.download_rounded
                                      : Icons.play_arrow_rounded,
                                  size: 22,
                                ),
                                label: Text(
                                  c.book == null
                                      ? '导入我的词书'
                                      : _resumeFor(c, selectedMode)
                                      ? copy.resume
                                      : copy.start,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              LayoutBuilder(
                builder: (context, constraints) {
                  final cols = constraints.maxWidth > 650 ? 4 : 2;
                  final items = [
                    (
                      '到期复习',
                      '${c.overdue}',
                      '今天优先处理',
                      Icons.history_rounded,
                      const Color(0xffb4773d),
                    ),
                    (
                      '今日正式答题',
                      '${c.formalToday}',
                      c.formalToday == 0
                          ? '未答题'
                          : '正确率 ${(c.correctToday / c.formalToday * 100).round()}%',
                      Icons.task_alt_rounded,
                      const Color(0xff39856c),
                    ),
                    (
                      '轻量过词',
                      '${c.seenToday}',
                      '浏览 / 自评，单独记录',
                      Icons.style_outlined,
                      const Color(0xff6587a6),
                    ),
                    (
                      '学习足迹',
                      '${c.daysActive} 天',
                      '每一步都算数',
                      Icons.eco_outlined,
                      const Color(0xff99805f),
                    ),
                  ];
                  return Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    children: [
                      for (final (label, value, sub, icon, color) in items)
                        SizedBox(
                          width:
                              (constraints.maxWidth - 14 * (cols - 1)) / cols,
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(21),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(icon, color: color, size: 19),
                                      const SizedBox(width: 8),
                                      Flexible(
                                        child: Text(
                                          label,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 18),
                                  Text(
                                    value,
                                    style: const TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    sub,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 30),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '你的学习节奏',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  TextButton(onPressed: onLibrary, child: const Text('管理词书 →')),
                ],
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer
                                  .withValues(alpha: .5),
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: Icon(
                              Icons.auto_stories_rounded,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  c.book?.title ?? '还没有正在学习的词书',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 7),
                                Text(
                                  c.book == null
                                      ? '导入后，词栖会为你安排下一小轮。'
                                      : '${c.words.length} 个词 · ${c.book!.units.length} 个单元 · ${learningOrderLabels[c.settings.learningOrder] ?? '按词书'}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          minHeight: 7,
                          backgroundColor: theme.colorScheme.primary.withValues(
                            alpha: .08,
                          ),
                          value: c.words.isEmpty
                              ? 0
                              : 1 - c.remaining / c.words.length,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 24,
                        runSpacing: 8,
                        children: [
                          Text(
                            '已认识 ${c.words.length - c.remaining} / ${c.words.length}',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            '稳定识别 ${c.stable} 个',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _examLine(c, theme),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 26),
              if (desktop.isDesktop)
                LayoutBuilder(
                  builder: (context, constraints) {
                    final narrow = constraints.maxWidth < 650;
                    final items = [
                      _entry(
                        context,
                        '桌面小窗',
                        '留在角落，闲下来记一个。',
                        Icons.picture_in_picture_alt_outlined,
                        onWidget,
                      ),
                    ];
                    return narrow
                        ? Column(
                            children: [
                              for (final item in items)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: item,
                                ),
                            ],
                          )
                        : Row(
                            children: [
                              for (var i = 0; i < items.length; i++) ...[
                                if (i > 0) const SizedBox(width: 16),
                                Expanded(child: items[i]),
                              ],
                            ],
                          );
                  },
                ),
              const SizedBox(height: 24),
              Text(
                '轻量浏览 ≠ 无提示回忆。正式答题的结果，才用于计算正确率。',
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _entry(
    BuildContext context,
    String title,
    String subtitle,
    IconData icon,
    VoidCallback onTap,
  ) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: controller.book == null ? onLibrary : onTap,
      child: Padding(
        padding: const EdgeInsets.all(23),
        child: Row(
          children: [
            Icon(icon, size: 28, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 17),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_rounded, size: 19),
          ],
        ),
      ),
    ),
  );
  Widget _examLine(AppController c, ThemeData theme) {
    final plan = c.examPlan;
    if (!plan.planned) {
      return Text(
        '设置考试日期后，词栖会按剩余词量给出每天建议新词的参考。',
        style: TextStyle(
          fontSize: 12,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final accent = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w700,
      color: theme.colorScheme.primary,
    );
    if (plan.expired) {
      return Text('考试日期已到。今天保持节奏，不必突击大量新词。', style: accent);
    }
    final perDay = plan.perDay;
    if (perDay == null || perDay <= 0) {
      return Text('考试计划：剩余词条已经覆盖，按节奏复习即可。', style: accent);
    }
    return Text('距考试 ${plan.daysLeft ?? 0} 天 · 每天约 $perDay 词', style: accent);
  }
}
