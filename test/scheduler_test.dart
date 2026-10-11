import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/domain/models.dart';
import 'package:wordnest/domain/scheduler.dart';

void main() {
  final now = DateTime.utc(2026, 10, 11, 12);
  final scheduler = IntervalScheduler();
  test('viewing translated words never counts as formal recall', () {
    final c = ReviewCard(entryId: 'focus', due: now);
    final seen = scheduler.view(c, true, now);
    expect(seen.seen, isTrue);
    expect(seen.reviews, 0);
    expect(seen.streak, 0);
    expect(seen.due, now.add(const Duration(minutes: 10)));
  });
  test('correct recall expands interval and failure resets streak', () {
    var c = ReviewCard(entryId: 'focus', due: now);
    c = scheduler.answer(c, true, now);
    expect(c.due, now.add(const Duration(days: 1)));
    final tomorrow = now.add(const Duration(days: 1));
    c = scheduler.answer(c, true, tomorrow);
    expect(c.due, tomorrow.add(const Duration(days: 3)));
    c = scheduler.answer(c, false, tomorrow, errorMinutes: 5);
    expect(c.streak, 0);
    expect(c.lapses, 1);
    expect(c.reviews, 3);
    expect(c.due, tomorrow.add(const Duration(minutes: 5)));
  });
  test(
    'early repeated answers do not inflate stable streak or postpone due',
    () {
      final reviewed = scheduler.answer(
        ReviewCard(entryId: 'focus', due: now),
        true,
        now,
      );
      final early = scheduler.answer(
        reviewed,
        true,
        now.add(const Duration(minutes: 1)),
      );
      expect(early.streak, reviewed.streak);
      expect(early.due, reviewed.due);
    },
  );
  test('translated notifications cannot undo a formal review interval', () {
    final reviewed = scheduler.answer(
      ReviewCard(entryId: 'focus', due: now),
      true,
      now,
    );
    expect(scheduler.view(reviewed, true, now).due, reviewed.due);
    expect(
      scheduler.view(reviewed, false, now).due,
      now.add(const Duration(minutes: 1)),
    );
  });
  test('question suppresses exact and overlapping meaning distractors', () {
    const target = WordEntry(
      id: 'focus',
      word: 'focus',
      meaning: 'v. 专注；集中注意力',
    );
    final q = createQuestion(target, const [
      target,
      WordEntry(id: 'concentrate', word: 'concentrate', meaning: 'v. 集中注意力'),
      WordEntry(id: 'travel', word: 'travel', meaning: 'v. 旅行'),
      WordEntry(id: 'read', word: 'read', meaning: 'v. 阅读'),
      WordEntry(id: 'write', word: 'write', meaning: 'v. 书写'),
    ]);
    expect(q, isNotNull);
    expect(q!.options, hasLength(4));
    expect(q.options, isNot(contains('v. 集中注意力')));
    expect(q.options[q.correctIndex], target.coreMeaning);
  });
  test('no misleading quiz when entries lack translated meaning', () {
    const w = WordEntry(id: 'word', word: 'word', meaning: '');
    expect(createQuestion(w, [w]), isNull);
  });
  test('backup snapshot clone isolates mutable settings and notes', () {
    final snapshot = AppSnapshot(notes: {'focus': '笔记'});
    final copied = snapshot.clone();
    copied.notes['focus'] = '已改';
    copied.settings.dailyNew = 30;
    expect(snapshot.notes['focus'], '笔记');
    expect(snapshot.settings.dailyNew, 10);
    expect(jsonDecode(jsonEncode(copied.toJson()))['version'], 1);
  });
}
