import 'dart:convert';

import '../domain/models.dart';

/// Parses the import formats supported by WordNest.
class ImportParser {
  static const maxBytes = 20 * 1024 * 1024;
  static const maxRecords = 50000;

  static ImportPreview parse(
    String text,
    String filename, {
    Map<String, int>? csvMapping,
  }) {
    if (utf8.encode(text).length > maxBytes) {
      throw const FormatException('文件过大，导入文件不能超过20MB');
    }
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    final name = _fileName(filename);
    final lower = name.toLowerCase();
    if (lower.endsWith('.json')) {
      return _json(text, name);
    }
    if (lower.endsWith('.csv')) {
      return _csv(text, name, csvMapping);
    }
    return _txt(text, name);
  }

  static String exportCsv(WordBook book, Map<String, WordEntry> entries) {
    const fields = [
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
      'unit',
    ];
    String quote(String text) => '"${text.replaceAll('"', '""')}"';
    final rows = <String>[fields.join(',')];
    for (final member in book.members) {
      final entry = entries[member.entryId];
      if (entry == null) continue;
      final json = entry.toJson();
      rows.add(
        fields
            .map(
              (field) =>
                  quote(field == 'unit' ? member.unit : json[field] as String),
            )
            .join(','),
      );
    }
    return '${rows.join('\r\n')}\r\n';
  }

