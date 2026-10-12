import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../domain/models.dart';

abstract class AppStorage {
  Future<AppSnapshot> load();
  Future<void> replace(AppSnapshot snapshot);
  Future<void> commitLearning(
    ReviewCard card,
    LearningEvent event, {
    Map<String, Map<String, dynamic>>? sessions,
    String? activeSessionMode,
    Set<String>? notebook,
    Map<String, int>? notebookProgress,
  });
  Future<void> saveSettings(AppSettings settings);
  Future<void> saveNotebook(Set<String> ids, Map<String, int> progress);
  Future<void> saveSessions(
    Map<String, Map<String, dynamic>> sessions, {
    required String activeSessionMode,
  });
  Future<void> saveNote(String entryId, String text);
  Future<void> importBook(ImportPreview preview);
  Future<void> deleteBook(String id);
  Future<void> dispose();
}

AppSnapshot normalizePortableAppearance(AppSnapshot snapshot) {
  final portable = snapshot.clone();
  portable.settings.backgroundAsset = '';
  return portable;
}

/// JSON backup codec shared by database replacement, export, and restore.
class BackupCodec {
  static const format = 'wordnest-backup';
  static const version = 1;
  static const maxBytes = 50 * 1024 * 1024;
  static const maxBooks = 10000;
  static const maxEntries = 50000;
  static const maxEvents = 500000;

  static String encode(AppSnapshot snapshot) {
    _validate(snapshot);
    try {
      final text = jsonEncode(snapshot.toJson());
      if (utf8.encode(text).length > maxBytes) {
        throw const FormatException('备份过大，不能超过50MB');
      }
      return text;
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('备份编码失败：$e');
    }
  }

  static AppSnapshot decode(String text) {
    if (utf8.encode(text).length > maxBytes) {
      throw const FormatException('备份过大，不能超过50MB');
    }
    dynamic raw;
    try {
      raw = jsonDecode(text);
    } catch (e) {
      throw FormatException('备份JSON解析失败：$e');
    }
    if (raw is! Map) throw const FormatException('备份格式错误：顶层必须是对象');
    final json = Map<String, dynamic>.from(raw);
    _validateKeys(
      json,
      {
        'format',
        'version',
        'exportedAt',
        'books',
        'entries',
        'cards',
        'events',
        'notes',
        'notebook',
        'notebookProgress',
        'settings',
        'session',
        'sessions',
        'activeSessionMode',
      },
      'backup',
      required: {
        'format',
        'version',
        'books',
        'entries',
        'cards',
        'events',
        'notes',
        'settings',
      },
    );
    if (json['format'] != format) {
      throw const FormatException('备份格式错误：format不匹配');
    }
    final v = json['version'];
    if (v is! int) throw const FormatException('备份格式错误：缺少version');
    if (v > version) throw FormatException('不支持的备份版本：$v');
    if (v < 1) throw FormatException('不支持的备份版本：$v');
    json['settings'] = migrateSettings(
      _expectMap(json['settings'], 'settings'),
    );
    // Legacy backups predate the notebook; only absent keys are coerced.
    if (!json.containsKey('notebook')) json['notebook'] = <String>[];
    if (!json.containsKey('notebookProgress')) {
      json['notebookProgress'] = <String, dynamic>{};
    }
    migrateSessions(json);
    _validateRawLists(json);
    try {
      final snapshot = AppSnapshot.fromJson(json);
      _validate(snapshot);
      return snapshot;
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('备份内容错误：$e');
    }
  }

  /// Fill only absent legacy fields; malformed present values remain errors.
  static Map<String, dynamic> migrateSettings(Map<String, dynamic> settings) =>
      {...AppSettings().toJson(), ...settings};

  static const modes = ['quick', 'formal', 'typing'];

  /// Normalize legacy single-session backups into per-mode sessions.
  ///
  /// Writes `sessions`, `activeSessionMode` and a mirrored `session` field so
  /// the legacy shape keeps working for readers.
  static Map<String, dynamic> migrateSessions(Map<String, dynamic> json) {
    final sessions = <String, Map<String, dynamic>>{};
    final raw = json['sessions'];
    if (raw is Map) {
      for (final entry in raw.entries) {
        if (entry.value is Map) {
          sessions['${entry.key}'] = migrateSession(
            Map<String, dynamic>.from(entry.value as Map),
          );
        }
      }
    }
    final legacy = json['session'];
    if (sessions.isEmpty && legacy is Map && legacy.isNotEmpty) {
      final session = migrateSession(Map<String, dynamic>.from(legacy));
      final mode = session['mode'] is String
          ? session['mode'] as String
          : 'quick';
      sessions[mode] = session;
    }
    for (final entry in sessions.entries) {
      entry.value['mode'] ??= entry.key;
    }
    var active = json['activeSessionMode'];
    if (active is! String || !sessions.containsKey(active)) {
      active = legacy is Map && legacy['mode'] is String
          ? legacy['mode'] as String
          : sessions.keys.firstOrNull ?? 'quick';
    }
    json['sessions'] = sessions;
    json['activeSessionMode'] = active;
    // A legacy map kept alongside sessions stays untouched so mirror
    // consistency is still validated; otherwise publish the active session.
    final keepMirror =
        legacy is Map && legacy.isNotEmpty && raw is Map && raw.isNotEmpty;
    final malformedLegacy = legacy != null && legacy is! Map;
    if (!keepMirror && !malformedLegacy) {
      json['session'] = sessions[active] ?? <String, dynamic>{};
    }
    return json;
  }

  static Map<String, dynamic> migrateSession(Map<String, dynamic> session) {
    final next = _deepMap(session);
    if (next.isEmpty) return next;
    if (!next.containsKey('history') &&
        (next['result'] != null || next['typingResult'] != null)) {
      final history = <String, dynamic>{};
      for (final field in ['result', 'typingResult']) {
        final result = next[field];
        if (result is Map && result['index'] is int) {
          final key = '${result['index']}';
          final question = history[key] as Map<String, dynamic>? ?? {};
          question[field] = result;
          history[key] = question;
        }
      }
      next['history'] = history;
    }
    return next;
  }

  static void _validateRawLists(Map<String, dynamic> json) {
    final books = _rawList(json, 'books', maxBooks);
    final entries = _rawList(json, 'entries', maxEntries);
    final cards = _rawList(json, 'cards', maxEntries);
    final events = _rawList(json, 'events', maxEvents);
    final notes = _expectMap(json['notes'], 'notes');
    final settings = _expectMap(json['settings'], 'settings');
    _validateRawBooks(books);
    final entryIds = _validateRawEntries(entries);
    _validateRawCards(cards);
    _validateRawEvents(events);
    for (final entry in notes.entries) {
      if (entry.value is! String) {
        throw const FormatException('备份内容错误：notes必须是字符串到字符串的映射');
      }
    }
    _validateRawNotebook(json['notebook'], entryIds);
    _validateRawNotebookProgress(json['notebookProgress'], entryIds);
    _validateRawSettings(settings);
    _validateRawSessions(json);
  }

