import 'dart:math';

import 'models.dart';

abstract interface class ReviewScheduler {
  ReviewCard answer(
    ReviewCard card,
    bool correct,
    DateTime now, {
    int errorMinutes = 10,
  });
  ReviewCard view(ReviewCard card, bool familiar, DateTime now);
}

class IntervalScheduler implements ReviewScheduler {
  static const days = [1, 3, 7, 14, 30, 60, 120];
  @override
  ReviewCard answer(
    ReviewCard card,
    bool correct,
    DateTime now, {
    int errorMinutes = 10,
  }) => ReviewCard(
    entryId: card.entryId,
    seen: true,
    streak: correct
        ? card.streak + (card.reviews > 0 && card.due.isAfter(now) ? 0 : 1)
        : 0,
    reviews: card.reviews + 1,
    lapses: card.lapses + (correct ? 0 : 1),
    due: correct
        ? card.reviews > 0 && card.due.isAfter(now)
              ? card.due
              : now.add(Duration(days: days[min(card.streak, days.length - 1)]))
        : now.add(Duration(minutes: errorMinutes)),
  );
  @override
  ReviewCard view(ReviewCard card, bool familiar, DateTime now) => ReviewCard(
    entryId: card.entryId,
    seen: true,
    streak: card.streak,
    reviews: card.reviews,
    lapses: card.lapses,
    due: card.reviews > 0 && familiar
        ? card.due
        : now.add(Duration(minutes: familiar ? 10 : 1)),
  );
}

class ChoiceQuestion {
  const ChoiceQuestion(this.entry, this.options, this.correctIndex);
  final WordEntry entry;
  final List<String> options;
  final int correctIndex;
}

String _cleanGloss(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll(RegExp(r'[；;，,。.!！]'), '');
Set<String> _glossParts(String text) => text
    .replaceAll(RegExp(r'\b(n|v|vt|vi|adj|adv|prep|pron|conj|a)\.'), '')
    .split(RegExp(r'[;；,，\n]'))
    .map((s) => _cleanGloss(s))
    .where((s) => s.length >= 2)
    .toSet();
String _pos(String text) =>
    RegExp(r'^\s*(n|v|vt|vi|adj|adv|prep|pron|conj|a)\.')
        .firstMatch(text.toLowerCase())
        ?.group(1) ??
    '';

ChoiceQuestion? createQuestion(
  WordEntry entry,
  Iterable<WordEntry> pool, {
  int count = 4,
  int seed = 0,
}) {
  if (!entry.hasMeaning) return null;
  final random = Random(seed);
  final targetParts = _glossParts(entry.meaning);
  final candidates =
      pool.where((e) => e.id != entry.id && e.hasMeaning).toList()
        ..shuffle(random);
  candidates.sort(
    (a, b) => (_pos(b.meaning) == _pos(entry.meaning) ? 1 : 0).compareTo(
      _pos(a.meaning) == _pos(entry.meaning) ? 1 : 0,
    ),
  );
  final options = <String>[entry.coreMeaning];
  final used = <String>{_cleanGloss(entry.meaning)};
  for (final candidate in candidates) {
    final key = _cleanGloss(candidate.meaning);
    final parts = _glossParts(candidate.meaning);
    if (used.contains(key) ||
        targetParts.any(
          (a) => parts.any((b) => a == b || a.contains(b) || b.contains(a)),
        )) {
      continue;
    }
    options.add(candidate.coreMeaning);
    used.add(key);
    if (options.length >= count) break;
  }
  if (options.length < 2) return null;
  options.shuffle(random);
  return ChoiceQuestion(entry, options, options.indexOf(entry.coreMeaning));
}
