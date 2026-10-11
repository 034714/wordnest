import 'package:flutter/material.dart';

import '../domain/controller.dart';
import '../domain/models.dart';
import '../data/offline_dictionary.dart';

typedef StartRoundCallback = Future<void> Function(
  String mode, {
  required bool resume,
  int? limit,
});

/// Optional friendly wording; assessment terms, errors and legal text stay literal.
class AppCopy {
  const AppCopy(this.cute);
  final bool cute;
  String get hero => cute ? '让单词，在小窝里住下来。' : '给单词，一点栖息的时间。';
  String get start => cute ? '开启一小轮' : '开始新一轮';
  String get resume => cute ? '接着上次的小脚印' : '继续上次学习';
  String get empty => cute ? '小窝暂时安静，先歇一歇。' : '这会儿，先歇一歇。';
  String get success => cute ? '这一小轮，稳稳收好啦。' : '这一小轮，完成了。';
  String get newWord => cute ? '新朋友' : '新词';
  String get remember => cute ? '记住啦' : '记住';
  String get unfamiliar => cute ? '还不熟，慢慢来' : '过 · 不熟悉';
  String get spellingCorrect => cute ? '拼对啦，去看看下一个。' : '拼写正确。继续下一词。';
  String get typingWrong => cute ? '差一点点，再试一次吧。' : '拼写不正确，请重新输入后再检查。';
  String get showAnswer => cute ? '看一眼答案 · Tab' : '显示答案 · Tab';
  String get hideAnswer => cute ? '收好答案 · Tab' : '隐藏答案 · Tab';
  String get typingHint => cute ? '在下面的输入框里敲出这个单词' : '在输入框中输入英文拼写';
  String get skipWord => cute ? '跳过去，看看下一个' : '跳过这个词';
  String get correct => cute ? '答对啦，收下一点进步。' : '回答正确。';
  String get incorrect => cute ? '没关系，再看看答案。' : '回答不正确，请查看答案。';
}

const learningOrderLabels = <String, String>{
  'book': '按词书',
  'reverse': '倒序',
  'alphabet': '按字母',
  'random': '随机',
  'weak': '薄弱优先',
  'root': '按词根',
};

class RoundCountChips extends StatelessWidget {
  const RoundCountChips({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });
  final int value;
  final ValueChanged<int> onChanged;
  final bool enabled;

  Future<void> _custom(BuildContext context) async {
    final input = TextEditingController(text: '$value');
    final key = GlobalKey<FormState>();
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义每轮词数'),
        content: Form(
          key: key,
          child: TextFormField(
            controller: input,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '词数（1–50）'),
            validator: (text) {
              final count = int.tryParse(text?.trim() ?? '');
              return count != null && count >= 1 && count <= 50
                  ? null
                  : '请输入 1 到 50 的整数';
            },
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
                Navigator.pop(context, int.parse(input.text.trim()));
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    input.dispose();
    if (result != null) onChanged(result);
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final count in const [1, 3, 5, 10, 20, 50])
        ChoiceChip(
          label: Text('$count'),
          selected: value == count,
          onSelected: enabled ? (_) => onChanged(count) : null,
        ),
      ActionChip(
        label: Text(
          const [1, 3, 5, 10, 20, 50].contains(value) ? '自定义' : '自定义 · $value',
        ),
        onPressed: enabled ? () => _custom(context) : null,
      ),
    ],
  );
}

class ContentShell extends StatelessWidget {
  const ContentShell({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(28, 30, 28, 44),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: padding,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1060),
          child: child,
        ),
      ),
    );
  }
}

class PageHeading extends StatelessWidget {
  const PageHeading({
    super.key,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        final copy = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: .2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.55,
              ),
            ),
          ],
        );
        if (trailing == null) return copy;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [copy, const SizedBox(height: 16), trailing!],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: copy),
            const SizedBox(width: 18),
            trailing!,
          ],
        );
      },
    );
  }
}