  /// Serialized stored form of the notebook; sorted so rows are deterministic.
  static Map<String, dynamic> _notebookPayload(
    Set<String> ids,
    Map<String, int> progress,
  ) => {
    'ids': (ids.toList()..sort()),
    'progress': {
      for (final id in (progress.keys.toList()..sort())) id: progress[id]!,
    },
  };

  /// Strict notebook member list: strings, no duplicates, existing entries.
  static void _validateRawNotebook(dynamic value, Set<String> entries) {
    if (value is! List) {
      throw const FormatException('备份内容错误：notebook必须是数组');
    }
    if (value.length > maxEntries) {
      throw const FormatException('备份内容错误：notebook数量超过限制');
    }
    final ids = <String>{};
    for (final item in value) {
      if (item is! String || item.trim().isEmpty || !ids.add(item)) {
        throw const FormatException('备份内容错误：notebook包含重复或无效的单词ID');
      }
      if (!entries.contains(item)) {
        throw FormatException('备份内容错误：notebook引用了不存在的单词$item');
      }
    }
  }

  /// Strict per-word consecutive-correct counters for notebook members.
  static void _validateRawNotebookProgress(dynamic value, Set<String> entries) {
    if (value is! Map) {
      throw const FormatException('备份内容错误：notebookProgress必须是对象');
    }
    if (value.length > maxEntries) {
      throw const FormatException('备份内容错误：notebookProgress数量超过限制');
    }
    for (final item in value.entries) {
      final id = item.key;
      if (id is! String || id.trim().isEmpty || !entries.contains(id)) {
        throw const FormatException('备份内容错误：notebookProgress引用了不存在的单词');
      }
      final count = item.value;
      if (count is! int || count < 0) {
        throw const FormatException('备份内容错误：notebookProgress计数无效');
      }
    }
  }

  /// One JSON settings row holding the whole notebook state.
  static void _validateRawNotebookState(
    Map<String, dynamic> state,
    Set<String> entries,
  ) {
    _validateKeys(
      state,
      {'ids', 'progress'},
      'notebook',
      required: {'ids', 'progress'},
    );
    _validateRawNotebook(state['ids'], entries);
    _validateRawNotebookProgress(state['progress'], entries);
  }

  static void _validateRawSessions(Map<String, dynamic> json) {
    final sessions = _expectMap(json['sessions'], 'sessions');
    final active = json['activeSessionMode'];
    if (active is! String || !modes.contains(active)) {
      throw const FormatException('备份内容错误：activeSessionMode无效');
    }
    final mirror = _expectMap(json['session'], 'session');
    for (final entry in sessions.entries) {
      if (!modes.contains(entry.key)) {
        throw const FormatException('备份内容错误：未知的session模式');
      }
      final session = _expectMap(entry.value, 'session');
      if (session['mode'] != entry.key) {
        throw const FormatException('备份内容错误：session模式与键不匹配');
      }
      _validateRawSession(session);
    }
    if (!_sameJson(mirror, sessions[active] ?? <String, dynamic>{})) {
      throw const FormatException('备份内容错误：session镜像与sessions不一致');
    }
  }

