import 'dart:convert';

import 'package:flutter/services.dart';

import '../domain/models.dart';

/// Original, conservative study hints, not a claim of historical etymology.
class OfflineMorphology {
  static const _prefixes = {
    'un': 'un-：常提示否定或反向动作',
    're': 're-：常提示再次或回到原处',
    'dis': 'dis-：常提示相反、分离或去除',
    'pre': 'pre-：常提示在先、预先',
    'mis': 'mis-：常提示错误或不当',
  };
  static const _suffixes = {
    'ness': '-ness：常把性质表达为名词',
    'ment': '-ment：常表示动作、过程或结果',
    'less': '-less：常提示缺少某物',
    'ful': '-ful：常提示具有某种性质',
    'ly': '-ly：常见于副词，也可用于形容词',
    'able': '-able：常提示能够或适于某种动作',
    'tion': '-tion：常见于表示动作或结果的名词',
  };
  static List<String> hints(String word) {
    final key = wordKey(word);
    return [
      for (final item in _prefixes.entries)
        if (key.startsWith(item.key) && key.length >= item.key.length + 4)
          '${item.value}（形式线索，需结合释义核对）',
      for (final item in _suffixes.entries)
        if (key.endsWith(item.key) && key.length >= item.key.length + 3)
          '${item.value}（形式线索，需结合释义核对）',
    ];
  }

  static String familyKey(WordEntry entry) {
    if (entry.root.trim().isNotEmpty) return wordKey(entry.root);
    var stem = wordKey(entry.word);
    for (final prefix in _prefixes.keys) {
      if (stem.startsWith(prefix) && stem.length >= prefix.length + 4) {
        stem = stem.substring(prefix.length);
        break;
      }
    }
    for (final suffix in [..._suffixes.keys, 'ing', 'ed', 's']) {
      if (stem.endsWith(suffix) && stem.length >= suffix.length + 3) {
        stem = stem.substring(0, stem.length - suffix.length);
        break;
      }
    }
    return stem;
  }

  static List<WordEntry> family(WordEntry entry, Iterable<WordEntry> entries) =>
      entries
          .where((candidate) => familyKey(candidate) == familyKey(entry))
          .toList();
}

class OfflineDictionary {
  static Future<Map<String, dynamic>>? _loading;
  static Future<Map<String, dynamic>> _load() => _loading ??= rootBundle
      .loadString('assets/dictionary.json')
      .then(
        (text) => Map<String, dynamic>.from(
          (jsonDecode(text) as Map)['entries'] as Map,
        ),
      );

  static Future<ImportPreview> enrich(ImportPreview preview) async {
    final missing = preview.entries.values.where((e) => !e.hasMeaning).toList();
    if (missing.isEmpty) return preview;
    final dict = await _load();
    final entries = {...preview.entries};
    var filled = 0;
    for (final entry in missing) {
      final value = dict[wordKey(entry.word)];
      if (value is! Map) continue;
      final data = entry.toJson();
      data['meaning'] = value['meaning'] as String? ?? '';
      if (entry.uk.isEmpty) data['uk'] = value['uk'] as String? ?? '';
      entries[entry.id] = WordEntry.fromJson(data);
      if (entries[entry.id]!.hasMeaning) filled++;
    }
    final remaining = entries.values.where((e) => !e.hasMeaning).length;
    return ImportPreview(
      book: preview.book,
      entries: entries,
      total: preview.total,
      duplicates: preview.duplicates,
      missingMeanings: remaining,
      missingExamples: preview.missingExamples,
      warnings: [
        ...preview.warnings,
        if (filled > 0) '已用 ECDICT 离线基础词典补充 $filled 个释义（社区内容，请核对）。',
        if (remaining > 0) '$remaining 个词暂缺释义，可浏览与拼写，不能生成选择题。',
      ],
    );
  }
}
