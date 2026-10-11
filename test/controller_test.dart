import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/data/storage.dart';
import 'package:wordnest/domain/controller.dart';
import 'package:wordnest/domain/models.dart';

class FailingStorage extends MemoryStorage {
  bool fail = false;
  bool failNotebook = false;
  @override
  Future<void> commitLearning(
    ReviewCard card,
    LearningEvent event, {
    Map<String, Map<String, dynamic>>? sessions,
    String? activeSessionMode,
    Set<String>? notebook,
    Map<String, int>? notebookProgress,
  }) {
    if (fail) throw StateError('disk full');
    return super.commitLearning(
      card,
      event,
      sessions: sessions,
      activeSessionMode: activeSessionMode,
      notebook: notebook,
      notebookProgress: notebookProgress,
    );
  }

  @override
  Future<void> saveNotebook(Set<String> ids, Map<String, int> progress) {
    if (failNotebook) throw StateError('disk full');
    return super.saveNotebook(ids, progress);
  }
}

String _examDateIn(int days) {
  final date = DateTime.now().add(Duration(days: days));
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

void main() {
  Future<AppController> create([AppStorage? storage]) async {
    final c = AppController(storage ?? MemoryStorage());
    await c.initialize();
    await c.importBook(
      ImportPreview(
        book: WordBook(
          id: 'book',
          title: '词书',
          importedAt: DateTime.now(),
          members: const [
            BookMember(entryId: 'a', unit: 'Unit1', position: 0),
            BookMember(entryId: 'b', unit: 'Unit2', position: 1),
          ],
        ),
        entries: const {
          'a': WordEntry(id: 'a', word: 'apple', meaning: '苹果'),
          'b': WordEntry(id: 'b', word: 'bird', meaning: '鸟'),
        },
        total: 2,
        duplicates: 0,
        missingMeanings: 0,
        missingExamples: 2,
      ),
    );
    await c.begin('quick');
    return c;
  }

  test('failed storage keeps UI progress and permits retry', () async {
    final storage = FailingStorage();
    final c = await create(storage);
    storage.fail = true;
    expect(await c.review('a', kind: 'view'), isFalse);
    expect(c.sessionIndex, 0);
    expect(c.state.events, isEmpty);
    expect(c.error, contains('保存失败'));
    storage.fail = false;
    expect(await c.review('a', kind: 'view'), isTrue);
    expect(c.sessionIndex, 1);
    expect(c.error, isNull);
  });
  test('double action event cannot advance session twice', () async {
    final c = await create();
    await c.review('a', kind: 'view', idempotencyKey: 'same');
    await c.review('a', kind: 'view', idempotencyKey: 'same');
    expect(c.sessionIndex, 1);
    expect(c.state.events.length, 1);
    expect(c.formalToday, 0);
  });
  test('notification is idempotent and stale after formal answer', () async {
    final c = await create();
    final payload = await c.recordNotification('a');
    expect(payload, isNotNull);
    expect(c.validateNotification(payload!), isNotNull);
    await c.review('a', kind: 'formal', correct: true, advanceSession: false);
    expect(c.validateNotification(payload), isNull);
    final another = await c.recordNotification('b');
    final request = c.validateNotification(another!);
    await c.review(
      'b',
      kind: 'self',
      idempotencyKey: 'handled-${request!.id}',
      advanceSession: false,
    );
    expect(c.validateNotification(another), isNull);
    expect(c.formalToday, 1);
  });
  test('restored active session resumes exact queue position', () async {
    final c = await create();
    await c.review('a', kind: 'view');
    final next = AppController(c.storage);
    await next.initialize();
    expect(next.sessionIndex, 1);
    expect(next.resumable, isTrue);
    await next.begin('quick');
    expect(next.sessionIndex, 1);
  });
  test(
    'verification request consumes a notification without claiming learning',
    () async {
      final c = await create();
      final payload = await c.recordNotification('a');
      final event = c.validateNotification(payload!);
      await c.review(
        'a',
        kind: 'notification_verified_request',
        action: 'verify',
        idempotencyKey: 'handled-${event!.id}',
        advanceSession: false,
      );
      expect(c.card('a').seen, isFalse);
      expect(c.workloadToday, 0);
      expect(c.validateNotification(payload), isNull);
    },
  );
  test('future reminders are invalid before their planned time', () async {
    final c = await create();
    final payload = await c.recordNotification(
      'a',
      scheduledAt: DateTime.now().add(const Duration(hours: 1)),
    );
    expect(c.validateNotification(payload!), isNull);
    expect(c.card('a').seen, isFalse);
    expect(c.workloadToday, 0);
  });
  test('legacy daily quotas never cap the selected round', () async {
    final c = await create();
    await c.updateSettings((s) {
      s.dailyNew = 1;
      s.dailyLimit = 1;
    });
    expect(c.queue('quick'), ['a', 'b']);
    await c.review(
      'a',
      kind: 'self',
      action: 'remember',
      advanceSession: false,
    );
    expect(c.state.events.single.action, 'new:remember');
  });
  test('known words leave the new pool and count as seen', () async {
    final c = await create();
    await c.updateSettings((s) => s.dailyLimit = 1);
    await c.review('a', kind: 'view');
    expect(c.card('a').seen, isTrue);
    expect(c.words.length - c.remaining, 1);
    expect(c.queue('quick'), ['b']);
    expect(c.queue('formal'), ['b']);
    await c.begin('quick', resume: false);
    expect(c.sessionIds, ['b']);
    await c.review('b', kind: 'view');
    expect(c.queue('quick'), isEmpty);
  });
  test('optional typing drills the whole book after quick reviews', () async {
    final c = await create();
    await c.updateSettings((s) => s.dailyLimit = 1);
    await c.review('a', kind: 'view');
    expect(c.queue('quick'), ['b']);
    expect(c.queue('typing'), ['a', 'b']);
  });
  test('selected count, reverse order and cursor navigation persist without events', () async {
    final c = await create();
    await c.updateSettings((s) => s.learningOrder = 'reverse');
    expect(c.queue('quick'), ['b', 'a']);
    await c.begin('formal', resume: false, limit: 1);
    expect(c.sessionIds, ['b']);
    await c.navigateTo(1);
    await c.navigateTo(0);
    expect(c.state.events, isEmpty);
    final reloaded = await c.storage.load();
    expect(reloaded.session['index'], 0);
    await c.begin('typing', resume: false, ids: ['a', 'b'], limit: 2);
    expect(c.sessionIds, ['a', 'b']);
  });
  test(
    'compact quick self review writes card and event through review()',
    () async {
      final storage = MemoryStorage();
      final c = await create(storage);
      final ok = await c.review(
        'a',
        kind: 'self',
        familiar: true,
        action: 'remember',
        sessionPatch: {
          'history': {
            '0': {
              'quickResult': {'familiar': true},
            },
          },
        },
      );
      expect(ok, isTrue);
      expect(c.card('a').seen, isTrue);
      expect(c.formalToday, 0);
      expect(c.state.events.single.kind, 'self');
      expect(c.state.events.single.action, 'new:remember');
      final saved = await storage.load();
      expect(saved.cards['a']!.seen, isTrue);
      expect(saved.events.single.kind, 'self');
      expect(saved.session['history']['0']['quickResult']['familiar'], true);
    },
  );
  test(
    'per-mode sessions keep independent cursors across switches and reopen',
    () async {
      final storage = MemoryStorage();
      final c = await create(storage);
      await c.review('a', kind: 'view');
      expect(c.sessionMode, 'quick');
      expect(c.sessionIndex, 1);
      await c.begin('typing', resume: false);
      expect(c.sessionMode, 'typing');
      expect(c.sessionIds, ['a', 'b']);
      expect(c.sessionIndex, 0);
      await c.review('b', kind: 'typing', correct: true);
      expect(c.sessionIndex, 1);
      await c.begin('quick');
      expect(c.sessionMode, 'quick');
      expect(c.sessionIndex, 1);
      await c.begin('typing');
      expect(c.sessionIndex, 1);
      final next = AppController(storage);
      await next.initialize();
      expect(next.sessionMode, 'typing');
      expect(next.sessionIndex, 1);
      expect(next.sessions.keys.toSet(), {'quick', 'typing'});
      await next.begin('quick');
      expect(next.sessionIds, ['a', 'b']);
      expect(next.sessionIndex, 1);
      await next.clearSession();
      expect(next.sessionIds, isEmpty);
      await next.begin('typing');
      expect(next.sessionIndex, 1);
      await next.begin('quick', resume: false);
      expect(next.sessionIds, ['b']);
    },
  );
  test('exam plan uses the active book unseen count', () async {
    final c = await create();
    expect(c.examPlan.daysLeft, isNull);
    expect(c.examPlan.perDay, isNull);
    await c.updateSettings((s) => s.examDate = _examDateIn(3));
    expect(c.examPlan.daysLeft, 3);
    expect(c.examPlan.remaining, 2);
    expect(c.examPlan.perDay, 1);
    await c.review('a', kind: 'view');
    expect(c.examPlan.remaining, 1);
    expect(c.examPlan.perDay, 1);
  });
  test('fixed option history survives answers navigation and reopen', () async {
    final c = await create();
    final question = {
      'options': ['b', 'a'],
      'optionLabels': ['鸟', '苹果'],
      'correctIndex': 1,
    };
    await c.patchSession({
      'history': {'0': question},
    });
    await c.review(
      'a',
      kind: 'formal',
      correct: true,
      sessionPatch: {
        'history': {
          '0': {
            ...question,
            'result': {'index': 0, 'selected': 1, 'correct': true},
          },
        },
      },
    );
    await c.navigateTo(0);
    final saved = await c.storage.load();
    expect(saved.session['history']['0']['optionLabels'], ['鸟', '苹果']);
    expect(saved.session['history']['0']['result']['correct'], true);
    expect(saved.events, hasLength(1));
  });

  group('notebook', () {
    test(
      'wrong formal answers auto-add and can be disabled by setting',
      () async {
        final c = await create();
        expect(c.settings.notebookAutoAddErrors, isTrue);
        expect(c.settings.notebookRemoveAfterCorrect, 2);
        expect(c.settings.questionDirection, 'en2zh');
        expect(c.notebookIds, isEmpty);

        await c.review(
          'a',
          kind: 'formal',
          correct: false,
          advanceSession: false,
        );
        expect(c.isNotebook('a'), isTrue);
        expect(c.notebookIds, {'a'});
        expect(c.state.notebookProgress, isEmpty);

        // Self/view/typing never change membership, even with correct=false.
        for (final kind in ['view', 'self', 'typing']) {
          await c.review(
            'b',
            kind: kind,
            correct: false,
            advanceSession: false,
          );
        }
        expect(c.notebookIds, {'a'});

        await c.updateSettings((s) => s.notebookAutoAddErrors = false);
        await c.review(
          'b',
          kind: 'formal',
          correct: false,
          advanceSession: false,
        );
        expect(c.notebookIds, {'a'});
      },
    );

    test(
      'a formal correct streak removes the member at the threshold',
      () async {
        final c = await create();
        await c.updateSettings((s) => s.notebookRemoveAfterCorrect = 3);
        await c.review(
          'a',
          kind: 'formal',
          correct: false,
          advanceSession: false,
        );
        await c.review(
          'a',
          kind: 'formal',
          correct: true,
          advanceSession: false,
        );
        expect(c.state.notebookProgress['a'], 1);

        // A wrong formal answer resets the streak instead of removing the word.
        await c.review(
          'a',
          kind: 'formal',
          correct: false,
          advanceSession: false,
        );
        expect(c.state.notebookProgress.containsKey('a'), isFalse);
        expect(c.isNotebook('a'), isTrue);

        await c.review(
          'a',
          kind: 'formal',
          correct: true,
          advanceSession: false,
        );
        await c.review(
          'a',
          kind: 'formal',
          correct: true,
          advanceSession: false,
        );
        expect(c.state.notebookProgress['a'], 2);
        expect(c.isNotebook('a'), isTrue);
        await c.review(
          'a',
          kind: 'formal',
          correct: true,
          advanceSession: false,
        );
        expect(c.isNotebook('a'), isFalse);
        expect(c.state.notebookProgress.containsKey('a'), isFalse);
      },
    );

    test(
      'notebookRemoveAfterCorrect 0 never removes and stores no counter',
      () async {
        final c = await create();
        await c.review(
          'a',
          kind: 'formal',
          correct: false,
          advanceSession: false,
        );
        await c.updateSettings((s) => s.notebookRemoveAfterCorrect = 0);
        for (var i = 0; i < 4; i++) {
          await c.review(
            'a',
            kind: 'formal',
            correct: true,
            advanceSession: false,
          );
        }
        expect(c.isNotebook('a'), isTrue);
        expect(c.state.notebookProgress, isEmpty);

        await c.updateSettings((s) => s.notebookRemoveAfterCorrect = 1);
        await c.review('a', kind: 'view', advanceSession: false);
        expect(c.isNotebook('a'), isTrue);
        expect(c.state.notebookProgress, isEmpty);
        await c.review(
          'a',
          kind: 'formal',
          correct: true,
          advanceSession: false,
        );
        expect(c.isNotebook('a'), isFalse);
      },
    );

    test(
      'toggle and explicit membership changes persist across reopen',
      () async {
        final storage = MemoryStorage();
        final c = await create(storage);
        expect(await c.toggleNotebook('b'), isTrue);
        expect(c.isNotebook('b'), isTrue);
        expect(await c.addToNotebook('a'), isTrue);
        expect(c.notebookIds, {'a', 'b'});

        final next = AppController(storage);
        await next.initialize();
        expect(next.notebookIds, {'a', 'b'});
        expect(await next.toggleNotebook('b'), isTrue);
        expect(next.notebookIds, {'a'});
        expect(await next.removeFromNotebook('a'), isTrue);
        expect(next.notebookIds, isEmpty);

        final again = AppController(storage);
        await again.initialize();
        expect(again.notebookIds, isEmpty);
        expect(await again.addToNotebook('missing'), isFalse);
        expect(again.notebookIds, isEmpty);
        expect(again.error, contains('不存在'));
      },
    );

    test('notebookEntries orders by active book then other sources', () async {
      final c = await create();
      await c.importBook(
        ImportPreview(
          book: WordBook(
            id: 'extra',
            title: '补充',
            importedAt: DateTime.now(),
            members: const [
              BookMember(entryId: 'c', unit: 'U1', position: 0),
              BookMember(entryId: 'd', unit: 'U1', position: 1),
            ],
          ),
          entries: const {
            'c': WordEntry(id: 'c', word: 'cat', meaning: '猫'),
            'd': WordEntry(id: 'd', word: 'dog', meaning: '狗'),
          },
          total: 2,
          duplicates: 0,
          missingMeanings: 0,
          missingExamples: 2,
        ),
      );
      await c.updateSettings((s) => s.activeBookId = 'book');
      for (final id in ['d', 'c', 'b', 'a']) {
        await c.addToNotebook(id);
      }
      expect(c.notebookEntries.map((e) => e.id).toList(), ['a', 'b', 'c', 'd']);
      expect(c.notebookEntries.map((e) => e.id).toList(), ['a', 'b', 'c', 'd']);
      await c.removeFromNotebook('a');
      expect(c.notebookEntries.map((e) => e.id).toList(), ['b', 'c', 'd']);
    });

    test(
      'wrong formal events are newest first, limited and day-grouped',
      () async {
        final c = await create();
        await c.review(
          'a',
          kind: 'formal',
          correct: false,
          advanceSession: false,
        );
        await c.review(
          'b',
          kind: 'formal',
          correct: true,
          advanceSession: false,
        );
        await c.review(
          'b',
          kind: 'formal',
          correct: false,
          advanceSession: false,
        );
        expect(c.wrongFormalEvents().map((e) => e.entryId).toList(), [
          'b',
          'a',
        ]);
        expect(c.wrongFormalEvents(limit: 1).single.entryId, 'b');
        expect(c.wrongFormalEvents(limit: 0), isEmpty);
        final grouped = c.wrongFormalEventsByDay();
        expect(grouped.values.single.map((e) => e.entryId).toList(), [
          'b',
          'a',
        ]);
      },
    );

    test(
      'failed notebook writes keep membership and report the error',
      () async {
        final storage = FailingStorage();
        final c = await create(storage);
        storage.failNotebook = true;
        expect(await c.addToNotebook('a'), isFalse);
        expect(c.notebookIds, isEmpty);
        expect(c.error, contains('保存失败'));
        storage.failNotebook = false;
        expect(await c.addToNotebook('a'), isTrue);
        expect(c.notebookIds, {'a'});

        storage.fail = true;
        expect(
          await c.review(
            'b',
            kind: 'formal',
            correct: false,
            advanceSession: false,
          ),
          isFalse,
        );
        expect(c.notebookIds, {'a'});
        expect(c.state.events, isEmpty);
      },
    );
  });
}
