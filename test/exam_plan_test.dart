import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/domain/exam_plan.dart';

void main() {
  final today = DateTime(2026, 10, 11, 15, 30);
  test('daily target estimates without an exam, including today', () {
    final plan = DailyNewPlan.compute(50, 101, today);
    expect(plan.target, 50);
    expect(plan.remaining, 101);
    expect(plan.daysNeeded, 3);
    expect(plan.completionDate, DateTime(2026, 10, 13));
    expect(
      DailyNewPlan.compute(50, 50, today).completionDate,
      DateTime(2026, 10, 11),
    );
    expect(DailyNewPlan.compute(50, 100, today).daysNeeded, 2);
  });
  test(
    'daily target has no upper quota and invalid legacy values are explicit',
    () {
      expect(DailyNewPlan.compute(1000, 2001, today).daysNeeded, 3);
      for (final target in [0, -1]) {
        final plan = DailyNewPlan.compute(target, 100, today);
        expect(plan.target, isNull);
        expect(plan.daysNeeded, isNull);
        expect(plan.completionDate, isNull);
      }
      final done = DailyNewPlan.compute(0, -2, today);
      expect(done.remaining, 0);
      expect(done.daysNeeded, 0);
      expect(done.completionDate, DateTime(2026, 10, 11));
    },
  );
  test(
    'daily estimate uses civil dates across month year and leap boundaries',
    () {
      expect(
        DailyNewPlan.compute(1, 3, DateTime(2026, 12, 31, 23)).completionDate,
        DateTime(2027, 1, 2),
      );
      expect(
        DailyNewPlan.compute(1, 2, DateTime(2028, 2, 28)).completionDate,
        DateTime(2028, 2, 29),
      );
      expect(
        DailyNewPlan.compute(1, 3, DateTime(2026, 3, 7)).completionDate,
        DateTime(2026, 3, 9),
      );
    },
  );
  test(
    'exam recommendation stays independent of the selected daily target',
    () {
      final daily = DailyNewPlan.compute(50, 120, today);
      final exam = ExamPlan.compute('2026-10-13', 120, today);
      expect(daily.daysNeeded, 3);
      expect(exam.perDay, 60);
    },
  );

  test('no or unparseable exam date yields an unplanned plan', () {
    for (final date in ['', 'not-a-date', '  ', 'tomorrow', '2026-1x-11']) {
      final plan = ExamPlan.compute(date, 120, today);
      expect(plan.daysLeft, isNull, reason: date);
      expect(plan.perDay, isNull, reason: date);
      expect(plan.remaining, 120);
      expect(plan.planned, isFalse);
      expect(plan.expired, isFalse);
    }
  });
  test('exam today and past dates clamp to an expired plan', () {
    for (final date in ['2026-10-11', '2020-01-01']) {
      final plan = ExamPlan.compute(date, 30, today);
      expect(plan.daysLeft, 0, reason: date);
      expect(plan.expired, isTrue, reason: date);
      expect(plan.perDay, 30, reason: date);
    }
  });
  test('ceil pace spreads remaining words over whole days', () {
    final plan = ExamPlan.compute('2026-10-14', 7, today);
    expect(plan.daysLeft, 3);
    expect(plan.perDay, 3);
    expect(plan.done, isFalse);
    final exact = ExamPlan.compute('2026-10-13', 4, today);
    expect(exact.daysLeft, 2);
    expect(exact.perDay, 2);
    expect(ExamPlan.compute('2026-10-12T09:00', 3, today).daysLeft, 1);
  });
  test('nothing left needs no pace and negatives clamp to zero', () {
    final plan = ExamPlan.compute('2026-10-30', 0, today);
    expect(plan.perDay, 0);
    expect(plan.done, isTrue);
    expect(plan.daysLeft, 19);
    expect(ExamPlan.compute('2026-10-30', -5, today).remaining, 0);
    expect(ExamPlan.compute('2026-10-11', -5, today).perDay, 0);
  });
}
