import 'dart:convert';

String wordKey(String word) => word.trim().toLowerCase();

/// Reserved virtual book identity; membership is always derived from notebook.
const notebookBookId = 'wordnest:system:notebook';

WordBook notebookBook(AppSnapshot snapshot) => WordBook(
  id: notebookBookId,
  title: '生词本',
  source: '动态词书 · 与正式错题及手动增删同步',
  importedAt: DateTime.utc(2026),
  members: [
    for (final (index, id) in snapshot.notebook.indexed)
      BookMember(entryId: id, unit: '生词本', position: index),
  ],
);

class WordEntry {
  const WordEntry({
    required this.id,
    required this.word,
    required this.meaning,
    this.uk = '',
    this.us = '',
    this.example = '',
    this.exampleTranslation = '',
    this.explanation = '',
    this.usage = '',
    this.root = '',
    this.synonyms = '',
  });
  final String id,
      word,
      meaning,
      uk,
      us,
      example,
      exampleTranslation,
      explanation,
      usage,
      root,
      synonyms;
  bool get hasMeaning => meaning.trim().isNotEmpty;
  String get coreMeaning => meaning.replaceAll(RegExp(r'\s+'), ' ').trim();
  Map<String, dynamic> toJson() => {
    'id': id,
    'word': word,
    'meaning': meaning,
    'uk': uk,
    'us': us,
    'example': example,
    'exampleTranslation': exampleTranslation,
    'explanation': explanation,
    'usage': usage,
    'root': root,
    'synonyms': synonyms,
  };
  factory WordEntry.fromJson(Map<String, dynamic> j) => WordEntry(
    id: j['id'] as String,
    word: j['word'] as String,
    meaning: j['meaning'] as String? ?? '',
    uk: j['uk'] as String? ?? '',
    us: j['us'] as String? ?? '',
    example: j['example'] as String? ?? '',
    exampleTranslation: j['exampleTranslation'] as String? ?? '',
    explanation: j['explanation'] as String? ?? '',
    usage: j['usage'] as String? ?? '',
    root: j['root'] as String? ?? '',
    synonyms: j['synonyms'] as String? ?? '',
  );
}

class BookMember {
  const BookMember({
    required this.entryId,
    required this.unit,
    required this.position,
  });
  final String entryId, unit;
  final int position;
  Map<String, dynamic> toJson() => {
    'entryId': entryId,
    'unit': unit,
    'position': position,
  };
  factory BookMember.fromJson(Map<String, dynamic> j) => BookMember(
    entryId: j['entryId'] as String,
    unit: j['unit'] as String,
    position: j['position'] as int,
  );
}

class WordBook {
  const WordBook({
    required this.id,
    required this.title,
    required this.members,
    required this.importedAt,
    this.source = '',
  });
  final String id, title, source;
  final DateTime importedAt;
  final List<BookMember> members;
  List<String> get units => members.map((m) => m.unit).toSet().toList();
  List<String> get uniqueIds => members.map((m) => m.entryId).toSet().toList();
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'source': source,
    'importedAt': importedAt.toIso8601String(),
    'members': members.map((m) => m.toJson()).toList(),
  };
  factory WordBook.fromJson(Map<String, dynamic> j) => WordBook(
    id: j['id'] as String,
    title: j['title'] as String,
    source: j['source'] as String? ?? '',
    importedAt: DateTime.parse(j['importedAt'] as String),
    members: (j['members'] as List)
        .map((m) => BookMember.fromJson(Map<String, dynamic>.from(m as Map)))
        .toList(),
  );
}

class ReviewCard {
  const ReviewCard({
    required this.entryId,
    required this.due,
    this.streak = 0,
    this.reviews = 0,
    this.lapses = 0,
    this.seen = false,
  });
  final String entryId;
  final DateTime due;
  final int streak, reviews, lapses;
  final bool seen;
  Map<String, dynamic> toJson() => {
    'entryId': entryId,
    'due': due.toIso8601String(),
    'streak': streak,
    'reviews': reviews,
    'lapses': lapses,
    'seen': seen,
  };
  factory ReviewCard.fromJson(Map<String, dynamic> j) => ReviewCard(
    entryId: j['entryId'] as String,
    due: DateTime.parse(j['due'] as String),
    streak: j['streak'] as int? ?? 0,
    reviews: j['reviews'] as int? ?? 0,
    lapses: j['lapses'] as int? ?? 0,
    seen: j['seen'] as bool? ?? false,
  );
}

