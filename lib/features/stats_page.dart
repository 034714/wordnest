import 'package:flutter/material.dart';

import '../domain/controller.dart';
import '../domain/models.dart';
import 'shared_widgets.dart';

/// 学习记录页：统计卡片 + 错题清单 + 按天分组、可继续加载的活动记录。
///
/// 「错题」数据来自并行落地的 `AppController.wrongFormalEvents({int? limit})`。
/// 这里用 [_wrongFormalEvents] 做防御式读取：契约缺失时退回本地事件推导，
/// 页面不会因为方法尚未落地而报错。
class StatsPage extends StatefulWidget {
  const StatsPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  /// null = all days; otherwise a yyyy-MM-dd key for one local day.
  String? _dayFilter;

  String _dayKey(DateTime local) =>
      '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';

  static const _pageSize = 50;
  static const _wrongPreviewLimit = 10;

  int _visibleEvents = _pageSize;

  AppController get c => widget.controller;

  void _loadMoreActivities() => setState(() => _visibleEvents += _pageSize);

  @override
  Widget build(BuildContext context) {
    final formal = c.state.events
        .where((event) => event.kind == 'formal')
        .toList();
    final self = c.state.events
        .where(
          (event) => event.kind == 'self' && !event.id.startsWith('handled-'),
        )
        .toList();
    final views = c.today.where((event) => event.kind == 'view').toList();
    final correct = formal.where((event) => event.correct == true).length;
    final formalAccuracy = formal.isEmpty
        ? 0
        : (correct / formal.length * 100).round();
    final selfKnown = self
        .where(
          (event) =>
              _actionName(event) == 'remember' || _actionName(event) == 'known',
        )
        .length;
    final dueBuckets = _dueBuckets(c);
    final week = _weekData(c);
    final maxWeek = week.fold<int>(
      1,
      (max, item) => item.total > max ? item.total : max,
    );
    final recent = [...c.state.events]..sort((a, b) => b.at.compareTo(a.at));
    final wrong = _wrongFormalEvents(c);

    return ContentShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PageHeading(
            title: '学习记录',
            subtitle: '看见真实的练习、浏览和自我判断，找到适合自己的节奏。',
          ),
          const SizedBox(height: 25),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 850
                  ? 4
                  : constraints.maxWidth >= 540
                  ? 2
                  : 1;
              final tiles = [
                MetricTile(
                  label: '今日正式',
                  value: '${c.formalToday}',
                  caption: '正式答题次数',
                  icon: Icons.task_alt_rounded,
                  color: const Color(0xff39856c),
                ),
                MetricTile(
                  label: '正确率',
                  value: '$formalAccuracy%',
                  caption: formal.isEmpty
                      ? '还没有正式答题'
                      : '基于 ${formal.length} 次正式答题',
                  icon: Icons.verified_rounded,
                  color: const Color(0xffb4773d),
                ),
                MetricTile(
                  label: '今日浏览',
                  value: '${views.length}',
                  caption: '轻量过词，不计入正式答题',
                  icon: Icons.visibility_outlined,
                  color: const Color(0xff5576a8),
                ),
                MetricTile(
                  label: '学习天数',
                  value: '${c.daysActive}',
                  caption: '有学习行为的天数',
                  icon: Icons.local_fire_department_outlined,
                  color: const Color(0xffb85f4e),
                ),
              ];
              if (columns == 1) {
                return Column(
                  children: [
                    for (var index = 0; index < tiles.length; index++) ...[
                      if (index > 0) const SizedBox(height: 13),
                      tiles[index],
                    ],
                  ],
                );
              }
              return GridView.count(
                crossAxisCount: columns,
                crossAxisSpacing: 13,
                mainAxisSpacing: 13,
                childAspectRatio: columns == 2 ? 1.72 : 1.35,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: tiles,
              );
            },
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 800) {
                return Column(
                  children: [
                    _weeklyCard(context, week, maxWeek),
                    const SizedBox(height: 16),
                    _dueCard(context, dueBuckets),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: _weeklyCard(context, week, maxWeek)),
                  const SizedBox(width: 16),
                  Expanded(flex: 2, child: _dueCard(context, dueBuckets)),
                ],
              );
            },
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 800) {
                return Column(
                  children: [
                    _selfViewCard(context, formal, self, selfKnown),
                    const SizedBox(height: 16),
                    _libraryProgressCard(context),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _selfViewCard(context, formal, self, selfKnown),
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: _libraryProgressCard(context)),
                ],
              );
            },
          ),
          const SizedBox(height: 18),
          _wrongCard(context, wrong),
          const SizedBox(height: 18),
          _recentCard(context, recent),
        ],
      ),
    );
  }

  Widget _weeklyCard(BuildContext context, List<_DayStats> week, int maxValue) {
    final theme = Theme.of(context);
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(
            title: '过去 7 天',
            subtitle: '正式答题和轻量浏览分别显示，避免把“看过”误当成“答对”。',
            icon: Icons.bar_chart_rounded,
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 175,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final day in week)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: Tooltip(
                                message:
                                    '${day.label}\n正式 ${day.formal} · 浏览 ${day.views}',
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Flexible(
                                      child: FractionallySizedBox(
                                        heightFactor: day.formal / maxValue,
                                        child: Container(
                                          width: 12,
                                          decoration: BoxDecoration(
                                            color: theme.colorScheme.primary,
                                            borderRadius:
                                                const BorderRadius.vertical(
                                                  top: Radius.circular(5),
                                                ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: FractionallySizedBox(
                                        heightFactor: day.views / maxValue,
                                        child: Container(
                                          width: 12,
                                          decoration: BoxDecoration(
                                            color: theme
                                                .colorScheme
                                                .tertiaryContainer,
                                            borderRadius:
                                                const BorderRadius.vertical(
                                                  top: Radius.circular(5),
                                                ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 9),
                          Text(day.label, style: theme.textTheme.labelSmall),
                          const SizedBox(height: 3),
                          Text(
                            '${day.formal + day.views}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              const Text('正式答题'),
              const SizedBox(width: 18),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              const Text('轻量浏览'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dueCard(BuildContext context, List<_DueBucket> buckets) {
    final theme = Theme.of(context);
    final total = buckets.fold<int>(0, (sum, bucket) => sum + bucket.count);
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(
            title: '复习分布',
            subtitle: '当前词书中已认识词条的到期情况。',
            icon: Icons.schedule_rounded,
          ),
          const SizedBox(height: 8),
          if (total == 0)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 25),
              child: Center(child: Text('还没有需要复习的卡片。')),
            )
          else ...[
            for (final bucket in buckets)
              Padding(
                padding: const EdgeInsets.only(bottom: 15),
                child: Row(
                  children: [
                    SizedBox(width: 74, child: Text(bucket.label)),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: LinearProgressIndicator(
                          value: bucket.count / total,
                          minHeight: 10,
                          color: bucket.color,
                          backgroundColor: bucket.color.withValues(alpha: .13),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 28,
                      child: Text(
                        '${bucket.count}',
                        textAlign: TextAlign.end,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (total > 0)
            Text(
              '共 $total 个已进入复习的词条',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _selfViewCard(
    BuildContext context,
    List<LearningEvent> formal,
    List<LearningEvent> self,
    int selfKnown,
  ) {
    final theme = Theme.of(context);
    final selfAccuracy = self.isEmpty
        ? 0
        : (selfKnown / self.length * 100).round();
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(
            title: '正式答题与自我判断',
            subtitle: '两种数据用途不同：正式题影响间隔，自我判断记录当下的熟悉程度。',
            icon: Icons.compare_arrows_rounded,
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              Expanded(
                child: _MiniStat(
                  label: '正式答题',
                  value: '${formal.length}',
                  detail: formal.isEmpty
                      ? '等待第一题'
                      : '正确 ${formal.where((event) => event.correct == true).length} 次',
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _MiniStat(
                  label: '自我判断',
                  value: '${self.length}',
                  detail: self.isEmpty
                      ? '还没有记录'
                      : '记住 $selfKnown 次 · $selfAccuracy%',
                  color: theme.colorScheme.tertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 15),
          Text(
            '今日轻量过词 ${c.seenToday} 个；其中看过只会记录熟悉度，不会提高正式正确率。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _libraryProgressCard(BuildContext context) {
    final theme = Theme.of(context);
    final words = c.words;
    final total = words.length;
    final learned = words
        .where((entry) => c.state.cards[entry.id]?.seen == true)
        .length;
    final stable = c.stable;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(
            title: '当前词书',
            subtitle: c.book?.title ?? '还没有选中的词书。',
            icon: Icons.auto_stories_outlined,
          ),
          const SizedBox(height: 8),
          if (total == 0)
            const Text('导入词书后，这里会显示词书进度。')
          else ...[
            Text(
              '$learned / $total',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: learned / total,
              minHeight: 10,
              borderRadius: BorderRadius.circular(8),
            ),
            const SizedBox(height: 13),
            Text(
              '已见过 $learned 个 · 稳定掌握 $stable 个',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 错题：最近答错的正式题，点一下打开词条详情。
  Widget _wrongCard(BuildContext context, List<LearningEvent> wrong) {
    final theme = Theme.of(context);
    final visible = wrong.take(_wrongPreviewLimit).toList();
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(
            title: '错题',
            subtitle: '最近答错的正式题，点一下可以查看词条详情。',
            icon: Icons.report_gmailerrorred_rounded,
          ),
          const SizedBox(height: 4),
          if (visible.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('还没有答错的正式题；继续保持。')),
            )
          else ...[
            for (final event in visible)
              _wrongTile(context, theme, event, c.state.entries[event.entryId]),
            if (wrong.length > visible.length)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '共 ${wrong.length} 条错题，这里先显示最近 ${visible.length} 条；完整记录在下面的活动列表里。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _wrongTile(
    BuildContext context,
    ThemeData theme,
    LearningEvent event,
    WordEntry? entry,
  ) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      onTap: entry == null ? null : () => showWordDetails(context, c, entry),
      leading: CircleAvatar(
        radius: 17,
        backgroundColor: theme.colorScheme.errorContainer.withValues(
          alpha: .55,
        ),
        child: Icon(
          Icons.close_rounded,
          size: 17,
          color: theme.colorScheme.error,
        ),
      ),
      title: Text(
        entry?.word ?? '已删除词条',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text('你答错的时间：${_momentLabel(event.at)}'),
      trailing: const Icon(Icons.chevron_right_rounded),
    );
  }

  /// 最近活动：全部学习事件按天分组，每页 50 条，可继续加载。
  Widget _recentCard(BuildContext context, List<LearningEvent> recent) {
    final theme = Theme.of(context);
    final allDays = <String>{for (final e in recent) _dayKey(e.at.toLocal())};
    final filtered = _dayFilter == null
        ? recent
        : recent.where((e) => _dayKey(e.at.toLocal()) == _dayFilter).toList();
    final visible = filtered.take(_visibleEvents).toList();
    final days = <_ActivityDay>[];
    for (final event in visible) {
      final local = event.at.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      if (days.isEmpty || days.last.day != day) days.add(_ActivityDay(day));
      days.last.events.add(event);
    }
    final remaining = filtered.length - visible.length;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(
            title: '最近活动',
            subtitle: '全部学习事件按天分组；每页加载 $_pageSize 条，也可以直接选某一天。',
            icon: Icons.history_rounded,
          ),
          const SizedBox(height: 8),
          // Direct day picker for older records, newest day first.
          Wrap(
            key: const ValueKey('activity-day-filter'),
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('全部'),
                selected: _dayFilter == null,
                onSelected: (_) => setState(() {
                  _dayFilter = null;
                  _visibleEvents = _pageSize;
                }),
              ),
              for (final day in allDays.take(14))
                ChoiceChip(
                  label: Text(day),
                  selected: _dayFilter == day,
                  onSelected: (_) => setState(() {
                    _dayFilter = day;
                    _visibleEvents = _pageSize;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  _dayFilter == null ? '完成一次浏览或答题后，这里会留下记录。' : '这一天没有学习记录。',
                ),
              ),
            )
          else ...[
            for (final (index, group) in days.indexed) ...[
              if (index > 0) const SizedBox(height: 6),
              _dayHeader(theme, group),
              for (final event in group.events) _activityTile(theme, event),
            ],
            const SizedBox(height: 10),
            if (remaining > 0)
              Align(
                alignment: Alignment.center,
                child: OutlinedButton.icon(
                  key: const ValueKey('activity-load-more'),
                  onPressed: _loadMoreActivities,
                  icon: const Icon(Icons.expand_more_rounded),
                  label: Text('加载更多（剩余 $remaining）'),
                ),
              )
            else if (filtered.length > _pageSize)
              Text(
                '已经显示全部 ${filtered.length} 条活动记录。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _dayHeader(ThemeData theme, _ActivityDay group) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 2),
      child: Row(
        children: [
          Text(
            _dayLabel(group.day),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
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
          const SizedBox(width: 10),
          Text(
            '${group.events.length} 条',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _activityTile(ThemeData theme, LearningEvent event) {
    final entry = c.state.entries[event.entryId];
    final label = switch (event.kind) {
      'formal' => event.correct == true ? '正式答题 · 正确' : '正式答题 · 再复习',
      'self' => _actionName(event) == 'pass' ? '自我判断 · 稍后再看' : '自我判断 · 记住了',
      'view' => '轻量浏览',
      _ => event.kind,
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: CircleAvatar(
        radius: 17,
        backgroundColor: theme.colorScheme.primaryContainer.withValues(
          alpha: .55,
        ),
        child: Icon(
          event.kind == 'formal'
              ? Icons.task_alt_rounded
              : Icons.visibility_outlined,
          size: 17,
          color: theme.colorScheme.primary,
        ),
      ),
      title: Text(
        entry?.word ?? '已删除词条',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(label),
      trailing: Text(
        _clockLabel(event.at),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  String _actionName(LearningEvent event) {
    final action = event.action.trim();
    if (action.isEmpty) return '';
    return action.split(':').last;
  }

  List<_DayStats> _weekData(AppController c) {
    final now = DateTime.now();
    return List.generate(7, (index) {
      final day = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(Duration(days: 6 - index));
      bool sameDay(LearningEvent event) {
        final date = event.at.toLocal();
        return date.year == day.year &&
            date.month == day.month &&
            date.day == day.day;
      }

      final events = c.state.events.where(sameDay).toList();
      return _DayStats(
        label: ['一', '二', '三', '四', '五', '六', '日'][day.weekday - 1],
        formal: events.where((event) => event.kind == 'formal').length,
        views: events
            .where(
              (event) =>
                  event.kind == 'view' ||
                  (event.kind == 'self' && !event.id.startsWith('handled-')),
            )
            .length,
      );
    });
  }

  List<_DueBucket> _dueBuckets(AppController c) {
    final now = DateTime.now();
    var today = 0;
    var tomorrow = 0;
    var later = 0;
    var overdue = 0;
    for (final entry in c.words) {
      final card = c.state.cards[entry.id];
      if (card == null || !card.seen) continue;
      final due = card.due.toLocal();
      final day = DateTime(due.year, due.month, due.day);
      final current = DateTime(now.year, now.month, now.day);
      if (!due.isAfter(now)) {
        overdue++;
      } else if (day == current) {
        today++;
      } else if (day == current.add(const Duration(days: 1))) {
        tomorrow++;
      } else {
        later++;
      }
    }
    return [
      _DueBucket(label: '已逾期', count: overdue, color: const Color(0xffc15d52)),
      _DueBucket(label: '今天', count: today, color: const Color(0xffb4773d)),
      _DueBucket(label: '明天', count: tomorrow, color: const Color(0xff39856c)),
      _DueBucket(label: '之后', count: later, color: const Color(0xff5576a8)),
    ];
  }

  String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    return '${day.year} 年 ${day.month} 月 ${day.day} 日';
  }

  /// 同一天内只显示时刻。
  String _clockLabel(DateTime date) {
    final local = date.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  /// 错题时间：带上「今天/昨天/日期」，因为错题清单不按天分组。
  String _momentLabel(DateTime date) {
    final local = date.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    return '${_dayLabel(day)} ${_clockLabel(date)}';
  }
}

/// 防御式读取 `AppController.wrongFormalEvents({int? limit})`。
/// 方法未落地（或签名不同）时退回本地事件推导：正式题且答错，按时间倒序。
List<LearningEvent> _wrongFormalEvents(AppController controller, {int? limit}) {
  final dynamic target = controller;
  try {
    final Object? fn = target.wrongFormalEvents;
    if (fn is Function) {
      Object? raw;
      try {
        raw = Function.apply(fn, const [], {#limit: limit});
      } catch (_) {
        raw = Function.apply(fn, const []);
      }
      if (raw is Iterable) {
        final events = raw.whereType<LearningEvent>().toList()
          ..sort((a, b) => b.at.compareTo(a.at));
        return limit == null ? events : events.take(limit).toList();
      }
    }
  } catch (_) {
    // Fall through to the local derivation below.
  }
  final events =
      controller.state.events
          .where((event) => event.kind == 'formal' && event.correct == false)
          .toList()
        ..sort((a, b) => b.at.compareTo(a.at));
  return limit == null ? events : events.take(limit).toList();
}

class _ActivityDay {
  _ActivityDay(this.day);
  final DateTime day;
  final List<LearningEvent> events = [];
}

class _DayStats {
  const _DayStats({
    required this.label,
    required this.formal,
    required this.views,
  });
  final String label;
  final int formal;
  final int views;
  int get total => formal + views;
}

class _DueBucket {
  const _DueBucket({
    required this.label,
    required this.count,
    required this.color,
  });
  final String label;
  final int count;
  final Color color;
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.label,
    required this.value,
    required this.detail,
    required this.color,
  });
  final String label;
  final String value;
  final String detail;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(15),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        Text(
          value,
          style: TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          detail,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    ),
  );
}