  static bool _sameJson(dynamic a, dynamic b) {
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key) || !_sameJson(a[key], b[key])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_sameJson(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  static void _validateRawBooks(List<dynamic> books) {
    final ids = <String>{};
    for (final value in books) {
      final item = _expectMap(value, 'book');
      _validateKeys(
        item,
        {'id', 'title', 'source', 'importedAt', 'members'},
        'book',
        required: {'id', 'title', 'source', 'importedAt', 'members'},
      );
      final id = _expectString(item, 'id', 'book');
      if (id.trim().isEmpty || !ids.add(id)) {
        throw const FormatException('备份内容错误：词书ID重复或无效');
      }
      _expectString(item, 'title', 'book');
      _expectString(item, 'source', 'book');
      _expectDate(item, 'importedAt', 'book');
      final members = _rawList(item, 'members', maxEntries);
      final positions = <int>{};
      for (final memberValue in members) {
        final member = _expectMap(memberValue, 'book member');
        _validateKeys(
          member,
          {'entryId', 'unit', 'position'},
          'book member',
          required: {'entryId', 'unit', 'position'},
        );
        _expectString(member, 'entryId', 'book member');
        _expectString(member, 'unit', 'book member');
        final position = _expectInt(member, 'position', 'book member');
        if (position < 0 || !positions.add(position)) {
          throw const FormatException('备份内容错误：词书成员位置重复或无效');
        }
      }
    }
  }

  static Set<String> _validateRawEntries(List<dynamic> entries) {
    final ids = <String>{};
    const fields = [
      'id',
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
    ];
    for (final value in entries) {
      final item = _expectMap(value, 'entry');
      _validateKeys(item, fields.toSet(), 'entry', required: fields.toSet());
      final id = _expectString(item, 'id', 'entry');
      if (id.trim().isEmpty || !ids.add(id)) {
        throw const FormatException('备份内容错误：单词ID重复或无效');
      }
      for (final field in fields.skip(1)) {
        _expectString(item, field, 'entry');
      }
      if (_expectString(item, 'word', 'entry').trim().isEmpty) {
        throw const FormatException('备份内容错误：存在空单词');
      }
    }
    return ids;
  }

  static void _validateRawCards(List<dynamic> cards) {
    final ids = <String>{};
    for (final value in cards) {
      final item = _expectMap(value, 'card');
      _validateKeys(
        item,
        {'entryId', 'due', 'streak', 'reviews', 'lapses', 'seen'},
        'card',
        required: {'entryId', 'due', 'streak', 'reviews', 'lapses', 'seen'},
      );
      final entryId = _expectString(item, 'entryId', 'card');
      if (entryId.trim().isEmpty || !ids.add(entryId)) {
        throw const FormatException('备份内容错误：卡片ID重复或无效');
      }
      _expectDate(item, 'due', 'card');
      for (final field in ['streak', 'reviews', 'lapses']) {
        if (_expectInt(item, field, 'card') < 0) {
          throw FormatException('备份内容错误：card.$field不能为负数');
        }
      }
      _expectBool(item, 'seen', 'card');
    }
  }

  static void _validateRawEvents(List<dynamic> events) {
    final ids = <String>{};
    for (final value in events) {
      final item = _expectMap(value, 'event');
      _validateKeys(
        item,
        {'id', 'entryId', 'kind', 'at', 'correct', 'action'},
        'event',
        required: {'id', 'entryId', 'kind', 'at', 'correct', 'action'},
      );
      final id = _expectString(item, 'id', 'event');
      if (id.trim().isEmpty || !ids.add(id)) {
        throw const FormatException('备份内容错误：学习事件ID重复或无效');
      }
      _expectString(item, 'entryId', 'event');
      _expectString(item, 'kind', 'event');
      _expectDate(item, 'at', 'event');
      final correct = item['correct'];
      if (correct != null && correct is! bool) {
        throw const FormatException('备份内容错误：event.correct类型无效');
      }
      _expectString(item, 'action', 'event');
    }
  }

  static void _validateRawSettings(Map<String, dynamic> settings) {
    const strings = [
      'activeBookId',
      'theme',
      'globalHotkey',
      'examDate',
      'learningOrder',
      'copyStyle',
      'backgroundAsset',
      'materialMode',
      'navigationStyle',
      'questionDirection',
    ];
    const ints = [
      'roundSize',
      'dailyNew',
      'dailyLimit',
      'optionCount',
      'reminderMinutes',
      'notificationLimit',
      'navigationInset',
      'navigationRadius',
      'startHour',
      'endHour',
      'widgetSeconds',
      'errorMinutes',
      'notebookRemoveAfterCorrect',
    ];
    const bools = [
      'adaptive',
      'showChinese',
      'showPhonetic',
      'showExample',
      'showRoot',
      'showSynonyms',
      'showNotes',
      'autoAdvance',
      'notifications',
      'reviewNotificationChinese',
      'sound',
      'closeToTray',
      'widgetAuto',
      'widgetTop',
      'tts',
      'autoTts',
      'typingReveal',
      'hotkeyEnabled',
      'notebookAutoAddErrors',
    ];
    final expected = {
      ...strings,
      ...ints,
      ...bools,
      'fontScale',
      'accentArgb',
      'backgroundOpacity',
      'surfaceOpacity',
    };
    _validateKeys(settings, expected, 'settings', required: expected);
    if (settings.length != expected.length) {
      throw const FormatException('备份内容错误：settings包含缺失或未知字段');
    }
    for (final field in strings) {
      _expectString(settings, field, 'settings');
    }
    for (final field in bools) {
      _expectBool(settings, field, 'settings');
    }
    for (final field in ints) {
      final value = _expectInt(settings, field, 'settings');
      final valid = switch (field) {
        'roundSize' => value >= 1 && value <= 50,
        // Daily plan target, not a quota. Keep JSON integers exact on web too.
        'dailyNew' => value >= 1 && value <= 9007199254740991,
        'dailyLimit' => value >= 1 && value <= 500,
        'optionCount' => value >= 2 && value <= 4,
        'reminderMinutes' => value >= 1 && value <= 240,
        'notificationLimit' => value >= 1 && value <= 100,
        'startHour' => value >= 0 && value <= 23,
        'endHour' => value >= 0 && value <= 24,
        'widgetSeconds' => value >= 5 && value <= 300,
        'errorMinutes' => value >= 1 && value <= 60,
        'notebookRemoveAfterCorrect' => value >= 0 && value <= 10,
        'navigationInset' => value >= 0 && value <= 48,
        'navigationRadius' => value >= 0 && value <= 48,
        _ => false,
      };
      if (!valid) throw FormatException('备份内容错误：settings.$field超出范围');
    }
    final accent = _expectInt(settings, 'accentArgb', 'settings');
    if (accent < 0xff000000 || accent > 0xffffffff) {
      throw const FormatException('备份内容错误：settings.accentArgb必须是不透明颜色');
    }
    if (!isValidBackgroundAsset(settings['backgroundAsset'] as String)) {
      throw const FormatException('备份内容错误：settings.backgroundAsset无效');
    }
    for (final field in ['backgroundOpacity', 'surfaceOpacity']) {
      final value = settings[field];
      final min = field == 'surfaceOpacity' ? .2 : 0;
      if (value is! num || !value.isFinite || value < min || value > 1) {
        throw FormatException('备份内容错误：settings.$field无效');
      }
    }
    if (!['solid', 'glass'].contains(settings['materialMode']) ||
        !['adaptive', 'floating'].contains(settings['navigationStyle'])) {
      throw const FormatException('备份内容错误：settings外观枚举值无效');
    }
    final fontScale = settings['fontScale'];
    if (fontScale is! num ||
        !fontScale.isFinite ||
        fontScale < .8 ||
        fontScale > 1.5) {
      throw const FormatException('备份内容错误：settings.fontScale无效');
    }
    if (!['plain', 'cute'].contains(settings['copyStyle']) ||
        !['light', 'dark', 'system'].contains(settings['theme']) ||
        !['en2zh', 'zh2en'].contains(settings['questionDirection']) ||
        ![
          'book',
          'reverse',
          'alphabet',
          'random',
          'weak',
          'root',
        ].contains(settings['learningOrder'])) {
      throw const FormatException('备份内容错误：settings枚举值无效');
    }
    if ((settings['examDate'] as String).isNotEmpty) {
      _expectDate(settings, 'examDate', 'settings');
    }
  }

  static bool validHistoryIndex(int? index, dynamic ids) =>
      index != null && ids is List && index >= 0 && index < ids.length;

  static void _validateRawSession(Map<String, dynamic> session) {
    if (session.isEmpty) return;
    final mode = session['mode'];
    if (mode != null &&
        (mode is! String || !['quick', 'formal', 'typing'].contains(mode))) {
      throw const FormatException('备份内容错误：session.mode无效');
    }
    final ids = session['ids'];
    if (ids != null) {
      if (ids is! List || ids.any((id) => id is! String)) {
        throw const FormatException('备份内容错误：session.ids无效');
      }
    }
    final index = session['index'];
    if (index != null &&
        (index is! int || index < 0 || ids is! List || index > ids.length)) {
      throw const FormatException('备份内容错误：session.index无效');
    }
    if (mode != null && (ids is! List || index is! int)) {
      throw const FormatException('备份内容错误：session缺少ids或index');
    }
    final historyValue = session['history'];
    if (historyValue != null) {
      final history = _expectMap(historyValue, 'session.history');
      for (final item in history.entries) {
        final questionIndex = int.tryParse(item.key);
        if (!validHistoryIndex(questionIndex, ids) ||
            '$questionIndex' != item.key) {
          throw const FormatException('session.history index无效');
        }
        final question = _expectMap(item.value, 'history question');
        _validateKeys(question, {
          'entryId',
          'mode',
          'options',
          'labels',
          'optionLabels',
          'correctIndex',
          'answered',
          'result',
          'typingResult',
          'quickResult',
        }, 'history question');
        if (question.containsKey('entryId') &&
            question['entryId'] != (ids as List)[questionIndex!]) {
          throw const FormatException('session.history entryId无效');
        }
        if (question.containsKey('mode') &&
            !['quick', 'formal', 'typing'].contains(question['mode'])) {
          throw const FormatException('session.history mode无效');
        }
        if (question.containsKey('answered')) {
          _expectBool(question, 'answered', 'history');
        }
        final options = question['options'];
        if (options != null &&
            (options is! List ||
                options.length > 4 ||
                options.any((x) => x is! String))) {
          throw const FormatException('session.history options无效');
        }
        for (final alias in ['optionLabels', 'labels']) {
          final labels = question[alias];
          if (labels != null &&
              (labels is! List ||
                  options is! List ||
                  labels.length != options.length ||
                  labels.any((x) => x is! String))) {
            throw const FormatException('session.history labels无效');
          }
        }
        final correctIndex = question['correctIndex'];
        if (correctIndex != null &&
            (correctIndex is! int ||
                options is! List ||
                correctIndex < 0 ||
                correctIndex >= options.length)) {
          throw const FormatException('session.history correctIndex无效');
        }
        for (final field in ['result', 'typingResult']) {
          if (question[field] == null) continue;
          final result = _expectMap(question[field], 'history.$field');
          if (result['index'] != questionIndex) {
            throw const FormatException('history result index无效');
          }
          _expectBool(result, 'correct', 'history.$field');
          if (field == 'result') {
            final selected = _expectInt(result, 'selected', 'history.result');
            if (selected < 0 ||
                selected > 3 ||
                (options is List && selected >= options.length)) {
              throw const FormatException('history selected无效');
            }
          } else {
            _expectString(result, 'input', 'history.typingResult');
          }
        }
        if (question['quickResult'] != null) {
          _expectBool(
            _expectMap(question['quickResult'], 'history.quickResult'),
            'familiar',
            'history.quickResult',
          );
        }
      }
    }
    final bookId = session['bookId'];
    if (bookId != null && bookId is! String) {
      throw const FormatException('备份内容错误：session.bookId无效');
    }
    final startedAt = session['startedAt'];
    if (startedAt != null) {
      _expectDate(session, 'startedAt', 'session');
    }
    bool validResultIndex(dynamic value) =>
        value is int && value >= 0 && ids is List && value < ids.length;
    final verificationIndex = session['verificationIndex'];
    if (verificationIndex != null && !validResultIndex(verificationIndex)) {
      throw const FormatException('备份内容错误：session.verificationIndex无效');
    }
    for (final field in ['result', 'typingResult']) {
      final value = session[field];
      if (value == null) continue;
      final result = _expectMap(value, 'session.$field');
      if (!validResultIndex(result['index'])) {
        throw FormatException('备份内容错误：session.$field.index无效');
      }
      _expectBool(result, 'correct', 'session.$field');
      if (field == 'result') {
        final selected = _expectInt(result, 'selected', 'session.result');
        if (selected < 0 || selected > 3) {
          throw const FormatException('备份内容错误：session.result.selected无效');
        }
      } else {
        _expectString(result, 'input', 'session.typingResult');
      }
    }
  }

  static void _validateKeys(
    Map<String, dynamic> value,
    Set<String> allowed,
    String label, {
    Set<String> required = const <String>{},
  }) {
    if (!value.keys.every((key) => allowed.contains(key)) ||
        !required.every(value.containsKey)) {
      throw FormatException('备份内容错误：$label包含缺失或未知字段');
    }
  }

  static Map<String, dynamic> _expectMap(dynamic value, String label) {
    if (value is! Map) throw FormatException('备份内容错误：$label必须是对象');
    return Map<String, dynamic>.from(value);
  }

  static String _expectString(
    Map<String, dynamic> value,
    String key,
    String label,
  ) {
    final item = value[key];
    if (item is! String) throw FormatException('备份内容错误：$label.$key必须是字符串');
    return item;
  }

  static int _expectInt(Map<String, dynamic> value, String key, String label) {
    final item = value[key];
    if (item is! int) throw FormatException('备份内容错误：$label.$key必须是整数');
    return item;
  }

  static bool _expectBool(
    Map<String, dynamic> value,
    String key,
    String label,
  ) {
    final item = value[key];
    if (item is! bool) throw FormatException('备份内容错误：$label.$key必须是布尔值');
    return item;
  }

  static DateTime _expectDate(
    Map<String, dynamic> value,
    String key,
    String label,
  ) {
    final text = _expectString(value, key, label);
    try {
      return DateTime.parse(text);
    } catch (e) {
      throw FormatException('备份内容错误：$label.$key不是有效日期');
    }
  }

  static List<dynamic> _rawList(
    Map<String, dynamic> json,
    String key,
    int max,
  ) {
    final value = json[key];
    if (value is! List) throw FormatException('备份内容错误：$key必须是数组');
    if (value.length > max) throw FormatException('备份内容错误：$key数量超过限制');
    return value;
  }

  static void _validate(AppSnapshot snapshot) {
    _validateRawSettings(snapshot.settings.toJson());
    _validateRawCards(
      snapshot.cards.values.map((card) => card.toJson()).toList(),
    );
    _validateRawEvents(snapshot.events.map((event) => event.toJson()).toList());
    if (snapshot.entries.entries.any((item) => item.key != item.value.id) ||
        snapshot.cards.entries.any((item) => item.key != item.value.entryId)) {
      throw const FormatException('备份内容错误：映射键与条目ID不匹配');
    }
    if (snapshot.books.length > maxBooks) {
      throw const FormatException('备份包含的词书过多');
    }
    if (snapshot.entries.length > maxEntries) {
      throw const FormatException('备份包含的单词过多');
    }
    if (snapshot.events.length > maxEvents) {
      throw const FormatException('备份包含的学习事件过多');
    }
    final bookIds = <String>{};
    for (final book in snapshot.books) {
      if (book.id == notebookBookId ||
          book.id.trim().isEmpty ||
          !bookIds.add(book.id)) {
        throw const FormatException('备份内容错误：词书ID重复或为空');
      }
      final positions = <int>{};
      for (final member in book.members) {
        if (!snapshot.entries.containsKey(member.entryId)) {
          throw FormatException(
            '备份内容错误：词书${book.id}引用了不存在的单词${member.entryId}',
          );
        }
        if (member.unit.trim().isEmpty ||
            member.position < 0 ||
            !positions.add(member.position)) {
          throw FormatException('备份内容错误：词书${book.id}的成员位置重复或无效');
        }
      }
    }
    final entryIds = <String>{};
    for (final entry in snapshot.entries.values) {
      if (entry.id.trim().isEmpty || !entryIds.add(entry.id)) {
        throw FormatException('备份内容错误：单词ID无效或重复（${entry.id}）');
      }
      if (entry.word.trim().isEmpty) {
        throw const FormatException('备份内容错误：存在空单词');
      }
    }
    final cardIds = <String>{};
    for (final card in snapshot.cards.values) {
      if (!snapshot.entries.containsKey(card.entryId) ||
          !cardIds.add(card.entryId)) {
        throw FormatException('备份内容错误：卡片引用无效或重复（${card.entryId}）');
      }
    }
    final eventIds = <String>{};
    for (final event in snapshot.events) {
      if (event.id.trim().isEmpty || !eventIds.add(event.id)) {
        throw const FormatException('备份内容错误：学习事件ID重复或为空');
      }
      if (!snapshot.entries.containsKey(event.entryId)) {
        throw FormatException('备份内容错误：事件引用了不存在的单词${event.entryId}');
      }
    }
    for (final key in snapshot.notes.keys) {
      if (!snapshot.entries.containsKey(key)) {
        throw FormatException('备份内容错误：笔记引用了不存在的单词$key');
      }
    }
    _validateRawNotebook(snapshot.notebook.toList(), entryIds);
    _validateRawNotebookProgress(snapshot.notebookProgress, entryIds);
    bookIds.add(notebookBookId);
    final active = snapshot.settings.activeBookId;
    if (active.isNotEmpty && !bookIds.contains(active)) {
      throw FormatException('备份内容错误：当前词书不存在（$active）');
    }
    _validateSessions(
      snapshot.sessions,
      snapshot.activeSessionMode,
      entryIds,
      bookIds,
    );
  }

  static void _validateSessions(
    Map<String, Map<String, dynamic>> sessions,
    String active,
    Set<String> entries,
    Set<String> books,
  ) {
    if (!modes.contains(active)) {
      throw const FormatException('备份内容错误：activeSessionMode无效');
    }
    for (final entry in sessions.entries) {
      final session = entry.value;
      if (!modes.contains(entry.key) || session['mode'] != entry.key) {
        throw const FormatException('备份内容错误：session模式与键不匹配');
      }
      _validateRawSession(session);
      _validateSession(session, entries, books);
      _validateJsonValue(session, 'session');
    }
  }

  static void _validateSession(
    Map<String, dynamic> session,
    Set<String> entries,
    Set<String> books,
  ) {
    if (session.length > 100) throw const FormatException('备份内容错误：session字段过多');
    final ids = session['ids'];
    if (ids != null) {
      if (ids is! List ||
          ids.length > maxEntries ||
          ids.any((x) => x is! String || !entries.contains(x))) {
        throw const FormatException('备份内容错误：session.ids无效');
      }
      final index = session['index'];
      if (index != null && (index is! int || index < 0 || index > ids.length)) {
        throw const FormatException('备份内容错误：session.index无效');
      }
    }
    final history = session['history'];
    if (history is Map) {
      for (final question in history.values) {
        if (question is Map &&
            question['options'] is List &&
            (question['options'] as List).any((id) => !entries.contains(id))) {
          throw const FormatException('history options引用无效');
        }
      }
    }
    final bookId = session['bookId'];
    if (bookId != null && bookId is! String) {
      throw const FormatException('备份内容错误：session.bookId无效');
    }
    if (bookId is String && bookId.isNotEmpty && !books.contains(bookId)) {
      throw FormatException('备份内容错误：session引用了不存在的词书$bookId');
    }
  }

  static void _validateJsonValue(dynamic value, String label, [int depth = 0]) {
    if (depth > 12) throw FormatException('备份内容错误：$label嵌套过深');
    if (value == null || value is String || value is num || value is bool) {
      return;
    }
    if (value is List) {
      if (value.length > maxEntries) throw FormatException('备份内容错误：$label数组过大');
      for (final item in value) {
        _validateJsonValue(item, label, depth + 1);
      }
      return;
    }
    if (value is Map) {
      if (value.length > 10000) throw FormatException('备份内容错误：$label对象过大');
      for (final entry in value.entries) {
        if (entry.key is! String) throw FormatException('备份内容错误：$label键名无效');
        _validateJsonValue(entry.value, label, depth + 1);
      }
      return;
    }
    throw FormatException('备份内容错误：$label包含不可序列化值');
  }
}

class MemoryStorage implements AppStorage {
  MemoryStorage([AppSnapshot? initial])
    : _snapshot = initial?.clone() ?? AppSnapshot();
  AppSnapshot _snapshot;
  bool _closed = false;