class LearningEvent {
  const LearningEvent({
    required this.id,
    required this.entryId,
    required this.kind,
    required this.at,
    this.correct,
    this.action = '',
  });
  final String id, entryId, kind, action;
  final DateTime at;
  final bool? correct;
  Map<String, dynamic> toJson() => {
    'id': id,
    'entryId': entryId,
    'kind': kind,
    'at': at.toIso8601String(),
    'correct': correct,
    'action': action,
  };
  factory LearningEvent.fromJson(Map<String, dynamic> j) => LearningEvent(
    id: j['id'] as String,
    entryId: j['entryId'] as String,
    kind: j['kind'] as String,
    at: DateTime.parse(j['at'] as String),
    correct: j['correct'] as bool?,
    action: j['action'] as String? ?? '',
  );
}

bool isValidBackgroundAsset(String value) =>
    value.isEmpty ||
    RegExp(r'^bg-[0-9a-f]{32}\.(png|jpg|webp)$').stringMatch(value) == value;

int? parseAccentHex(String value) {
  final hex = value.trim().replaceFirst(RegExp(r'^#'), '');
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
  return 0xff000000 | int.parse(hex, radix: 16);
}

class AppSettings {
  AppSettings({
    this.activeBookId = '',
    this.theme = 'dark',
    this.roundSize = 50,
    this.dailyNew = 10,
    this.dailyLimit = 40,
    this.adaptive = true,
    this.showChinese = true,
    this.showPhonetic = true,
    this.showExample = true,
    this.showRoot = true,
    this.showSynonyms = true,
    this.showNotes = true,
    this.optionCount = 4,
    this.autoAdvance = true,
    this.notifications = false,
    this.reminderMinutes = 120,
    this.notificationLimit = 12,
    this.startHour = 9,
    this.endHour = 21,
    this.reviewNotificationChinese = false,
    this.sound = false,
    this.soundPack = 'classic',
    this.closeToTray = true,
    this.widgetSeconds = 30,
    this.widgetAuto = true,
    this.widgetTop = true,
    this.fontScale = 1,
    this.tts = true,
    this.autoTts = false,
    this.typingReveal = true,
    this.globalHotkey = 'Ctrl+Alt+W',
    this.examDate = '',
    this.hotkeyEnabled = false,
    this.learningOrder = 'book',
    this.copyStyle = 'plain',
    this.errorMinutes = 10,
    this.accentArgb = 0xff23775d,
    this.backgroundAsset = '',
    this.materialMode = 'solid',
    this.backgroundOpacity = 1,
    this.surfaceOpacity = 1,
    this.navigationStyle = 'adaptive',
    this.navigationInset = 12,
    this.navigationRadius = 24,
    this.notebookAutoAddErrors = true,
    this.notebookRemoveAfterCorrect = 2,
    this.questionDirection = 'en2zh',
  });
  static const soundPackLabels = {
    'classic': '清脆键盘',
    'soft': '柔和木音',
    'digital': '电子脉冲',
    'mechanical': '机械轻轴',
    'chime': '清亮弹音',
    'click': '轻柔短 click',
  };
  String soundPack;
  String activeBookId, theme, globalHotkey, examDate, learningOrder, copyStyle;
  String backgroundAsset, materialMode, navigationStyle, questionDirection;
  int accentArgb;
  double backgroundOpacity, surfaceOpacity;
  int navigationInset, navigationRadius;
  int roundSize,
      dailyNew,
      dailyLimit,
      optionCount,
      reminderMinutes,
      notificationLimit,
      startHour,
      endHour,
      widgetSeconds,
      errorMinutes,
      notebookRemoveAfterCorrect;
  bool adaptive,
      showChinese,
      showPhonetic,
      showExample,
      showRoot,
      showSynonyms,
      showNotes,
      autoAdvance,
      notifications,
      reviewNotificationChinese,
      sound,
      closeToTray,
      widgetAuto,
      widgetTop,
      tts,
      autoTts,
      typingReveal,
      hotkeyEnabled,
      notebookAutoAddErrors;
  double fontScale;
  Map<String, dynamic> toJson() => {
    'activeBookId': activeBookId,
    'theme': theme,
    'roundSize': roundSize,
    'dailyNew': dailyNew,
    'dailyLimit': dailyLimit,
    'adaptive': adaptive,
    'showChinese': showChinese,
    'showPhonetic': showPhonetic,
    'showExample': showExample,
    'showRoot': showRoot,
    'showSynonyms': showSynonyms,
    'showNotes': showNotes,
    'optionCount': optionCount,
    'autoAdvance': autoAdvance,
    'notifications': notifications,
    'reminderMinutes': reminderMinutes,
    'notificationLimit': notificationLimit,
    'startHour': startHour,
    'endHour': endHour,
    'reviewNotificationChinese': reviewNotificationChinese,
    'sound': sound,
    'soundPack': soundPack,
    'closeToTray': closeToTray,
    'widgetSeconds': widgetSeconds,
    'widgetAuto': widgetAuto,
    'widgetTop': widgetTop,
    'fontScale': fontScale,
    'tts': tts,
    'autoTts': autoTts,
    'typingReveal': typingReveal,
    'globalHotkey': globalHotkey,
    'examDate': examDate,
    'hotkeyEnabled': hotkeyEnabled,
    'learningOrder': learningOrder,
    'copyStyle': copyStyle,
    'errorMinutes': errorMinutes,
    'accentArgb': accentArgb,
    'backgroundAsset': backgroundAsset,
    'materialMode': materialMode,
    'backgroundOpacity': backgroundOpacity,
    'surfaceOpacity': surfaceOpacity,
    'navigationStyle': navigationStyle,
    'navigationInset': navigationInset,
    'navigationRadius': navigationRadius,
    'notebookAutoAddErrors': notebookAutoAddErrors,
    'notebookRemoveAfterCorrect': notebookRemoveAfterCorrect,
    'questionDirection': questionDirection,
  };
  factory AppSettings.fromJson(Map<String, dynamic> j) {
    final s = AppSettings();
    final d = s.toJson()..addAll(j);
    return AppSettings(
      activeBookId: d['activeBookId'] as String,
      theme: d['theme'] as String,
      roundSize: (d['roundSize'] as int).clamp(1, 50),
      dailyNew: (d['dailyNew'] as int).clamp(1, 9007199254740991),
      dailyLimit: (d['dailyLimit'] as int).clamp(1, 500),
      adaptive: d['adaptive'] as bool,
      showChinese: d['showChinese'] as bool,
      showPhonetic: d['showPhonetic'] as bool,
      showExample: d['showExample'] as bool,
      showRoot: d['showRoot'] as bool,
      showSynonyms: d['showSynonyms'] as bool,
      showNotes: d['showNotes'] as bool,
      optionCount: (d['optionCount'] as int).clamp(2, 4),
      autoAdvance: d['autoAdvance'] as bool,
      notifications: d['notifications'] as bool,
      reminderMinutes: (d['reminderMinutes'] as int).clamp(1, 240),
      notificationLimit: (d['notificationLimit'] as int).clamp(1, 100),
      startHour: (d['startHour'] as int).clamp(0, 23),
      endHour: (d['endHour'] as int).clamp(0, 24),
      reviewNotificationChinese: d['reviewNotificationChinese'] as bool,
      sound: d['sound'] as bool,
      soundPack: d['soundPack'] as String,
      closeToTray: d['closeToTray'] as bool,
      widgetSeconds: (d['widgetSeconds'] as int).clamp(5, 300),
      widgetAuto: d['widgetAuto'] as bool,
      widgetTop: d['widgetTop'] as bool,
      fontScale: (d['fontScale'] as num).toDouble().clamp(0.8, 1.5),
      tts: d['tts'] as bool,
      autoTts: d['autoTts'] as bool,
      typingReveal: d['typingReveal'] as bool,
      globalHotkey: d['globalHotkey'] as String,
      examDate: d['examDate'] as String,
      hotkeyEnabled: d['hotkeyEnabled'] as bool,
      learningOrder: d['learningOrder'] as String,
      copyStyle: d['copyStyle'] as String,
      errorMinutes: (d['errorMinutes'] as int).clamp(1, 60),
      accentArgb: d['accentArgb'] as int,
      backgroundAsset: d['backgroundAsset'] as String,
      materialMode: d['materialMode'] as String,
      backgroundOpacity: (d['backgroundOpacity'] as num).toDouble(),
      surfaceOpacity: (d['surfaceOpacity'] as num).toDouble(),
      navigationStyle: d['navigationStyle'] as String,
      navigationInset: (d['navigationInset'] as num).toInt(),
      navigationRadius: (d['navigationRadius'] as num).toInt(),
      notebookAutoAddErrors: d['notebookAutoAddErrors'] as bool,
      notebookRemoveAfterCorrect: (d['notebookRemoveAfterCorrect'] as int)
          .clamp(0, 10),
      questionDirection: d['questionDirection'] as String,
    );
  }
}

