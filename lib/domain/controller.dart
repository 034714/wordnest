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
  WordBook? get book =>
      state.books.where((b) => b.id == settings.activeBookId).firstOrNull ??
      state.books.firstOrNull;
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
    );
    state.cards[id] = next;
    state.events.add(event);
    state.sessions = sessions;
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