class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(22),
    this.color,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color,
      child: Padding(padding: padding, child: child),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle({
    super.key,
    required this.title,
    required this.subtitle,
    this.icon,
  });

  final String title;
  final String subtitle;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 21, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
    this.color,
  });

  final String label;
  final String value;
  final String caption;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = color ?? theme.colorScheme.primary;
    return SurfaceCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 19, color: accent),
              const Spacer(),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            value,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: accent,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            caption,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      child: Column(
        children: [
          Icon(
            icon,
            size: 46,
            color: theme.colorScheme.primary.withValues(alpha: .65),
          ),
          const SizedBox(height: 15),
          Text(
            title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.55,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    );
  }
}

class LabeledSwitch extends StatelessWidget {
  const LabeledSwitch({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: enabled,
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
        ),
      ),
      trailing: Switch(value: value, onChanged: enabled ? onChanged : null),
    );
  }
}

Future<void> showWordDetails(
  BuildContext context,
  AppController controller,
  WordEntry entry, {
  Future<void> Function(String)? onSpeak,
}) async {
  final noteController = TextEditingController(
    text: controller.state.notes[entry.id] ?? '',
  );
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      return AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(26, 24, 18, 4),
        contentPadding: const EdgeInsets.fromLTRB(26, 10, 26, 8),
        actionsPadding: const EdgeInsets.fromLTRB(18, 4, 18, 16),
        title: Row(
          children: [
            Expanded(
              child: Text(
                entry.word,
                style: const TextStyle(
                  fontSize: 27,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (onSpeak != null)
              IconButton(
                tooltip: '朗读',
                onPressed: () => onSpeak(entry.word),
                icon: const Icon(Icons.volume_up_outlined),
              ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 640),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entry.uk.trim().isNotEmpty || entry.us.trim().isNotEmpty)
                  Wrap(
                    spacing: 14,
                    runSpacing: 5,
                    children: [
                      if (entry.uk.trim().isNotEmpty)
                        _Pronunciation(label: '英', value: entry.uk),
                      if (entry.us.trim().isNotEmpty)
                        _Pronunciation(label: '美', value: entry.us),
                    ],
                  ),
                if (entry.meaning.trim().isNotEmpty)
                  _DetailBlock(label: '释义', value: entry.meaning),
                if (entry.example.trim().isNotEmpty)
                  _DetailBlock(
                    label: '例句',
                    value: entry.example,
                    secondary: entry.exampleTranslation,
                  ),
                if (entry.explanation.trim().isNotEmpty)
                  _DetailBlock(label: '补充说明', value: entry.explanation),
                if (entry.usage.trim().isNotEmpty)
                  _DetailBlock(label: '常见用法', value: entry.usage),
                if (entry.root.trim().isNotEmpty)
                  _DetailBlock(label: '词根词源', value: entry.root)
                else if (OfflineMorphology.hints(entry.word).isNotEmpty)
                  _DetailBlock(
                    label: '构词提示',
                    value: OfflineMorphology.hints(entry.word).join(' · '),
                  ),
                if (entry.synonyms.trim().isNotEmpty)
                  _DetailBlock(label: '近义词', value: entry.synonyms),
                const SizedBox(height: 13),
                Text(
                  '我的笔记',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: noteController,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    hintText: '写下自己的联想、易错点或例句…',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () async {
              final ok = await controller.note(
                entry.id,
                noteController.text.trim(),
              );
              if (!dialogContext.mounted) return;
              if (ok) Navigator.pop(dialogContext);
            },
            child: const Text('保存笔记'),
          ),
        ],
      );
    },
  );
  noteController.dispose();
}

class _Pronunciation extends StatelessWidget {
  const _Pronunciation({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Chip(
    avatar: CircleAvatar(
      radius: 10,
      child: Text(label, style: const TextStyle(fontSize: 10)),
    ),
    label: Text('/$value/'),
  );
}

class _DetailBlock extends StatelessWidget {
  const _DetailBlock({
    required this.label,
    required this.value,
    this.secondary = '',
  });
  final String label;
  final String value;
  final String secondary;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          Text(value, style: theme.textTheme.bodyLarge?.copyWith(height: 1.55)),
          if (secondary.trim().isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              secondary,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