class AppSnapshot {
  AppSnapshot({
    List<WordBook>? books,
    Map<String, WordEntry>? entries,
    Map<String, ReviewCard>? cards,
    List<LearningEvent>? events,
    Map<String, String>? notes,
    Set<String>? notebook,
    Map<String, int>? notebookProgress,
    AppSettings? settings,
    Map<String, dynamic>? session,
    Map<String, Map<String, dynamic>>? sessions,
    String? activeSessionMode,
  }) : books = books ?? [],
       entries = entries ?? {},
       cards = cards ?? {},
       events = events ?? [],
       notes = notes ?? {},
       notebook = notebook ?? <String>{},
       notebookProgress = notebookProgress ?? <String, int>{},
       settings = settings ?? AppSettings(),
       sessions = sessions ?? _legacySessions(session),
       activeSessionMode =
           activeSessionMode ??
           (session?['mode'] is String ? session!['mode'] as String : 'quick');
  final List<WordBook> books;
  final Map<String, WordEntry> entries;
  final Map<String, ReviewCard> cards;
  final List<LearningEvent> events;
  final Map<String, String> notes;

  /// 生词本成员；[notebookProgress] 记录每个成员的正式答对连续次数。
  Set<String> notebook;
  Map<String, int> notebookProgress;
  AppSettings settings;

