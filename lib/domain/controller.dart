import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/storage.dart';
import '../data/offline_dictionary.dart';
import 'exam_plan.dart';
import 'models.dart';
import 'scheduler.dart';

class AppController extends ChangeNotifier {
  AppController(this.storage, {ReviewScheduler? scheduler})
    : scheduler = scheduler ?? IntervalScheduler();
  final AppStorage storage;
  final ReviewScheduler scheduler;
  AppSnapshot state = AppSnapshot();
  String? error;
  bool ready = false, saving = false;
  Future<void> _pending = Future.value();
  AppSettings get settings => state.settings;
  List<WordBook> get libraryBooks => [...state.books, notebookBook(state)];
  WordBook? get book => settings.activeBookId == notebookBookId
      ? notebookBook(state)
      : state.books.where((b) => b.id == settings.activeBookId).firstOrNull ??
            state.books.firstOrNull;

  List<WordBook> groupsFor(String entryId) =>
      libraryBooks.where((b) => b.uniqueIds.contains(entryId)).toList();

  String _bookTitle(String title, {String? exceptId}) {
    final name = title.trim();
    if (name.isEmpty || name.length > 100) {
      throw const FormatException('词书名称需为 1–100 个字符');
    }
    if (libraryBooks.any((b) => b.id != exceptId && b.title == name)) {
      throw const FormatException('已有同名词书，请使用其他名称');
    }
    return name;
  }

  Future<bool> _editBooks(void Function(AppSnapshot) edit) => _write(() async {
    final next = state.clone();
    edit(next);
    await storage.replace(next);
    state = next;
  });

  Future<bool> createBook(String title) => _editBooks((next) {
    final name = _bookTitle(title);
    final id = 'custom-${eventId()}';
    next.books.add(
      WordBook(
        id: id,
        title: name,
        members: const [],
        importedAt: now,
        source: '自建词书',
      ),
    );
    next.settings.activeBookId = id;
  });

  Future<bool> renameBook(String id, String title) => _editBooks((next) {
    if (id == notebookBookId) throw const FormatException('生词本名称固定');
    final index = next.books.indexWhere((b) => b.id == id);
    if (index < 0) throw const FormatException('词书不存在');
    final old = next.books[index];
    next.books[index] = WordBook(
      id: id,
      title: _bookTitle(title, exceptId: id),
      members: old.members,
      importedAt: old.importedAt,
      source: old.source,
    );
  });

  void _membership(AppSnapshot next, String entryId, String bookId, bool add) {
    if (!next.entries.containsKey(entryId)) {
      throw const FormatException('单词不存在');
    }
    if (bookId == notebookBookId) {
      if (add == next.notebook.contains(entryId)) return;
      add ? next.notebook.add(entryId) : next.notebook.remove(entryId);
      next.notebookProgress.remove(entryId);
      return;
    }
    final index = next.books.indexWhere((b) => b.id == bookId);
    if (index < 0) throw const FormatException('词书不存在');
    final old = next.books[index];
    final members = [...old.members];
    if (add) {
      if (old.uniqueIds.contains(entryId)) return;
      final position = members.fold<int>(-1, (v, m) => max(v, m.position)) + 1;
      members.add(
        BookMember(entryId: entryId, unit: '自选词条', position: position),
      );
    } else {
      members.removeWhere((m) => m.entryId == entryId);
    }
    next.books[index] = WordBook(
      id: old.id,
      title: old.title,
      members: members,
      importedAt: old.importedAt,
      source: old.source,
    );
  }

  /// Copy shares the global entry/card; move removes only the source relation.
  Future<bool> copyWord(String entryId, String targetBookId) =>
      _editBooks((next) => _membership(next, entryId, targetBookId, true));

  Future<bool> moveWord(
    String entryId,
    String sourceBookId,
    String targetBookId,
  ) => _editBooks((next) {
    if (!groupsFor(entryId).any((b) => b.id == sourceBookId)) {
      throw const FormatException('单词不在来源词书中');
    }
    _membership(next, entryId, targetBookId, true);
    if (sourceBookId != targetBookId) {
      _membership(next, entryId, sourceBookId, false);
    }
  });