  void _ensureOpen() {
    if (_closed) throw StateError('存储已关闭');
  }

  @override
  Future<AppSnapshot> load() async {
    _ensureOpen();
    return _snapshot.clone();
  }

  @override
  Future<void> replace(AppSnapshot snapshot) async {
    _ensureOpen();
    final encoded = BackupCodec.encode(snapshot);
    _snapshot = BackupCodec.decode(encoded);
  }

  @override
  Future<void> commitLearning(
    ReviewCard card,
    LearningEvent event, {
    Map<String, Map<String, dynamic>>? sessions,
    String? activeSessionMode,
    Set<String>? notebook,
    Map<String, int>? notebookProgress,
  }) async {
    _ensureOpen();
    if (!_snapshot.entries.containsKey(event.entryId) ||
        card.entryId != event.entryId) {
      throw FormatException('学习记录引用了不存在的单词：${event.entryId}');
    }
    if (_snapshot.events.any((e) => e.id == event.id)) return;
    final next = _snapshot.clone();
    if (event.kind != 'notification_requested' &&
        event.kind != 'notification_verified_request') {
      next.cards[card.entryId] = card;
    }
    next.events.add(event);
    if (sessions != null) {
      next.sessions = _deepSessions(sessions);
      if (activeSessionMode != null) next.activeSessionMode = activeSessionMode;
    }
    if (notebook != null) next.notebook = {...notebook};
    if (notebookProgress != null) {
      next.notebookProgress = {...notebookProgress};
    }
    BackupCodec._validate(next);
    _snapshot = next;
  }