  /// One resumable session per study mode (`quick`, `formal`, `typing`).
  Map<String, Map<String, dynamic>> sessions;

  /// The mode whose session [session] currently exposes.
  String activeSessionMode;

  /// Legacy single-session view of the active mode (read-only usage expected).
  Map<String, dynamic> get session => sessions[activeSessionMode] ?? {};
  Map<String, dynamic> toJson() => {
    'format': 'wordnest-backup',
    'version': 1,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'books': books.map((b) => b.toJson()).toList(),
    'entries': entries.values.map((e) => e.toJson()).toList(),
    'cards': cards.values.map((c) => c.toJson()).toList(),
    'events': events.map((e) => e.toJson()).toList(),
    'notes': notes,
    'notebook': (notebook.toList()..sort()),
    'notebookProgress': {
      for (final id in (notebookProgress.keys.toList()..sort()))
        id: notebookProgress[id]!,
    },
    'settings': settings.toJson(),
    'session': sessions[activeSessionMode] ?? <String, dynamic>{},
    'sessions': sessions,
    'activeSessionMode': activeSessionMode,
  };
  factory AppSnapshot.fromJson(Map<String, dynamic> j) => AppSnapshot(
    books: (j['books'] as List)
        .map((e) => WordBook.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    entries: {
      for (final e in j['entries'] as List)
        (e as Map)['id'] as String: WordEntry.fromJson(
          Map<String, dynamic>.from(e),
        ),
    },
    cards: {
      for (final c in j['cards'] as List)
        (c as Map)['entryId'] as String: ReviewCard.fromJson(
          Map<String, dynamic>.from(c),
        ),
    },
    events: (j['events'] as List)
        .map((e) => LearningEvent.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    notes: Map<String, String>.from(j['notes'] as Map),
    notebook: j['notebook'] is List
        ? (j['notebook'] as List).cast<String>().toSet()
        : <String>{},
    notebookProgress: j['notebookProgress'] is Map
        ? {
            for (final e in (j['notebookProgress'] as Map).entries)
              '${e.key}': e.value as int,
          }
        : <String, int>{},
    settings: AppSettings.fromJson(
      Map<String, dynamic>.from(j['settings'] as Map),
    ),
    session: j['session'] is Map
        ? Map<String, dynamic>.from(j['session'] as Map)
        : null,
    sessions: j['sessions'] is Map
        ? {
            for (final e in (j['sessions'] as Map).entries)
              '${e.key}': Map<String, dynamic>.from(e.value as Map),
          }
        : null,
    activeSessionMode: j['activeSessionMode'] as String?,
  );
  AppSnapshot clone() => AppSnapshot(
    books: [...books],
    entries: {...entries},
    cards: {...cards},
    events: [...events],
    notes: {...notes},
    notebook: {...notebook},
    notebookProgress: {...notebookProgress},
    settings: AppSettings.fromJson(settings.toJson()),
    sessions: {
      for (final e in sessions.entries)
        e.key: Map<String, dynamic>.from(
          jsonDecode(jsonEncode(e.value)) as Map,
        ),
    },
    activeSessionMode: activeSessionMode,
  );
}

Map<String, Map<String, dynamic>> _legacySessions(
  Map<String, dynamic>? session,
) {
  if (session == null || session.isEmpty) return {};
  final mode = session['mode'] is String ? session['mode'] as String : 'quick';
  return {
    mode: {...session, 'mode': mode},
  };
}

class ImportPreview {
  const ImportPreview({
    required this.book,
    required this.entries,
    required this.total,
    required this.duplicates,
    required this.missingMeanings,
    required this.missingExamples,
    this.warnings = const [],
  });
  final WordBook book;
  final Map<String, WordEntry> entries;
  final int total, duplicates, missingMeanings, missingExamples;
  final List<String> warnings;
}
