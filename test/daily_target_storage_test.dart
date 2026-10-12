import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/data/storage.dart';
import 'package:wordnest/domain/models.dart';

void main() {
  test('daily target accepts positive safe integers beyond the old quota', () {
    for (final target in [1, 101, 1000, 9007199254740991]) {
      final snapshot = AppSnapshot();
      snapshot.settings.dailyNew = target;
      final encoded = BackupCodec.encode(snapshot);
      expect((jsonDecode(encoded) as Map)['settings']['dailyNew'], target);
      expect(BackupCodec.decode(encoded).settings.dailyNew, target);
    }
  });

  test(
    'daily target rejects nonpositive unsafe or noninteger backup values',
    () {
      for (final target in [0, -1, 9007199254740992, 1.5, '1000', null]) {
        final raw = AppSnapshot().toJson();
        (raw['settings'] as Map)['dailyNew'] = target;
        expect(
          () => BackupCodec.decode(jsonEncode(raw)),
          throwsFormatException,
          reason: 'target=$target',
        );
      }
      for (final target in [0, -1, 9007199254740992]) {
        final snapshot = AppSnapshot();
        snapshot.settings.dailyNew = target;
        expect(() => BackupCodec.encode(snapshot), throwsFormatException);
      }
    },
  );

  test('memory settings persist a daily plan target above 100', () async {
    final storage = MemoryStorage();
    addTearDown(storage.dispose);
    await storage.saveSettings(AppSettings(dailyNew: 1000));
    expect((await storage.load()).settings.dailyNew, 1000);
  });
}