  @override
  Future<void> saveNotebook(Set<String> ids, Map<String, int> progress) async {
    _ensureOpen();
    final next = _snapshot.clone();
    next.notebook = {...ids};
    next.notebookProgress = {...progress};
    BackupCodec._validate(next);
    _snapshot = next;
  }

  @override
  Future<void> saveSettings(AppSettings settings) async {
    _ensureOpen();
    final next = _snapshot.clone();
    BackupCodec._validateRawSettings(settings.toJson());
    next.settings = AppSettings.fromJson(settings.toJson());
    BackupCodec._validate(next);
    _snapshot = next;
  }

  @override
  Future<void> saveSessions(
    Map<String, Map<String, dynamic>> sessions, {
    required String activeSessionMode,
  }) async {
    _ensureOpen();
    final next = _snapshot.clone();
    next.sessions = _deepSessions(sessions);
    next.activeSessionMode = activeSessionMode;
    BackupCodec._validate(next);
    _snapshot = next;
  }

  @override
  Future<void> saveNote(String entryId, String text) async {
    _ensureOpen();
    if (!_snapshot.entries.containsKey(entryId)) {
      throw FormatException('笔记引用了不存在的单词：$entryId');
    }
    final next = _snapshot.clone();
    if (text.isEmpty) {
      next.notes.remove(entryId);
    } else {
      next.notes[entryId] = text;
    }
    _snapshot = next;
  }

  @override
  Future<void> importBook(ImportPreview preview) async {
    _ensureOpen();
    if (preview.book.id.trim().isEmpty) throw const FormatException('词书ID为空');
    final next = _snapshot.clone();
    final existingBookIndex = next.books.indexWhere(
      (b) => b.id == preview.book.id,
    );
    if (existingBookIndex >= 0) next.books.removeAt(existingBookIndex);
    for (final incoming in preview.entries.values) {
      final old = next.entries[incoming.id];
      next.entries[incoming.id] = old == null
          ? incoming
          : _mergeEntry(old, incoming);
    }
    next.books.add(preview.book);
    next.settings.activeBookId = preview.book.id;
    BackupCodec._validate(next);
    _snapshot = next;
  }

