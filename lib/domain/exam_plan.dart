import 'dart:math';

/// Pure exam pacing plan for the active book.
///
/// [daysLeft] is `null` when the exam date is missing or unparseable;
/// otherwise it is the whole number of days until the exam, clamped to zero
/// once the date has passed. [perDay] is the ceil of `remaining / daysLeft`,
/// so an expired plan puts everything on today and an empty plan needs zero.
class ExamPlan {
  const ExamPlan({this.daysLeft, required this.remaining, this.perDay});

  /// Days until the exam (>= 0), or `null` when no usable date is set.
  final int? daysLeft;

  /// Remaining new words, never negative.
  final int remaining;

  /// Words to introduce per remaining day, or `null` when there is no date.
  final int? perDay;

  /// Whether a usable exam date exists.
  bool get planned => daysLeft != null;

  /// Whether the exam date is today or already past.
  bool get expired => daysLeft == 0;

  /// Whether no new words are left.
  bool get done => remaining == 0;

  static ExamPlan compute(
    String examDate,
    int remainingNewWords,
    DateTime today,
  ) {
    final remaining = max(0, remainingNewWords);
    final exam = _day(DateTime.tryParse(examDate.trim()));
    if (exam == null) {
      return ExamPlan(daysLeft: null, remaining: remaining, perDay: null);
    }
    final daysLeft = max(0, exam.difference(_day(today)!).inDays);
    final perDay = remaining == 0
        ? 0
        : daysLeft == 0
        ? remaining
        : (remaining + daysLeft - 1) ~/ daysLeft;
    return ExamPlan(daysLeft: daysLeft, remaining: remaining, perDay: perDay);
  }

  /// Midnight UTC for civil-date arithmetic, immune to DST shifts.
  static DateTime? _day(DateTime? value) =>
      value == null ? null : DateTime.utc(value.year, value.month, value.day);
}