  /// No memberships is allowed: the global word, notes and history survive.
  Future<bool> setWordGroups(String entryId, Set<String> bookIds) =>
      _editBooks((next) {
        for (final id in bookIds) {
          _membership(next, entryId, id, true);
        }
        for (final b in libraryBooks) {
          if (!bookIds.contains(b.id)) _membership(next, entryId, b.id, false);
        }
      });
  List<WordEntry> get words => (book?.uniqueIds ?? [])
      .map((id) => state.entries[id])
      .whereType<WordEntry>()
      .toList();
  DateTime get now => DateTime.now();
  bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
  List<LearningEvent> get today =>
      state.events.where((e) => sameDay(e.at.toLocal(), now)).toList();
  int get formalToday => today.where((e) => e.kind == 'formal').length;
  int get workloadToday =>
      today.where((e) => ['formal', 'view', 'self'].contains(e.kind)).length;
  int get correctToday =>
      today.where((e) => e.kind == 'formal' && e.correct == true).length;
  int get seenToday => today
      .where((e) => e.kind == 'view' || e.kind == 'self')
      .map((e) => e.entryId)
      .toSet()
      .length;
  int get overdue => words.where((e) {
    final c = state.cards[e.id];
    return c != null && c.seen && !c.due.isAfter(now);
  }).length;
  int get remaining =>
      words.where((e) => !(state.cards[e.id]?.seen ?? false)).length;
  ExamPlan get examPlan => ExamPlan.compute(settings.examDate, remaining, now);
  int get stable =>
      words.where((e) => (state.cards[e.id]?.streak ?? 0) >= 3).length;
  int get daysActive => state.events
      .where((e) => ['view', 'self', 'formal'].contains(e.kind))
      .map(
        (e) =>
            '${e.at.toLocal().year}-${e.at.toLocal().month}-${e.at.toLocal().day}',
      )
      .toSet()
      .length;
  // Compatibility getter: no daily or adaptive learning quota remains.
  int get effectiveNew => remaining;

