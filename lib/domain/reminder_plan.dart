import 'models.dart';

List<DateTime> reminderSlots(
  DateTime now,
  AppSettings settings, {
  required int count,
  Map<String, int> requestedPerDay = const {},
}) {
  if (!settings.notifications || count <= 0) return [];
  final end = now.add(const Duration(hours: 24));
  final interval = Duration(minutes: settings.reminderMinutes.clamp(1, 240));
  final slots = <DateTime>[];
  var next = now.add(interval);
  while (next.isBefore(end) && slots.length < count) {
    final hour = next.hour;
    final inWindow = settings.startHour <= settings.endHour
        ? hour >= settings.startHour && hour < settings.endHour
        : hour >= settings.startHour || hour < settings.endHour;
    if (inWindow) {
      slots.add(next);
      next = next.add(interval);
    } else {
      next = next.add(const Duration(minutes: 1));
    }
  }
  return slots;
}

String reminderDay(DateTime date) => '${date.year}-${date.month}-${date.day}';
