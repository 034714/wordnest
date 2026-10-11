import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/domain/models.dart';
import 'package:wordnest/domain/reminder_plan.dart';

void main() {
  test('disabled notifications never generate background tasks', () {
    expect(
      reminderSlots(DateTime(2026, 10, 11, 12), AppSettings(), count: 10),
      isEmpty,
    );
  });
  test('slots observe hours and interval but ignore legacy daily quota', () {
    final settings = AppSettings(
      notifications: true,
      reminderMinutes: 30,
      notificationLimit: 2,
      startHour: 9,
      endHour: 21,
    );
    final now = DateTime(2026, 10, 11, 20);
    final slots = reminderSlots(
      now,
      settings,
      count: 10,
      requestedPerDay: {'2026-10-11': 1},
    );
    expect(slots, hasLength(10));
    expect(slots.first, DateTime(2026, 10, 11, 20, 30));
    expect(slots[1], DateTime(2026, 10, 12, 9));
    expect(
      slots.every((date) => date.isBefore(now.add(const Duration(hours: 24)))),
      isTrue,
    );
  });
  test('overnight windows and empty time windows are handled', () {
    final settings = AppSettings(
      notifications: true,
      reminderMinutes: 60,
      startHour: 22,
      endHour: 6,
    );
    final slots = reminderSlots(DateTime(2026, 10, 11, 21), settings, count: 3);
    expect(slots.map((date) => date.hour), [22, 23, 0]);
    settings.startHour = 9;
    settings.endHour = 9;
    expect(
      reminderSlots(DateTime(2026, 10, 11, 12), settings, count: 3),
      isEmpty,
    );
  });
}
