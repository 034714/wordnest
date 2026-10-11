import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/importer.dart';
import '../data/offline_dictionary.dart';
import '../data/storage.dart';
import '../domain/controller.dart';
import '../domain/models.dart';
import '../platform/catalog_service.dart';
import 'shared_widgets.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.controller, this.onSpeak});

  final AppController controller;
  final Future<void> Function(String word)? onSpeak;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _searchController = TextEditingController();
  String _query = '';
  bool _busy = false;
  int _visibleWordCount = 60;
  bool _onlyNotes = false;

  AppController get c => widget.controller;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _pickAndPreview() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt', 'csv'],
        withData: true,
      );
      if (result == null || result.files.single.bytes == null) return;
      final file = result.files.single;
      final text = utf8.decode(file.bytes!);
      if (file.name.toLowerCase().endsWith('.csv')) {
        await _previewCsv(text, file.name);
      } else {
        await _previewText(text, file.name);
      }
    } on FormatException catch (error) {
      _message('文件编码不是有效的 UTF-8：$error');
    } catch (error) {
      _message('选择或读取词书失败：$error');
    }
  }

  Future<void> _previewCsv(String text, String filename) async {
    final labels = _firstCsvRow(text);
    final normalized = labels.map(_canonicalCsvLabel).toList();
    final hasRecognizedWord = normalized.any((label) => label == 'word');
    if (hasRecognizedWord || labels.isEmpty) {
      await _previewText(text, filename);
      return;
    }
    final mapping = await _showCsvMapping(labels);
    if (!mounted || mapping == null) return;
    await _previewText(_dropFirstCsvRow(text), filename, csvMapping: mapping);
  }

  String _dropFirstCsvRow(String text) {
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == '"') {
        if (quoted && i + 1 < text.length && text[i + 1] == '"') {
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (!quoted && (char == '\n' || char == '\r')) {
        if (char == '\r' && i + 1 < text.length && text[i + 1] == '\n') {
          i++;
        }
        return text.substring(i + 1);
      }
    }
    return '';
  }

  List<String> _firstCsvRow(String text) {
    final row = <String>[];
    final field = StringBuffer();
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (quoted) {
        if (char == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          field.write(char);
        }
      } else if (char == '"' && field.isEmpty) {
        quoted = true;
      } else if (char == ',') {
        row.add(field.toString().trim());
        field.clear();
      } else if (char == '\n' || char == '\r') {
        row.add(field.toString().trim());
        break;
      } else {
        field.write(char);
      }
    }
    if (row.isEmpty && field.isNotEmpty) row.add(field.toString().trim());
    return row;
  }

  String _canonicalCsvLabel(String label) {
    final value = label.trim().toLowerCase().replaceAll(RegExp(r'[ _-]+'), '');
    if (['word', 'w', 'term', 'english', '单词', '英文', '词汇'].contains(value)) {
      return 'word';
    }
    if ([
      'meaning',
      'translation',
      'definition',
      'tr',
      'cn',
      '释义',
      '中文',
      '意思',
    ].contains(value)) {
      return 'meaning';
    }
    if (['uk', 'britishphonetic', '英音'].contains(value)) return 'uk';
    if (['us', 'americanphonetic', '美音'].contains(value)) return 'us';
    if (['example', 'sentence', 'ex', '例句'].contains(value)) return 'example';
    if (['exampletranslation', 'excn', '例句翻译'].contains(value)) {
      return 'exampleTranslation';
    }
    if (['explanation', '说明'].contains(value)) return 'explanation';
    if (['unit', 'chapter', 'section', '单元', '章节'].contains(value)) {
      return 'unit';
    }
    return '';
  }

  Future<Map<String, int>?> _showCsvMapping(List<String> labels) async {
    final mapping = <String, int>{};
    const fields = <String, String>{
      'word': '单词（必填）',
      'meaning': '中文释义',
      'uk': '英式音标',
      'us': '美式音标',
      'example': '例句',
      'exampleTranslation': '例句翻译',
      'explanation': '补充说明',
      'unit': '单元',
    };
    return showDialog<Map<String, int>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('映射 CSV 列'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '没有识别出标准表头，请告诉词栖每一列的含义。单词列是必填项。',
                    style: TextStyle(height: 1.5),
                  ),
                  const SizedBox(height: 16),
                  for (final entry in fields.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: DropdownButtonFormField<int>(
                        initialValue: mapping[entry.key],
                        decoration: InputDecoration(labelText: entry.value),
                        items: [
                          for (var i = 0; i < labels.length; i++)
                            DropdownMenuItem(
                              value: i,
                              child: Text(
                                '${i + 1}. ${labels[i]}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (value) => setDialogState(() {
                          if (value == null) {
                            mapping.remove(entry.key);
                          } else {
                            mapping[entry.key] = value;
                          }
                        }),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: mapping['word'] == null
                  ? null
                  : () => Navigator.pop(dialogContext, mapping),
              child: const Text('继续预览'),
            ),
          ],
        ),
      ),
    );
  }

  // Local built-in sources for the 内置词库 dialog. A future online catalog
  // can append entries to this list without changing the dialog flow.
  Future<List<({String asset, String label, String detail, IconData icon})>>
  _builtInBooks() async {
    final items =
        <({String asset, String label, String detail, IconData icon})>[
          (
            asset: 'demo.json',
            label: '自编演示 24 词',
            detail: '了解完整学习流程',
            icon: Icons.auto_awesome_outlined,
          ),
        ];
    // The personal build ships this file; the public source export does not.
    try {
      await rootBundle.load('assets/demo.json');
      items.add((
        asset: 'demo.json',
        label: '内置演示词书',
        detail: '自编 24 词内容',
        icon: Icons.menu_book_rounded,
      ));
    } catch (_) {}
    return items;
  }

  Future<void> _showBuiltInBooks() async {
    final items = await _builtInBooks();
    if (!mounted) return;
    final catalog = CatalogService();
    var online = <CatalogBook>[];
    try {
      online = await catalog.list();
    } catch (_) {}
    if (!mounted) return;
    String? downloading;
    final choice = await showDialog<Object>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('内置词库'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '随包词书（离线可用）',
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  for (final item in items)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .primaryContainer,
                        child: Icon(
                          item.icon,
                          size: 20,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      title: Text(item.label),
                      subtitle: Text(item.detail),
                      onTap: downloading == null
                          ? () => Navigator.pop(dialogContext, item)
                          : null,
                    ),
                  if (online.isNotEmpty) ...[
                    const Divider(height: 22),
                    Text(
                      '在线词库（需要网络，下载后预览再导入）',
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '只收录已核对许可证的公开来源，每本都显示来源署名。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    for (final book in online)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .secondaryContainer,
                          child: Icon(
                            book.id.startsWith('kylebing')
                                ? Icons.auto_stories_rounded
                                : Icons.abc_rounded,
                            size: 20,
                            color: Theme.of(context).colorScheme.secondary,
                          ),
                        ),
                        title: Text(book.title),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            '${book.description}\n${book.attribution}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(height: 1.4),
                          ),
                        ),
                        isThreeLine: true,
                        trailing: downloading == book.id
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                ),
                              )
                            : TextButton(
                                onPressed: downloading == null
                                    ? () async {
                                        setDialogState(
                                          () => downloading = book.id,
                                        );
                                        try {
                                          final download = await catalog.fetch(
                                            book,
                                          );
                                          if (dialogContext.mounted) {
                                            Navigator.pop(
                                              dialogContext,
                                              download,
                                            );
                                          }
                                        } on CatalogError catch (error) {
                                          if (dialogContext.mounted) {
                                            setDialogState(
                                              () => downloading = null,
                                            );
                                          }
                                          _message(error.message);
                                        } catch (error) {
                                          if (dialogContext.mounted) {
                                            setDialogState(
                                              () => downloading = null,
                                            );
                                          }
                                          _message('在线词库下载失败：$error');
                                        }
                                      }
                                    : null,
                                child: const Text('下载'),
                              ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    if (choice is CatalogDownload) {
      await _previewText(choice.text, choice.filename);
      return;
    }
    if (choice is ({String asset, String label})) {
      try {
        final text = await rootBundle.loadString('assets/${choice.asset}');
        await _previewText(text, choice.asset);
      } catch (error) {
        _message('内置词库暂时不可用：$error');
      }
    }
  }

  Future<void> _previewText(
    String text,
    String filename, {
    Map<String, int>? csvMapping,
  }) async {
    setState(() => _busy = true);
    try {
      var preview = ImportParser.parse(text, filename, csvMapping: csvMapping);
      preview = await OfflineDictionary.enrich(preview);
      if (!mounted) return;
      await _showImportPreview(preview, filename);
    } catch (error) {
      _message('无法读取这本词书：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showImportPreview(
    ImportPreview preview,
    String filename,
  ) async {
    var dedupe = false;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('确认导入词书'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580, maxHeight: 560),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    preview.book.title,
                    style: Theme.of(dialogContext).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    filename,
                    style: Theme.of(dialogContext).textTheme.bodySmall
                        ?.copyWith(
                          color: Theme.of(dialogContext)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _PreviewChip(label: '词条', value: '${preview.total}'),
                      _PreviewChip(label: '重复', value: '${preview.duplicates}'),
                      _PreviewChip(
                        label: '缺释义',
                        value: '${preview.missingMeanings}',
                      ),
                      _PreviewChip(
                        label: '缺例句',
                        value: '${preview.missingExamples}',
                      ),
                    ],
                  ),
                  if (preview.duplicates > 0) ...[
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('跳过重复词'),
                      subtitle: const Text('同一个词只保留第一次出现的位置，适合乱序且有重复的公开词表。'),
                      value: dedupe,
                      onChanged: (value) =>
                          setDialogState(() => dedupe = value),
                    ),
                  ],
                  if (preview.warnings.isNotEmpty) ...[
                    const SizedBox(height: 21),
                    Text(
                      '导入提示',
                      style: Theme.of(dialogContext).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    ...preview.warnings
                        .take(8)
                        .map(
                          (warning) => Padding(
                            padding: const EdgeInsets.only(bottom: 7),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.info_outline_rounded,
                                  size: 17,
                                  color: Theme.of(dialogContext)
                                      .colorScheme
                                      .tertiary,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    warning,
                                    style: Theme.of(dialogContext)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(height: 1.4),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                  ],
                  const SizedBox(height: 21),
                  Text(
                    '前 5 个词条',
                    style: Theme.of(dialogContext).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  ...preview.entries.values
                      .take(5)
                      .map(
                        (entry) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            entry.word,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            entry.meaning.isEmpty ? '暂无释义' : entry.coreMeaning,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'cancel'),
              child: const Text('先不导入'),
            ),
            FilledButton.icon(
              onPressed: () =>
                  Navigator.pop(dialogContext, dedupe ? 'dedupe' : 'plain'),
              icon: const Icon(Icons.download_rounded),
              label: Text(
                dedupe ? '去重导入 ${_uniqueCount(preview)} 词' : '导入这本词书',
              ),
            ),
          ],
        ),
      ),
    );
    if (choice == null || choice == 'cancel' || !mounted) return;
    final target = choice == 'dedupe' ? _dedupePreview(preview) : preview;
    final ok = await c.importBook(target);
    if (ok) {
      _message(
        choice == 'dedupe'
            ? '已去重导入「${target.book.title}」，共 ${target.total} 个词。'
            : '已导入「${preview.book.title}」，现在可以开始学习了。',
      );
    }
  }

  /// Keeps the first occurrence of every word, preserving its unit and order.
  ImportPreview _dedupePreview(ImportPreview preview) {
    final seen = <String>{};
    final members = <BookMember>[];
    for (final member in preview.book.members) {
      if (seen.add(member.entryId)) members.add(member);
    }
    final book = WordBook(
      id: preview.book.id,
      title: preview.book.title,
      source: preview.book.source,
      importedAt: preview.book.importedAt,
      members: members,
    );
    return ImportPreview(
      book: book,
      entries: preview.entries,
      total: members.length,
      duplicates: 0,
      missingMeanings: preview.missingMeanings,
      missingExamples: preview.missingExamples,
      warnings: const [],
    );
  }

  int _uniqueCount(ImportPreview preview) =>
      preview.book.members.map((m) => m.entryId).toSet().length;

  Future<void> _deleteBook(WordBook book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除「${book.title}」？'),
        content: const Text('这会删除词书关联的学习进度和笔记。若你还需要它们，请先导出备份。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await c.deleteBook(book.id);
    if (ok) _message('已删除「${book.title}」。');
  }

  Future<void> _exportBackup() async {
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出词栖备份',
        fileName: 'wordnest-backup.json',
        bytes: Uint8List.fromList(utf8.encode(BackupCodec.encode(c.state))),
      );
      if (path != null) _message('备份已保存。');
    } catch (error) {
      _message('导出备份失败：$error');
    }
  }

  Future<void> _restoreBackup() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'wordnest'],
        withData: true,
      );
      if (result == null || result.files.single.bytes == null) return;
      final snapshot = BackupCodec.decode(
        utf8.decode(result.files.single.bytes!),
      );
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('恢复本地备份？'),
          content: Text(
            '备份包含 ${snapshot.books.length} 本词书、${snapshot.entries.length} 个词条和 ${snapshot.events.length} 条学习记录。恢复后会替换当前本地数据。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('恢复备份'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final ok = await c.restore(snapshot);
      if (ok) _message('备份已恢复，学习记录也回来了。');
    } catch (error) {
      _message('备份文件无效或无法读取：$error');
    }
  }

  Future<void> _exportCsv() async {
    final entries = c.words;
    if (entries.isEmpty) {
      _message('当前词书还没有词条。');
      return;
    }
    final rows = <List<String>>[
      [
        'word',
        'meaning',
        'uk',
        'us',
        'example',
        'exampleTranslation',
        'explanation',
        'usage',
        'root',
        'synonyms',
        'note',
      ],
      ...entries.map(
        (entry) => [
          entry.word,
          entry.meaning,
          entry.uk,
          entry.us,
          entry.example,
          entry.exampleTranslation,
          entry.explanation,
          entry.usage,
          entry.root,
          entry.synonyms,
          c.state.notes[entry.id] ?? '',
        ],
      ),
    ];
    final csv = rows.map((row) => row.map(_csvCell).join(',')).join('\r\n');
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出当前词书为 CSV',
        fileName: '${c.book?.title ?? 'wordnest'}-entries.csv',
        bytes: Uint8List.fromList(utf8.encode(csv)),
      );
      if (path != null) _message('CSV 已保存，包含 ${entries.length} 个词条。');
    } catch (error) {
      _message('导出 CSV 失败：$error');
    }
  }

  String _csvCell(String value) {
    final normalized = value.replaceAll('"', '""');
    return '"$normalized"';
  }

  @override
  Widget build(BuildContext context) {
    final books = c.state.books;
    final words = c.words.where((entry) {
      final q = _query.trim().toLowerCase();
      final match =
          q.isEmpty ||
          entry.word.toLowerCase().contains(q) ||
          entry.meaning.toLowerCase().contains(q);
      return match &&
          (!_onlyNotes || c.state.notes[entry.id]?.trim().isNotEmpty == true);
    }).toList();
    final visibleWords = words.take(_visibleWordCount).toList();

    return ContentShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeading(
            title: '我的词书',
            subtitle: '把正在学习的内容放在手边，顺序、笔记和进度都会留在本地。',
            trailing: FilledButton.icon(
              onPressed: _busy ? null : _pickAndPreview,
              icon: const Icon(Icons.add_rounded),
              label: const Text('导入词书'),
            ),
          ),
          const SizedBox(height: 25),
          if (books.isEmpty)
            EmptyState(
              icon: Icons.auto_stories_outlined,
              title: '还没有词书',
              message: '点右上角「导入词书」选择 JSON、TXT 或 CSV；也可以先从内置词库里挑一本直接开始。',
              action: OutlinedButton.icon(
                onPressed: _busy ? null : _showBuiltInBooks,
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('打开内置词库'),
              ),
            )
          else ...[
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 830 ? 2 : 1;
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 14,
                    mainAxisSpacing: 14,
                    mainAxisExtent: 240,
                  ),
                  itemCount: books.length,
                  itemBuilder: (context, index) => _BookCard(
                    book: books[index],
                    active: c.book?.id == books[index].id,
                    controller: c,
                    onSelect: () async {
                      await c.updateSettings(
                        (settings) => settings.activeBookId = books[index].id,
                      );
                    },
                    onDelete: () => _deleteBook(books[index]),
                  ),
                );
              },
            ),
            const SizedBox(height: 25),
            SurfaceCard(
              padding: const EdgeInsets.all(20),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _showBuiltInBooks,
                    icon: const Icon(Icons.cloud_download_outlined),
                    label: const Text('内置词库'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _exportBackup,
                    icon: const Icon(Icons.save_alt_rounded),
                    label: const Text('导出完整备份'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _restoreBackup,
                    icon: const Icon(Icons.restore_rounded),
                    label: const Text('恢复备份'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _exportCsv,
                    icon: const Icon(Icons.table_view_rounded),
                    label: const Text('导出当前 CSV'),
                  ),
                  const Text('备份包含词书、笔记与学习记录；数据只保存在本机。'),
                ],
              ),
            ),
            const SizedBox(height: 30),
            if (c.book != null) ...[
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 620;
                  final heading = SectionTitle(
                    title: '词条浏览',
                    subtitle: '${c.book!.title} · ${c.words.length} 个词条',
                    icon: Icons.search_rounded,
                  );
                  final search = TextField(
                    controller: _searchController,
                    onChanged: (value) => setState(() {
                      _query = value;
                      _visibleWordCount = 60;
                    }),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search_rounded),
                      hintText: '搜索词条',
                      isDense: true,
                    ),
                  );
                  return compact
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            heading,
                            const SizedBox(height: 8),
                            search,
                          ],
                        )
                      : Row(
                          children: [
                            Expanded(child: heading),
                            const SizedBox(width: 18),
                            SizedBox(width: 260, child: search),
                          ],
                        );
                },
              ),
              const SizedBox(height: 5),
              if (words.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('没有匹配的词条。')),
                )
              else ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '显示 ${visibleWords.length} / ${words.length} 个词条',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      ChoiceChip(
                        label: Text(
                          '只看生词本（${c.words.where((entry) => c.state.notes[entry.id]?.trim().isNotEmpty == true).length}）',
                        ),
                        selected: _onlyNotes,
                        onSelected: (value) => setState(() {
                          _onlyNotes = value;
                          _visibleWordCount = 60;
                        }),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: visibleWords.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) => _WordRow(
                    entry: visibleWords[index],
                    controller: c,
                    onTap: () => showWordDetails(
                      context,
                      c,
                      visibleWords[index],
                      onSpeak: widget.onSpeak,
                    ),
                  ),
                ),
                if (visibleWords.length < words.length) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.center,
                    child: OutlinedButton.icon(
                      onPressed: () => setState(() => _visibleWordCount += 60),
                      icon: const Icon(Icons.expand_more_rounded),
                      label: Text(
                        '加载更多（剩余 ${words.length - visibleWords.length}）',
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ],
        ],
      ),
    );
  }
}