  @override
  Future<void> deleteBook(String id) async {
    _ensureOpen();
    final next = _snapshot.clone();
    if (id == notebookBookId) throw const FormatException('生词本不可删除');
    next.books.removeWhere((b) => b.id == id);
    // Deleting the last reference never destroys global learning data.
    if (next.settings.activeBookId == id) {
      next.settings.activeBookId = next.books.firstOrNull?.id ?? '';
    }
    next.sessions.removeWhere((mode, session) => session['bookId'] == id);
    if (!next.sessions.containsKey(next.activeSessionMode)) {
      next.activeSessionMode = next.sessions.keys.firstOrNull ?? 'quick';
    }
    BackupCodec._validate(next);
    _snapshot = next;
  }

  @override
  Future<void> dispose() async {
    _closed = true;
  }
}

class SqliteStorage implements AppStorage {
  SqliteStorage._(this._db);
  final Database _db;
  bool _closed = false;

  static Future<SqliteStorage> open({String? databasePath}) async {
    final path = databasePath ?? await _defaultPath();
    Database db;
    final options = OpenDatabaseOptions(
      version: 1,
      onConfigure: _configure,
      onCreate: _createSchema,
      onUpgrade: _upgradeSchema,
    );
    if (Platform.isWindows) {
      sqfliteFfiInit();
      db = await databaseFactoryFfi.openDatabase(path, options: options);
    } else {
      db = await sqflite.openDatabase(path, options: options);
    }
    return SqliteStorage._(db);
  }

  static Future<String> _defaultPath() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return p.join(directory.path, 'wordnest.sqlite');
  }