  static ImportPreview _json(String text, String filename) {
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      throw FormatException('JSON格式错误，无法解析文件：$e');
    }
    final records = <_ImportRecord>[];
    String? title;
    var source = filename;
    try {
      if (decoded is List) {
        title = _titleFromFilename(filename);
        for (var i = 0; i < decoded.length; i++) {
          records.add(_recordFrom(decoded[i], '导入', i + 1));
        }
      } else if (decoded is Map) {
        final root = Map<String, dynamic>.from(decoded);
        title =
            _string(root['book_name']) ??
            _string(root['title']) ??
            _string(root['name']) ??
            _titleFromFilename(filename);
        source = _string(root['source']) ?? filename;
        final chapters = root['chapters'];
        if (chapters is List) {
          for (var ci = 0; ci < chapters.length; ci++) {
            final chapter = chapters[ci];
            if (chapter is! Map) {
              throw FormatException('JSON结构错误：chapters中的第${ci + 1}项不是对象');
            }
            final c = Map<String, dynamic>.from(chapter);
            final unit =
                _string(c['name']) ?? _string(c['title']) ?? '单元${ci + 1}';
            final words = c['words'] ?? c['entries'] ?? c['items'];
            if (words is! List) {
              throw FormatException('JSON结构错误：第${ci + 1}个章节缺少words数组');
            }
            for (var wi = 0; wi < words.length; wi++) {
              records.add(_recordFrom(words[wi], unit, records.length + 1));
            }
          }
        } else {
          final list =
              root['words'] ?? root['entries'] ?? root['items'] ?? root['data'];
          if (list is! List) {
            throw const FormatException('JSON结构错误：需要数组，或包含chapters/words数组的对象');
          }
          for (var i = 0; i < list.length; i++) {
            records.add(_recordFrom(list[i], '导入', i + 1));
          }
        }
      } else {
        throw const FormatException('JSON结构错误：顶层必须是数组或对象');
      }
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('JSON结构错误：$e');
    }
    if (records.isEmpty) throw const FormatException('JSON中没有可导入的记录');
    return _preview(records, title, source);
  }

  static ImportPreview _txt(String text, String filename) {
    final records = <_ImportRecord>[];
    final lines = text.split(RegExp(r'\r?\n'));
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trimRight();
      if (line.trim().isEmpty) continue;
      final parts = line.split('\t');
      final word = parts.first.trim();
      if (word.isEmpty) throw FormatException('第${i + 1}行单词为空');
      records.add(
        _ImportRecord(
          word: word,
          meaning: parts.length > 1 ? parts[1].trim() : '',
          example: parts.length > 2 ? parts[2].trim() : '',
          unit: '导入',
          position: records.length + 1,
        ),
      );
      _checkCount(records.length);
    }
    if (records.isEmpty) throw const FormatException('文本中没有可导入的单词');
    return _preview(records, _titleFromFilename(filename), filename);
  }

  static ImportPreview _csv(
    String text,
    String filename,
    Map<String, int>? supplied,
  ) {
    final rows = _parseCsv(text);
    if (rows.isEmpty) throw const FormatException('CSV文件为空');
    final suppliedMapping = <String, int>{};
    supplied?.forEach((key, value) {
      final canonical = _canonical(key);
      final field =
          _csvAlias(canonical) ??
          (const [
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
                'unit',
              ].contains(key)
              ? key
              : null);
      if (field != null) suppliedMapping[field] = value;
    });
    var mapping = Map<String, int>.from(suppliedMapping);
    var start = 0;
    if (mapping.isNotEmpty && rows.length > 1) {
      final first = rows.first.map(_canonical).toList();
      if (first.any((column) => _csvAlias(column) != null)) start = 1;
    }
    if (mapping.isEmpty) {
      final header = rows.first.map(_canonical).toList();
      for (var i = 0; i < header.length; i++) {
        final field = _csvAlias(header[i]);
        if (field != null) mapping[field] = i;
      }
      if (mapping.containsKey('word')) start = 1;
    }
    if (!mapping.containsKey('word')) {
      if (suppliedMapping.isEmpty && rows.first.isNotEmpty) {
        mapping['word'] = 0;
      } else {
        throw const FormatException('CSV缺少单词列，请提供word列或csvMapping映射');
      }
    }
    final records = <_ImportRecord>[];
    for (var ri = start; ri < rows.length; ri++) {
      final row = rows[ri];
      String value(String key) {
        final index = mapping[key];
        return index == null || index < 0 || index >= row.length
            ? ''
            : row[index].trim();
      }

      final word = value('word');
      if (word.isEmpty) throw FormatException('CSV第${ri + 1}行单词为空');
      records.add(
        _ImportRecord(
          word: word,
          meaning: value('meaning'),
          uk: value('uk'),
          us: value('us'),
          example: value('example'),
          exampleTranslation: value('exampleTranslation'),
          explanation: value('explanation'),
          usage: value('usage'),
          root: value('root'),
          synonyms: value('synonyms'),
          unit: value('unit').isEmpty ? '导入' : value('unit'),
          position: records.length + 1,
        ),
      );
      _checkCount(records.length);
    }
    if (records.isEmpty) throw const FormatException('CSV中没有可导入的记录');
    return _preview(records, _titleFromFilename(filename), filename);
  }

  static List<List<String>> _parseCsv(String text) {
    final rows = <List<String>>[];
    var row = <String>[];
    var field = StringBuffer();
    var quoted = false;
    var i = 0;
    void finishField() {
      row.add(field.toString());
      field = StringBuffer();
    }

    void finishRow() {
      finishField();
      if (row.length > 1 || row.any((x) => x.isNotEmpty)) rows.add(row);
      row = <String>[];
    }

    while (i < text.length) {
      final ch = text[i];
      if (quoted) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i += 2;
            continue;
          }
          quoted = false;
        } else {
          field.write(ch);
        }
      } else if (ch == '"' && field.length == 0) {
        quoted = true;
      } else if (ch == ',') {
        finishField();
      } else if (ch == '\n' || ch == '\r') {
        if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        finishRow();
      } else {
        field.write(ch);
      }
      i++;
    }
    if (quoted) throw const FormatException('CSV格式错误：引号没有闭合');
    if (field.isNotEmpty || row.isNotEmpty) finishRow();
    return rows;
  }

  static _ImportRecord _recordFrom(dynamic value, String unit, int position) {
    if (value is String) {
      if (value.trim().isEmpty) throw FormatException('$unit第$position项单词为空');
      return _ImportRecord(word: value.trim(), unit: unit, position: position);
    }
    if (value is! Map) throw FormatException('$unit第$position项不是对象');
    final m = Map<String, dynamic>.from(value);
    String field(List<String> keys) {
      for (final key in keys) {
        final value = m[key];
        final result = _string(value);
        if (result != null) return result;
      }
      return '';
    }

    final word = field(['word', 'w', 'term', 'english', 'en_word']);
    if (word.trim().isEmpty) throw FormatException('$unit第$position项缺少单词');
    final recordUnit = field(['unit', 'chapter', 'section']);
    return _ImportRecord(
      word: word.trim(),
      meaning: field(['meaning', 'translation', 'tr', 'cn', 'definition']),
      uk: field(['uk', 'phoneticUk']),
      us: field(['us', 'phoneticUs']),
      example: field(['example', 'ex']),
      exampleTranslation: field(['exampleTranslation', 'ex_cn']),
      explanation: field(['explanation', 'en']),
      usage: field(['usage']),
      root: field(['root']),
      synonyms: field(['synonyms', 'synonym']),
      unit: recordUnit.trim().isEmpty ? unit : recordUnit.trim(),
      position: position,
    );
  }

  static ImportPreview _preview(
    List<_ImportRecord> records,
    String title,
    String source,
  ) {
    _checkCount(records.length);
    final entries = <String, WordEntry>{};
    final members = <BookMember>[];
    var duplicates = 0;
    var missingMeanings = 0;
    var missingExamples = 0;
    final seenInBook = <String>{};
    for (final record in records) {
      final id = wordKey(record.word);
      if (id.isEmpty) throw const FormatException('存在空单词');
      if (seenInBook.contains(id)) duplicates++;
      seenInBook.add(id);
      final existing = entries[id];
      if (existing == null) {
        entries[id] = WordEntry(
          id: id,
          word: record.word,
          meaning: record.meaning,
          uk: record.uk,
          us: record.us,
          example: record.example,
          exampleTranslation: record.exampleTranslation,
          explanation: record.explanation,
          usage: record.usage,
          root: record.root,
          synonyms: record.synonyms,
        );
      } else {
        // Keep the first occurrence's canonical text, but fill fields omitted by later duplicates.
        entries[id] = WordEntry(
          id: id,
          word: existing.word,
          meaning: existing.meaning.isEmpty ? record.meaning : existing.meaning,
          uk: existing.uk.isEmpty ? record.uk : existing.uk,
          us: existing.us.isEmpty ? record.us : existing.us,
          example: existing.example.isEmpty ? record.example : existing.example,
          exampleTranslation: existing.exampleTranslation.isEmpty
              ? record.exampleTranslation
              : existing.exampleTranslation,
          explanation: existing.explanation.isEmpty
              ? record.explanation
              : existing.explanation,
          usage: existing.usage.isEmpty ? record.usage : existing.usage,
          root: existing.root.isEmpty ? record.root : existing.root,
          synonyms: existing.synonyms.isEmpty
              ? record.synonyms
              : existing.synonyms,
        );
      }
      if (record.meaning.trim().isEmpty) missingMeanings++;
      if (record.example.trim().isEmpty) missingExamples++;
      members.add(
        BookMember(entryId: id, unit: record.unit, position: record.position),
      );
    }
    final now = DateTime.now().toUtc();
    final id =
        'book-${_hash('$source\u0000$title\u0000${now.microsecondsSinceEpoch}')}';
    final book = WordBook(
      id: id,
      title: title.trim().isEmpty ? '未命名词书' : title.trim(),
      source: source,
      importedAt: now,
      members: members,
    );
    final warnings = <String>[];
    if (duplicates > 0) warnings.add('发现$duplicates条重复单词，已保留词书中的重复位置');
    if (missingMeanings > 0) warnings.add('$missingMeanings条记录缺少释义');
    if (missingExamples > 0) warnings.add('$missingExamples条记录缺少例句');
    return ImportPreview(
      book: book,
      entries: entries,
      total: records.length,
      duplicates: duplicates,
      missingMeanings: missingMeanings,
      missingExamples: missingExamples,
      warnings: warnings,
    );
  }

  static String? _string(dynamic value) => value == null
      ? null
      : value is String
      ? value
      : value is num || value is bool
      ? '$value'
      : null;
  static String _fileName(String value) => value.split(RegExp(r'[\\/]')).last;
  static String _titleFromFilename(String value) {
    final n = _fileName(value);
    return n.replaceFirst(RegExp(r'\.[^.]+$'), '').trim();
  }

  static String _canonical(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'[ _-]+'), '');
  static String? _csvAlias(String value) {
    const aliases = <String, List<String>>{
      'word': ['word', 'w', 'term', 'english', '单词', '英文', '词汇'],
      'meaning': [
        'meaning',
        'translation',
        'definition',
        'tr',
        'cn',
        '释义',
        '中文',
        '意思',
      ],
      'uk': ['uk', 'britishphonetic', '英音'],
      'us': ['us', 'americanphonetic', '美音'],
      'example': ['example', 'sentence', 'ex', '例句'],
      'exampleTranslation': ['exampletranslation', 'excn', '例句翻译'],
      'explanation': ['explanation', 'en', '说明'],
      'usage': ['usage', '用法'],
      'root': ['root', '词根'],
      'synonyms': ['synonyms', 'synonym', '同义词'],
      'unit': ['unit', 'chapter', 'section', '单元', '章节'],
    };
    for (final entry in aliases.entries) {
      if (entry.value.contains(value)) return entry.key;
    }
    return null;
  }

  static void _checkCount(int count) {
    if (count > maxRecords) throw const FormatException('记录过多，单次最多导入50000条');
  }

  static String _hash(String value) {
    var hash = 0xcbf29ce484222325;
    for (final code in utf8.encode(value)) {
      hash ^= code;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return hash.toRadixString(16);
  }
}

class _ImportRecord {
  const _ImportRecord({
    required this.word,
    required this.unit,
    required this.position,
    this.meaning = '',
    this.uk = '',
    this.us = '',
    this.example = '',
    this.exampleTranslation = '',
    this.explanation = '',
    this.usage = '',
    this.root = '',
    this.synonyms = '',
  });
  final String word,
      meaning,
      uk,
      us,
      example,
      exampleTranslation,
      explanation,
      usage,
      root,
      synonyms,
      unit;
  final int position;
}