class _PreviewChip extends StatelessWidget {
  const _PreviewChip({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Chip(
      label: Text('$label  $value'),
      backgroundColor: theme.colorScheme.primaryContainer.withValues(
        alpha: .45,
      ),
      side: BorderSide.none,
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.active,
    required this.controller,
    required this.onSelect,
    required this.onDelete,
  });
  final WordBook book;
  final bool active;
  final AppController controller;
  final Future<void> Function() onSelect;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = book.uniqueIds.length;
    final learned = book.uniqueIds
        .where((id) => controller.state.cards[id]?.seen == true)
        .length;
    return SurfaceCard(
      padding: const EdgeInsets.all(20),
      color: active
          ? theme.colorScheme.primaryContainer.withValues(alpha: .32)
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  book.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (active)
                const Chip(
                  label: Text('正在学习'),
                  visualDensity: VisualDensity.compact,
                ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'delete') onDelete();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'delete', child: Text('删除词书')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$count 个词条 · ${book.units.length} 个单元',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (book.source.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              book.source,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: LinearProgressIndicator(
                  value: count == 0 ? 0 : learned / count,
                  minHeight: 7,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(width: 12),
              Text('$learned / $count', style: theme.textTheme.labelMedium),
            ],
          ),
          const SizedBox(height: 13),
          if (!active)
            TextButton.icon(
              onPressed: onSelect,
              icon: const Icon(Icons.play_circle_outline_rounded, size: 18),
              label: const Text('切换到这本词书'),
            )
          else
            Text(
              '导入于 ${book.importedAt.toLocal().year}-${book.importedAt.toLocal().month.toString().padLeft(2, '0')}-${book.importedAt.toLocal().day.toString().padLeft(2, '0')}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _WordRow extends StatelessWidget {
  const _WordRow({
    required this.entry,
    required this.controller,
    required this.onTap,
  });
  final WordEntry entry;
  final AppController controller;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = controller.state.cards[entry.id];
    final note = controller.state.notes[entry.id]?.trim().isNotEmpty == true;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withValues(
                    alpha: .55,
                  ),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Text(
                  entry.word.substring(0, 1).toUpperCase(),
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.word,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      entry.coreMeaning.isEmpty ? '暂无释义' : entry.coreMeaning,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (entry.uk.isNotEmpty)
                Text(
                  '/${entry.uk}/',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              if (note)
                const Padding(
                  padding: EdgeInsets.only(left: 10),
                  child: Icon(Icons.sticky_note_2_outlined, size: 18),
                ),
              const SizedBox(width: 9),
              Icon(
                card?.seen == true
                    ? Icons.check_circle_outline_rounded
                    : Icons.chevron_right_rounded,
                color: card?.seen == true
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