  ReviewCard card(String id) =>
      state.cards[id] ?? ReviewCard(entryId: id, due: now);
  String eventId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}';

  /// Per-mode sessions, keyed by study mode.
  Map<String, Map<String, dynamic>> get sessions => state.sessions;

  /// The active mode's session (legacy single-session view).
  Map<String, dynamic> get session => state.session;
  String get sessionMode => state.activeSessionMode;

  /// True when [mode] has an unfinished session, for the home-page primary
  /// button so "continue" always follows the mode the user selected.
  bool resumableInMode(String mode) => _resumableIn(mode);
  List<String> get sessionIds => (session['ids'] as List? ?? []).cast<String>();
  int get sessionIndex => session['index'] as int? ?? 0;
  bool get resumable => _resumableIn(sessionMode);

  bool _resumableIn(String mode) {
    final stored = state.sessions[mode];
    if (stored == null) return false;
    final ids = (stored['ids'] as List? ?? []).cast<String>();
    final index = stored['index'] as int? ?? 0;
    return ids.isNotEmpty && index < ids.length && stored['bookId'] == book?.id;
  }

  /// The active mode's session replaced by [next]; an empty map removes it.
  Map<String, Map<String, dynamic>> _sessionsWith(
    String mode,
    Map<String, dynamic> next,
  ) {
    final sessions = {...state.sessions};
    if (next.isEmpty) {
      sessions.remove(mode);
    } else {
      sessions[mode] = next;
    }
    return sessions;
  }

  /// A valid minimal session so defensive patches stay well-formed.
  Map<String, dynamic> _sessionBase(String mode, Map<String, dynamic> patch) =>
      patch.isEmpty
      ? <String, dynamic>{}
      : {'mode': mode, 'ids': const <String>[], 'index': 0, ...patch};

  Future<void> initialize() async {
    try {
      state = await storage.load();
      ready = true;
    } catch (e) {
      error = '读取本地数据失败：$e';
    }
    notifyListeners();
  }

  Future<bool> _write(Future<void> Function() action) {
    final completer = Completer<bool>();
    _pending = _pending.then((_) async {
      saving = true;
      notifyListeners();
      final before = state.clone();
      try {
        await action();
        error = null;
        completer.complete(true);
      } catch (e) {
        state = before;
        error = '保存失败，进度未推进：$e';
        completer.complete(false);
      } finally {
        saving = false;
        notifyListeners();
      }
    });
    return completer.future;
  }

  Future<bool> importBook(ImportPreview preview) => _write(() async {
    await storage.importBook(preview);
    state = await storage.load();
  });
  Future<bool> deleteBook(String id) => _write(() async {
    await storage.deleteBook(id);
    state = await storage.load();
  });
  Future<bool> updateSettings(void Function(AppSettings) update) =>
      _write(() async {
        final next = AppSettings.fromJson(settings.toJson());
        update(next);
        await storage.saveSettings(next);
        state.settings = next;
      });
  Future<bool> note(String id, String text) => _write(() async {
    await storage.saveNote(id, text);
    state.notes[id] = text;
  });

  /// 生词本成员 ID 集合（只读视图）。
  Set<String> get notebookIds => Set.unmodifiable(state.notebook);
  bool isNotebook(String id) => state.notebook.contains(id);

  /// 生词本词条：当前词书按书内顺序在前，其余按词书与载入顺序稳定排列。
  List<WordEntry> get notebookEntries {
    final ordered = <WordEntry>[];
    final seen = <String>{};
    void collect(WordBook? value) {
      if (value == null) return;
      for (final id in value.uniqueIds) {
        if (!state.notebook.contains(id) || !seen.add(id)) continue;
        final entry = state.entries[id];
        if (entry != null) ordered.add(entry);
      }
    }

    final current = book;
    collect(current);
    for (final value in state.books) {
      if (value.id != current?.id) collect(value);
    }
    for (final id in state.notebook) {
      if (seen.add(id)) {
        final entry = state.entries[id];
        if (entry != null) ordered.add(entry);
      }
    }
    return ordered;
  }

  /// 加入/移出/切换生词本；不存在的词条会被拒绝且状态不变。
  Future<bool> toggleNotebook(String id) => _setNotebook(id, null);
  Future<bool> addToNotebook(String id) => _setNotebook(id, true);
  Future<bool> removeFromNotebook(String id) => _setNotebook(id, false);

  Future<bool> _setNotebook(String id, bool? member) => _write(() async {
    if (!state.entries.containsKey(id)) {
      throw FormatException('生词本引用了不存在的单词：$id');
    }
    final add = member ?? !state.notebook.contains(id);
    if (add == state.notebook.contains(id)) return;
    final notebook = {...state.notebook};
    // 手动增删从零开始计数，避免残留连对次数立刻触发移除。
    final progress = {...state.notebookProgress}..remove(id);
    if (add) {
      notebook.add(id);
    } else {
      notebook.remove(id);
    }
    await storage.saveNotebook(notebook, progress);
    state.notebook = notebook;
    state.notebookProgress = progress;
  });

  /// Library sorting preserves source order whenever sort keys are equal.
  List<WordEntry> sortLibraryWords(List<WordEntry> entries, String order) {
    final indexed = entries.indexed.toList();
    indexed.sort((a, b) {
      var comparison = 0;
      if (order == 'alpha') {
        comparison = a.$2.word.toLowerCase().compareTo(b.$2.word.toLowerCase());
      } else if (order == 'noted') {
        bool marked(WordEntry entry) =>
            isNotebook(entry.id) ||
            state.notes[entry.id]?.trim().isNotEmpty == true;
        comparison = (marked(b.$2) ? 1 : 0).compareTo(marked(a.$2) ? 1 : 0);
      }
      return comparison != 0 ? comparison : a.$1.compareTo(b.$1);
    });
    return [for (final item in indexed) item.$2];
  }

  /// 最近的正式答错记录，最新在前；[limit] 为 null 时返回全部。
  List<LearningEvent> wrongFormalEvents({int? limit}) {
    final indexed = <(int, LearningEvent)>[];
    for (var i = 0; i < state.events.length; i++) {
      final event = state.events[i];
      if (event.kind == 'formal' && event.correct == false) {
        indexed.add((i, event));
      }
    }
    indexed.sort((a, b) {
      final byTime = b.$2.at.compareTo(a.$2.at);
      return byTime != 0 ? byTime : b.$1.compareTo(a.$1);
    });
    final events = [for (final item in indexed) item.$2];
    return limit == null ? events : events.take(max(0, limit)).toList();
  }

  /// 按本地日期（yyyy-MM-dd）分组，日期与组内事件均最新在前。
  Map<String, List<LearningEvent>> wrongFormalEventsByDay({int? limit}) {
    final grouped = <String, List<LearningEvent>>{};
    for (final event in wrongFormalEvents(limit: limit)) {
      final day = event.at.toLocal();
      final key =
          '${day.year.toString().padLeft(4, '0')}-'
          '${day.month.toString().padLeft(2, '0')}-'
          '${day.day.toString().padLeft(2, '0')}';
      (grouped[key] ??= <LearningEvent>[]).add(event);
    }
    return grouped;
  }

  /// Round queue for [mode]: due reviews first (earliest first), then unseen
  /// words in the selected study order. Known words never return as new.
  List<String> queue(String mode, {int? limit}) {
    var ordered = [...words];
    switch (settings.learningOrder) {
      case 'reverse':
        ordered = ordered.reversed.toList();
      case 'alphabet':
        ordered.sort((a, b) => wordKey(a.word).compareTo(wordKey(b.word)));
      case 'random':
        ordered.shuffle();
      case 'weak':
        ordered.sort((a, b) {
          final weakness = card(b.id).lapses.compareTo(card(a.id).lapses);
          return weakness != 0
              ? weakness
              : card(a.id).streak.compareTo(card(b.id).streak);
        });
      case 'root':
        ordered.sort(
          (a, b) =>
              OfflineMorphology.familyKey(a)
                  .compareTo(OfflineMorphology.familyKey(b)),
        );
    }
    // Typing practice drills the whole book; other modes respect study state.
    final selected = mode == 'typing' ? ordered : _dueThenFresh(ordered);
    final eligible = mode == 'formal'
        ? selected.where((e) => e.hasMeaning).toList()
        : selected;
    return eligible
        .take(max(0, limit ?? settings.roundSize))
        .map((e) => e.id)
        .toList();
  }

  /// Due cards first (earliest due wins), then words never seen before.
  List<WordEntry> _dueThenFresh(List<WordEntry> ordered) {
    final current = now;
    final due =
        ordered.where((e) {
          final card = state.cards[e.id];
          return (card?.seen ?? false) && !card!.due.isAfter(current);
        }).toList()..sort(
          (a, b) => state.cards[a.id]!.due.compareTo(state.cards[b.id]!.due),
        );
    final fresh = ordered.where((e) => !(state.cards[e.id]?.seen ?? false));
    return [...due, ...fresh];
  }

  Future<bool> begin(
    String mode, {
    bool resume = true,
    List<String>? ids,
    int? limit,
  }) => _write(() async {
    if (resume && ids == null && limit == null && _resumableIn(mode)) {
      if (state.activeSessionMode == mode) return;
      await storage.saveSessions(state.sessions, activeSessionMode: mode);
      state.activeSessionMode = mode;
      return;
    }
    final selected = ids == null
        ? queue(mode, limit: limit)
        : ids
              .where((id) => state.entries.containsKey(id))
              .toSet()
              .take(max(0, limit ?? ids.length))
              .toList();
    final next = <String, dynamic>{
      'mode': mode,
      'ids': selected,
      'index': 0,
      'bookId': book?.id,
      'startedAt': now.toIso8601String(),
      'history': <String, dynamic>{},
    };
    final sessions = _sessionsWith(mode, next);
    await storage.saveSessions(sessions, activeSessionMode: mode);
    state.sessions = sessions;
    state.activeSessionMode = mode;
  });

  /// Moves the active mode's cursor without writing any learning event.
  Future<bool> navigateTo(int index) => _write(() async {
    if (state.session.isEmpty) return;
    if (index < 0 || index > sessionIds.length) {
      throw RangeError.range(index, 0, sessionIds.length);
    }
    final sessions = _sessionsWith(sessionMode, {
      ...state.session,
      'index': index,
    });
    await storage.saveSessions(
      sessions,
      activeSessionMode: state.activeSessionMode,
    );
    state.sessions = sessions;
  });

  Future<bool> advance() => _write(() async {
    if (state.session.isEmpty) return;
    final sessions = _sessionsWith(sessionMode, {
      ...state.session,
      'index': min(sessionIndex + 1, sessionIds.length),
    });
    await storage.saveSessions(
      sessions,
      activeSessionMode: state.activeSessionMode,
    );
    state.sessions = sessions;
  });

  Future<bool> patchSession(Map<String, dynamic> patch) => _write(() async {
    final mode = sessionMode;
    final next = state.session.isEmpty
        ? _sessionBase(mode, patch)
        : {...state.session, ...patch};
    final sessions = _sessionsWith(mode, next);
    await storage.saveSessions(
      sessions,
      activeSessionMode: state.activeSessionMode,
    );
    state.sessions = sessions;
  });

  Future<bool> clearSession() => _write(() async {
    final sessions = _sessionsWith(sessionMode, const <String, dynamic>{});
    await storage.saveSessions(
      sessions,
      activeSessionMode: state.activeSessionMode,
    );
    state.sessions = sessions;
  });

  Future<bool> review(
    String id, {
    required String kind,
    bool? correct,
    bool familiar = true,
    String action = '',
    String? idempotencyKey,
    bool advanceSession = true,
    Map<String, dynamic>? sessionPatch,
  }) => _write(() async {
    if (idempotencyKey != null &&
        state.events.any((e) => e.id == idempotencyKey)) {
      return;
    }
    final current = card(id);
    final next = kind == 'formal'
        ? scheduler.answer(
            current,
            correct == true,
            now,
            errorMinutes: settings.errorMinutes,
          )
        : ['view', 'self'].contains(kind)
        ? scheduler.view(current, familiar, now)
        : current;
    final event = LearningEvent(
      id: idempotencyKey ?? eventId(),
      entryId: id,
      kind: kind,
      correct: correct,
      at: now,
      action: !current.seen && ['view', 'self', 'formal'].contains(kind)
          ? (action.isEmpty ? 'new' : 'new:$action')
          : action,
    );
    // 生词本只响应正式作答：view/self/typing 不改成员与连对计数。
    final formal = kind == 'formal';
    var notebook = state.notebook;
    var notebookProgress = state.notebookProgress;
    if (formal && correct == false) {
      final ids = {...notebook};
      if (settings.notebookAutoAddErrors) ids.add(id);
      notebook = ids;
      notebookProgress = {...notebookProgress}..remove(id);
    } else if (formal &&
        correct == true &&
        notebook.contains(id) &&
        settings.notebookRemoveAfterCorrect > 0) {
      final streak = (notebookProgress[id] ?? 0) + 1;
      if (streak >= settings.notebookRemoveAfterCorrect) {
        notebook = {...notebook}..remove(id);
        notebookProgress = {...notebookProgress}..remove(id);
      } else {
        notebookProgress = {...notebookProgress, id: streak};
      }
    }
    final session = state.session.isEmpty
        ? _sessionBase(sessionMode, sessionPatch ?? const <String, dynamic>{})
        : {
            ...state.session,
            if (advanceSession)
              'index': min(sessionIndex + 1, sessionIds.length),
            ...?sessionPatch,
          };
    final sessions = _sessionsWith(sessionMode, session);
    await storage.commitLearning(
      next,
      event,
      sessions: sessions,
      activeSessionMode: state.activeSessionMode,
      notebook: formal ? notebook : null,
      notebookProgress: formal ? notebookProgress : null,
    );
    state.cards[id] = next;
    state.events.add(event);
    state.sessions = sessions;
    if (formal) {
      state.notebook = notebook;
      state.notebookProgress = notebookProgress;
    }
  });

  Future<String?> recordNotification(String id, {DateTime? scheduledAt}) async {
    final requestId = eventId();
    final successful = await _write(() async {
      final c = card(id);
      final event = LearningEvent(
        id: requestId,
        entryId: id,
        kind: 'notification_requested',
        at: now,
        action: jsonEncode({
          'due': c.due.toIso8601String(),
          'bookId': book?.id,
          'seen': c.seen,
          if (scheduledAt != null) 'scheduledAt': scheduledAt.toIso8601String(),
        }),
      );
      await storage.commitLearning(c, event);
      state.events.add(event);
    });
    return successful
        ? jsonEncode({'requestId': requestId, 'entryId': id})
        : null;
  }

  LearningEvent? validateNotification(String payload) {
    try {
      final p = jsonDecode(payload) as Map<String, dynamic>;
      final event = state.events
          .where(
            (e) =>
                e.id == p['requestId'] &&
                e.entryId == p['entryId'] &&
                e.kind == 'notification_requested',
          )
          .firstOrNull;
      if (event == null ||
          state.events.any((e) => e.id == 'handled-${event.id}')) {
        return null;
      }
      final info = jsonDecode(event.action) as Map;
      final sentAt =
          DateTime.tryParse(info['scheduledAt'] as String? ?? '') ?? event.at;
      if (sentAt.isAfter(now) || now.difference(sentAt).inHours >= 24) {
        return null;
      }
      if (info['bookId'] != book?.id ||
          !state.entries.containsKey(event.entryId)) {
        return null;
      }
      if (state.events.any(
        (e) =>
            e.entryId == event.entryId &&
            ['formal', 'view', 'self'].contains(e.kind) &&
            e.at.isAfter(event.at),
      )) {
        return null;
      }
      return event;
    } catch (_) {
      return null;
    }
  }

  bool get mayNotify {
    if (!settings.notifications || book == null || saving) return false;
    final hour = now.hour;
    final inWindow = settings.startHour <= settings.endHour
        ? hour >= settings.startHour && hour < settings.endHour
        : hour >= settings.startHour || hour < settings.endHour;
    if (!inWindow) return false;
    final requests = state.events
        .where((e) => e.kind == 'notification_requested')
        .toList();
    if (requests.isNotEmpty &&
        now.difference(requests.last.at).inMinutes < settings.reminderMinutes) {
      return false;
    }
    return queue('quick', limit: 1).isNotEmpty;
  }

  Future<bool> restore(AppSnapshot snapshot) => _write(() async {
    await storage.replace(snapshot);
    state = snapshot;
  });
  void refreshClock() => notifyListeners();

  void clearError() {
    error = null;
    notifyListeners();
  }

  Future<void> flush() => _pending;
}