  static Future<void> _configure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
    final rows = await db.rawQuery('PRAGMA user_version');
    final value = rows.isEmpty ? 0 : rows.first.values.first;
    final version = value is int ? value : int.tryParse('$value') ?? 0;
    if (version > BackupCodec.version) {
      throw StateError('数据库版本过新：$version');
    }
  }

  static Future<void> _createSchema(DatabaseExecutor db, int version) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS books (id TEXT PRIMARY KEY, title TEXT NOT NULL, source TEXT NOT NULL, imported_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS entries (id TEXT PRIMARY KEY, payload TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS book_members (book_id TEXT NOT NULL, entry_id TEXT NOT NULL, unit TEXT NOT NULL, position INTEGER NOT NULL, PRIMARY KEY(book_id, position), FOREIGN KEY(book_id) REFERENCES books(id) ON DELETE CASCADE, FOREIGN KEY(entry_id) REFERENCES entries(id))',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS cards (entry_id TEXT PRIMARY KEY, payload TEXT NOT NULL, FOREIGN KEY(entry_id) REFERENCES entries(id))',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS review_events (id TEXT PRIMARY KEY, entry_id TEXT NOT NULL, payload TEXT NOT NULL, FOREIGN KEY(entry_id) REFERENCES entries(id))',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS notification_events (id TEXT PRIMARY KEY, entry_id TEXT NOT NULL, payload TEXT NOT NULL, FOREIGN KEY(entry_id) REFERENCES entries(id))',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS user_notes (entry_id TEXT PRIMARY KEY, note TEXT NOT NULL, FOREIGN KEY(entry_id) REFERENCES entries(id))',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, payload TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await db.insert('schema_meta', {
      'key': 'format',
      'value': BackupCodec.format,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.insert('schema_meta', {
      'key': 'version',
      'value': '${BackupCodec.version}',
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion > BackupCodec.version) {
      throw StateError('数据库版本过新：$oldVersion');
    }
    await _createSchema(db, newVersion);
  }

  void _ensureOpen() {
    if (_closed) throw StateError('存储已关闭');
  }

  @override
  Future<AppSnapshot> load() async {
    _ensureOpen();
    return _db.transaction(_load);
  }

  Future<AppSnapshot> _load(DatabaseExecutor db) async {
    try {
      final meta = await db.query('schema_meta');
      final metaValues = <String, String>{
        for (final row in meta) row['key']! as String: row['value']! as String,
      };
      if (metaValues['format'] != null &&
          metaValues['format'] != BackupCodec.format) {
        throw const FormatException('数据库格式不受支持');
      }
      final dbVersion = int.tryParse(
        metaValues['version'] ?? '${BackupCodec.version}',
      );
      if (dbVersion == null || dbVersion > BackupCodec.version) {
        throw FormatException('数据库版本过新：${metaValues['version']}');
      }
      final booksRows = await db.query('books', orderBy: 'imported_at, id');
      final memberRows = await db.query(
        'book_members',
        orderBy: 'book_id, position',
      );
      final members = <String, List<BookMember>>{};
      for (final row in memberRows) {
        final bookId = row['book_id']! as String;
        (members[bookId] ??= []).add(
          BookMember(
            entryId: row['entry_id']! as String,
            unit: row['unit']! as String,
            position: row['position']! as int,
          ),
        );
      }
      final books = booksRows
          .map(
            (row) => WordBook(
              id: row['id']! as String,
              title: row['title']! as String,
              source: row['source']! as String,
              importedAt: DateTime.parse(row['imported_at']! as String),
              members: members[row['id']! as String] ?? const <BookMember>[],
            ),
          )
          .toList();
      final entries = <String, WordEntry>{};
      for (final row in await db.query('entries')) {
        final item = _decodeMap(row['payload']! as String, 'entry');
        BackupCodec._validateRawEntries([item]);
        final entry = WordEntry.fromJson(item);
        if (entry.id != row['id'] || entries.containsKey(entry.id)) {
          throw const FormatException('数据库单词ID与内容不匹配');
        }
        entries[entry.id] = entry;
      }
      final cards = <String, ReviewCard>{};
      for (final row in await db.query('cards')) {
        final item = _decodeMap(row['payload']! as String, 'card');
        BackupCodec._validateRawCards([item]);
        final card = ReviewCard.fromJson(item);
        if (card.entryId != row['entry_id'] ||
            cards.containsKey(card.entryId)) {
          throw const FormatException('数据库卡片ID与内容不匹配');
        }
        cards[card.entryId] = card;
      }
      final events = <LearningEvent>[];
      for (final table in ['review_events', 'notification_events']) {
        for (final row in await db.query(table)) {
          final item = _decodeMap(row['payload']! as String, 'event');
          BackupCodec._validateRawEvents([item]);
          final event = LearningEvent.fromJson(item);
          if (event.id != row['id'] || event.entryId != row['entry_id']) {
            throw const FormatException('数据库事件ID与内容不匹配');
          }
          events.add(event);
        }
      }
      events.sort((a, b) => a.at.compareTo(b.at));
      final notes = <String, String>{};
      for (final row in await db.query('user_notes')) {
        notes[row['entry_id']! as String] = row['note']! as String;
      }
      var settings = AppSettings();
      Map<String, dynamic>? legacySession;
      Map<String, dynamic>? sessionState;
      Map<String, dynamic>? notebookState;
      final settingRows = await db.query('settings');
      for (final row in settingRows) {
        final payload = _decodeMap(row['payload']! as String, 'settings');
        if (row['key'] == 'app') {
          final migrated = BackupCodec.migrateSettings(payload);
          BackupCodec._validateRawSettings(migrated);
          settings = AppSettings.fromJson(migrated);
        }
        if (row['key'] == 'session') legacySession = payload;
        if (row['key'] == 'sessions') sessionState = payload;
        if (row['key'] == 'notebook') notebookState = payload;
      }
      final stored = <String, dynamic>{
        ...?sessionState,
        'session': ?legacySession,
      };
      BackupCodec.migrateSessions(stored);
      // A legacy database has no notebook row; it loads as an empty notebook.
      final notebook = <String>{};
      final notebookProgress = <String, int>{};
      if (notebookState != null) {
        BackupCodec._validateRawNotebookState(
          notebookState,
          entries.keys.toSet(),
        );
        notebook.addAll((notebookState['ids'] as List).cast<String>());
        notebookProgress.addAll({
          for (final item in (notebookState['progress'] as Map).entries)
            '${item.key}': item.value as int,
        });
      }
      final snapshot = AppSnapshot(
        books: books,
        entries: entries,
        cards: cards,
        events: events,
        notes: notes,
        notebook: notebook,
        notebookProgress: notebookProgress,
        settings: settings,
        sessions: (stored['sessions'] as Map)
            .cast<String, Map<String, dynamic>>(),
        activeSessionMode: stored['activeSessionMode'] as String,
      );
      BackupCodec._validate(snapshot);
      return snapshot;
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('读取本地数据库失败：$e');
    }
  }

  @override
  Future<void> replace(AppSnapshot snapshot) async {
    _ensureOpen();
    final encoded = BackupCodec.encode(snapshot);
    final checked = BackupCodec.decode(encoded);
    await _db.transaction((txn) async {
      await _clear(txn);
      await _insertSnapshot(txn, checked);
    });
  }

  @override
  Future<void> commitLearning(
    ReviewCard card,
    LearningEvent event, {
    Map<String, Map<String, dynamic>>? sessions,
    String? activeSessionMode,
    Set<String>? notebook,
    Map<String, int>? notebookProgress,
  }) async {
    _ensureOpen();
    await _db.transaction((txn) async {
      final inReviews = await txn.query(
        'review_events',
        where: 'id = ?',
        whereArgs: [event.id],
        limit: 1,
      );
      final inNotifications = await txn.query(
        'notification_events',
        where: 'id = ?',
        whereArgs: [event.id],
        limit: 1,
      );
      if (inReviews.isNotEmpty || inNotifications.isNotEmpty) return;
      final entry = await txn.query(
        'entries',
        where: 'id = ?',
        whereArgs: [event.entryId],
        limit: 1,
      );
      if (entry.isEmpty || card.entryId != event.entryId) {
        throw FormatException('学习记录引用了不存在的单词：${event.entryId}');
      }
      BackupCodec._validateRawCards([card.toJson()]);
      BackupCodec._validateRawEvents([event.toJson()]);
      if (event.kind != 'notification_requested' &&
          event.kind != 'notification_verified_request') {
        await txn.insert('cards', {
          'entry_id': card.entryId,
          'payload': jsonEncode(card.toJson()),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      final table =
          event.kind == 'notification_requested' ||
              event.kind == 'notification_verified_request'
          ? 'notification_events'
          : 'review_events';
      await txn.insert(table, {
        'id': event.id,
        'entry_id': event.entryId,
        'payload': jsonEncode(event.toJson()),
      });
      if (sessions != null) {
        await _writeSessions(txn, sessions, activeSessionMode ?? 'quick');
      }
      if (notebook != null || notebookProgress != null) {
        final stored = await _readNotebook(txn);
        await _writeNotebook(
          txn,
          notebook ?? stored.$1,
          notebookProgress ?? stored.$2,
        );
      }
    });
  }

  /// Stored notebook state; an absent row means an empty notebook.
  static Future<(Set<String>, Map<String, int>)> _readNotebook(
    DatabaseExecutor db,
  ) async {
    final rows = await db.query(
      'settings',
      where: 'key = ?',
      whereArgs: ['notebook'],
      limit: 1,
    );
    if (rows.isEmpty) return (<String>{}, <String, int>{});
    final state = _decodeMap(rows.single['payload']! as String, 'notebook');
    final entryIds = (await db.query(
      'entries',
      columns: ['id'],
    )).map((row) => row['id']! as String).toSet();
    BackupCodec._validateRawNotebookState(state, entryIds);
    return (
      (state['ids'] as List).cast<String>().toSet(),
      {
        for (final item in (state['progress'] as Map).entries)
          '${item.key}': item.value as int,
      },
    );
  }

  static Future<void> _writeNotebook(
    DatabaseExecutor db,
    Set<String> ids,
    Map<String, int> progress,
  ) async {
    final entryIds = (await db.query(
      'entries',
      columns: ['id'],
    )).map((row) => row['id']! as String).toSet();
    BackupCodec._validateRawNotebook(ids.toList(), entryIds);
    BackupCodec._validateRawNotebookProgress(progress, entryIds);
    await db.insert('settings', {
      'key': 'notebook',
      'payload': jsonEncode(BackupCodec._notebookPayload(ids, progress)),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> saveNotebook(Set<String> ids, Map<String, int> progress) async {
    _ensureOpen();
    await _db.transaction((txn) async {
      await _writeNotebook(txn, ids, progress);
    });
  }

  @override
  Future<void> saveSettings(AppSettings settings) async {
    _ensureOpen();
    BackupCodec._validateRawSettings(settings.toJson());
    await _db.transaction((txn) async {
      final current = await _load(txn);
      current.settings = settings;
      BackupCodec._validate(current);
      await txn.insert('settings', {
        'key': 'app',
        'payload': jsonEncode(settings.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  @override
  Future<void> saveSessions(
    Map<String, Map<String, dynamic>> sessions, {
    required String activeSessionMode,
  }) async {
    _ensureOpen();
    await _db.transaction((txn) async {
      await _writeSessions(txn, sessions, activeSessionMode);
    });
  }

  static Future<void> _writeSessions(
    DatabaseExecutor db,
    Map<String, Map<String, dynamic>> sessions,
    String activeSessionMode,
  ) async {
    await _validateStoredSessions(db, sessions, activeSessionMode);
    await db.delete('settings', where: 'key = ?', whereArgs: ['session']);
    await db.insert('settings', {
      'key': 'sessions',
      'payload': jsonEncode({
        'activeSessionMode': activeSessionMode,
        'sessions': sessions,
      }),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _validateStoredSessions(
    DatabaseExecutor db,
    Map<String, Map<String, dynamic>> sessions,
    String activeSessionMode,
  ) async {
    if (!BackupCodec.modes.contains(activeSessionMode)) {
      throw const FormatException('会话模式无效');
    }
    final entries = (await db.query(
      'entries',
      columns: ['id'],
    )).map((row) => row['id']! as String).toSet();
    final books = (await db.query(
      'books',
      columns: ['id'],
    )).map((row) => row['id']! as String).toSet()..add(notebookBookId);
    for (final entry in sessions.entries) {
      if (!BackupCodec.modes.contains(entry.key) ||
          entry.value['mode'] != entry.key) {
        throw const FormatException('会话模式与键不匹配');
      }
      BackupCodec._validateRawSession(entry.value);
      BackupCodec._validateJsonValue(entry.value, 'session');
      BackupCodec._validateSession(entry.value, entries, books);
    }
  }

  @override
  Future<void> saveNote(String entryId, String text) async {
    _ensureOpen();
    await _db.transaction((txn) async {
      final entry = await txn.query(
        'entries',
        where: 'id = ?',
        whereArgs: [entryId],
        limit: 1,
      );
      if (entry.isEmpty) throw FormatException('笔记引用了不存在的单词：$entryId');
      if (text.isEmpty) {
        await txn.delete(
          'user_notes',
          where: 'entry_id = ?',
          whereArgs: [entryId],
        );
      } else {
        await txn.insert('user_notes', {
          'entry_id': entryId,
          'note': text,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  @override
  Future<void> importBook(ImportPreview preview) async {
    _ensureOpen();
    await _db.transaction((txn) async {
      final memory = MemoryStorage(await _load(txn));
      try {
        await memory.importBook(preview);
        final next = await memory.load();
        BackupCodec._validate(next);
        await _clear(txn);
        await _insertSnapshot(txn, next);
      } finally {
        await memory.dispose();
      }
    });
  }

  @override
  Future<void> deleteBook(String id) async {
    _ensureOpen();
    await _db.transaction((txn) async {
      final memory = MemoryStorage(await _load(txn));
      try {
        await memory.deleteBook(id);
        final next = await memory.load();
        BackupCodec._validate(next);
        await _clear(txn);
        await _insertSnapshot(txn, next);
      } finally {
        await memory.dispose();
      }
    });
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    await _db.close();
  }

  static Future<void> _clear(DatabaseExecutor db) async {
    for (final table in [
      'book_members',
      'review_events',
      'notification_events',
      'cards',
      'user_notes',
      'books',
      'entries',
      'settings',
    ]) {
      await db.delete(table);
    }
  }

  static Future<void> _insertSnapshot(
    DatabaseExecutor db,
    AppSnapshot snapshot,
  ) async {
    final entriesBatch = db.batch();
    for (final entry in snapshot.entries.values) {
      entriesBatch.insert('entries', {
        'id': entry.id,
        'payload': jsonEncode(entry.toJson()),
      });
    }
    await entriesBatch.commit(noResult: true);

    final booksBatch = db.batch();
    for (final book in snapshot.books) {
      booksBatch.insert('books', {
        'id': book.id,
        'title': book.title,
        'source': book.source,
        'imported_at': book.importedAt.toIso8601String(),
      });
    }
    await booksBatch.commit(noResult: true);

    final membersBatch = db.batch();
    for (final book in snapshot.books) {
      for (final member in book.members) {
        membersBatch.insert('book_members', {
          'book_id': book.id,
          'entry_id': member.entryId,
          'unit': member.unit,
          'position': member.position,
        });
      }
    }
    await membersBatch.commit(noResult: true);

    final cardsBatch = db.batch();
    for (final card in snapshot.cards.values) {
      cardsBatch.insert('cards', {
        'entry_id': card.entryId,
        'payload': jsonEncode(card.toJson()),
      });
    }
    await cardsBatch.commit(noResult: true);

    final reviewsBatch = db.batch();
    final notificationsBatch = db.batch();
    for (final event in snapshot.events) {
      final batch =
          event.kind == 'notification_requested' ||
              event.kind == 'notification_verified_request'
          ? notificationsBatch
          : reviewsBatch;
      batch.insert(
        event.kind == 'notification_requested' ||
                event.kind == 'notification_verified_request'
            ? 'notification_events'
            : 'review_events',
        {
          'id': event.id,
          'entry_id': event.entryId,
          'payload': jsonEncode(event.toJson()),
        },
      );
    }
    await reviewsBatch.commit(noResult: true);
    await notificationsBatch.commit(noResult: true);

    final notesBatch = db.batch();
    for (final note in snapshot.notes.entries) {
      notesBatch.insert('user_notes', {
        'entry_id': note.key,
        'note': note.value,
      });
    }
    await notesBatch.commit(noResult: true);

    await db.insert('settings', {
      'key': 'notebook',
      'payload': jsonEncode(
        BackupCodec._notebookPayload(
          snapshot.notebook,
          snapshot.notebookProgress,
        ),
      ),
    });
    await db.insert('settings', {
      'key': 'app',
      'payload': jsonEncode(snapshot.settings.toJson()),
    });
    await db.insert('settings', {
      'key': 'sessions',
      'payload': jsonEncode({
        'activeSessionMode': snapshot.activeSessionMode,
        'sessions': snapshot.sessions,
      }),
    });
    await db.insert('schema_meta', {
      'key': 'format',
      'value': BackupCodec.format,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert('schema_meta', {
      'key': 'version',
      'value': '${BackupCodec.version}',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Map<String, dynamic> _decodeMap(String value, String what) {
    try {
      final raw = jsonDecode(value);
      if (raw is! Map) throw const FormatException('不是对象');
      return Map<String, dynamic>.from(raw);
    } catch (e) {
      throw FormatException('数据库中的$what数据损坏：$e');
    }
  }
}

WordEntry _mergeEntry(WordEntry old, WordEntry incoming) => WordEntry(
  id: old.id,
  word: old.word,
  meaning: old.meaning.isNotEmpty ? old.meaning : incoming.meaning,
  uk: old.uk.isNotEmpty ? old.uk : incoming.uk,
  us: old.us.isNotEmpty ? old.us : incoming.us,
  example: old.example.isNotEmpty ? old.example : incoming.example,
  exampleTranslation: old.exampleTranslation.isNotEmpty
      ? old.exampleTranslation
      : incoming.exampleTranslation,
  explanation: old.explanation.isNotEmpty
      ? old.explanation
      : incoming.explanation,
  usage: old.usage.isNotEmpty ? old.usage : incoming.usage,
  root: old.root.isNotEmpty ? old.root : incoming.root,
  synonyms: old.synonyms.isNotEmpty ? old.synonyms : incoming.synonyms,
);

Map<String, Map<String, dynamic>> _deepSessions(
  Map<String, Map<String, dynamic>> value,
) => {for (final entry in value.entries) entry.key: _deepMap(entry.value)};

Map<String, dynamic> _deepMap(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
