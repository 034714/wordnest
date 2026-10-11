import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wordnest/data/importer.dart';
import 'package:wordnest/data/offline_dictionary.dart';
import 'package:wordnest/data/storage.dart';
import 'package:wordnest/domain/models.dart';

void main() {
  group('ImportParser', () {
    test('imports original generated chapter fixture without external files', () {
      final text = _syntheticChapterFixture();
      final preview = ImportParser.parse(text, 'synthetic.json');
      expect(preview.total, 2331);
      expect(preview.entries.length, 2329);
      expect(preview.book.members, hasLength(2331));
      final chapters = (jsonDecode(text) as Map)['chapters'] as List;
      final expectedUnits = [
        for (final chapter in chapters) chapter['name'] as String,
      ];
      expect(preview.book.units, expectedUnits);
      expect(preview.book.units, hasLength(10));
      expect(preview.book.units[4], 'unit 5');
      expect(
        [
          for (final unit in preview.book.units)
            preview.book.members.where((member) => member.unit == unit).length,
        ],
        [233, 233, 233, 233, 233, 233, 233, 233, 233, 234],
      );
      var position = 0;
      final originalIds = <String>[];
      for (final chapter in chapters) {
        for (final word in chapter['words'] as List) {
          final member = preview.book.members[position];
          final id = wordKey(word['w'] as String);
          expect(member.entryId, id, reason: 'Original record ${position + 1}');
          expect(member.unit, chapter['name']);
          expect(member.position, ++position);
          originalIds.add(id);
        }
      }
      expect(preview.book.uniqueIds, originalIds.toSet().toList());
      expect(preview.entries['synthetic0']?.meaning, 'Original test meaning 0');
      expect(preview.duplicates, 2);
    });

    test('parses quoted CSV and explicit mappings', () {
      final preview = ImportParser.parse(
        '单词,中文,例句\n"hello, world","问候","He said ""hello, world""."\n',
        'words.csv',
      );
      expect(preview.total, 1);
      expect(preview.entries['hello, world']?.meaning, '问候');
      expect(
        preview.entries['hello, world']?.example,
        'He said "hello, world".',
      );

      final mapped = ImportParser.parse(
        'cat,猫,unit-a\n',
        'mapped.csv',
        csvMapping: {'word': 0, 'meaning': 1, 'unit': 2},
      );
      expect(mapped.book.members.single.unit, 'unit-a');
      expect(mapped.entries['cat']?.meaning, '猫');
    });

    test('accepts UTF-8 BOM without corrupting words or CSV headers', () {
      for (final file in ['words.txt', 'words.csv', 'words.json']) {
        final text = file.endsWith('.json')
            ? '["cat"]'
            : file.endsWith('.csv')
            ? 'word,meaning\ncat,猫'
            : 'cat\t猫';
        expect(ImportParser.parse('\uFEFF$text', file).entries.keys, ['cat']);
      }
    });

    test('rejects malformed structures and empty words', () {
      expect(
        () => ImportParser.parse('{"chapters":{}}', 'bad.json'),
        throwsFormatException,
      );
      expect(
        () => ImportParser.parse('word,meaning\n,empty\n', 'bad.csv'),
        throwsFormatException,
      );
      expect(
        () => ImportParser.parse('good\n\tbad\n', 'bad.txt'),
        throwsFormatException,
      );
    });
  });

  group('MemoryStorage and backup validation', () {
    final malformed = <String, void Function(Map<String, dynamic>)>{
      'duplicate entry': (j) =>
          (j['entries'] as List).add((j['entries'] as List).first),
      'duplicate card': (j) =>
          (j['cards'] as List).add((j['cards'] as List).first),
      'duplicate book': (j) =>
          (j['books'] as List).add((j['books'] as List).first),
      'duplicate event': (j) =>
          (j['events'] as List).add((j['events'] as List).first),
      'duplicate position': (j) =>
          j['books'][0]['members'].add(j['books'][0]['members'][0]),
      'missing entry field': (j) => j['entries'][0].remove('meaning'),
      'string card counter': (j) => j['cards'][0]['reviews'] = '1',
      'negative card counter': (j) => j['cards'][0]['lapses'] = -1,
      'invalid card date': (j) => j['cards'][0]['due'] = 'not-date',
      'invalid card bool': (j) => j['cards'][0]['seen'] = 1,
      'orphan card': (j) => j['cards'][0]['entryId'] = 'missing',
      'orphan note': (j) => j['notes']['missing'] = 'note',
      'orphan event': (j) => j['events'][0]['entryId'] = 'missing',
      'orphan member': (j) =>
          j['books'][0]['members'][0]['entryId'] = 'missing',
      'unknown setting': (j) => j['settings']['surprise'] = true,
      'clamped setting': (j) => j['settings']['roundSize'] = 0,
      'wrong setting type': (j) => j['settings']['notifications'] = 'yes',
      'font scale out of range': (j) => j['settings']['fontScale'] = 99,
      'unknown theme': (j) => j['settings']['theme'] = 'invalid',
      'unknown order': (j) => j['settings']['learningOrder'] = 'invalid',
      'orphan active book': (j) => j['settings']['activeBookId'] = 'missing',
      'bad session mode': (j) => j['session']['mode'] = 'invalid',
      'bad session ids': (j) => j['session']['ids'] = [17],
      'orphan session ids': (j) => j['session']['ids'] = ['missing'],
      'orphan session book': (j) => j['session']['bookId'] = 'missing',
      'session index overflow': (j) => j['session']['index'] = 2,
      'session invalid date': (j) => j['session']['startedAt'] = 'not-date',
      'session verification overflow': (j) =>
          j['session']['verificationIndex'] = 1,
      'session invalid result': (j) => j['session']['result'] = {
        'index': 0,
        'selected': '0',
        'correct': true,
      },
      'session invalid result correct': (j) =>
          j['session']['result'] = {'index': 0, 'selected': 0, 'correct': 1},
      'session invalid typing input': (j) => j['session']['typingResult'] = {
        'index': 0,
        'input': 12,
        'correct': true,
      },
      'session mode mismatch': (j) => j['sessions'] = {
        'quick': {
          'mode': 'formal',
          'ids': ['cat'],
          'index': 0,
        },
      },
      'unknown session mode': (j) => j['sessions'] = {
        'cram': {
          'mode': 'cram',
          'ids': ['cat'],
          'index': 0,
        },
      },
      'future backup': (j) => j['version'] = 2,
    };
    for (final item in malformed.entries) {
      test('rejects malformed backup: ${item.key}', () {
        final json = jsonDecode(
          BackupCodec.encode(_validSnapshot()),
        ) as Map<String, dynamic>;
        item.value(json);
        expect(
          () => BackupCodec.decode(jsonEncode(json)),
          throwsFormatException,
        );
      });
    }
    test('encode rejects invalid typed snapshot before save', () {
      final invalid = _validSnapshot();
      invalid.settings.roundSize = 0;
      expect(() => BackupCodec.encode(invalid), throwsFormatException);
      invalid.settings.roundSize = 5;
      invalid.cards['cat'] = ReviewCard(
        entryId: 'cat',
        due: DateTime.utc(2026),
        reviews: -1,
      );
      expect(() => BackupCodec.encode(invalid), throwsFormatException);
      invalid.cards.clear();
      invalid.session['result'] = {
        'index': 0,
        'selected': 'bad',
        'correct': true,
      };
      expect(() => BackupCodec.encode(invalid), throwsFormatException);
      invalid.session.remove('result');
      invalid.sessions['cram'] = {
        'mode': 'cram',
        'ids': <String>[],
        'index': 0,
      };
      expect(() => BackupCodec.encode(invalid), throwsFormatException);
      invalid.sessions.remove('cram');
      invalid.sessions['quick'] = {
        'mode': 'formal',
        'ids': <String>[],
        'index': 0,
      };
      expect(() => BackupCodec.encode(invalid), throwsFormatException);
    });

    test(
      'merges definitions, preserves duplicate events, and restores backup',
      () async {
        final first = ImportParser.parse(
          '[{"word":"Cat","meaning":"猫","example":"A cat."}]',
          'one.json',
        );
        final second = ImportParser.parse(
          '[{"word":"cat"},{"word":"dog","meaning":"狗"}]',
          'two.json',
        );
        final storage = MemoryStorage();
        await storage.importBook(first);
        await storage.importBook(second);
        var snapshot = await storage.load();
        expect(snapshot.entries['cat']?.meaning, '猫');
        expect(snapshot.entries['cat']?.example, 'A cat.');
        expect(snapshot.entries['dog']?.meaning, '狗');

        final event = LearningEvent(
          id: 'event-1',
          entryId: 'cat',
          kind: 'formal',
          at: DateTime.utc(2026, 1, 1),
          correct: true,
        );
        final card = ReviewCard(
          entryId: 'cat',
          due: DateTime.utc(2026, 1, 2),
          seen: true,
          reviews: 1,
        );
        await storage.commitLearning(card, event);
        await storage.commitLearning(
          ReviewCard(
            entryId: 'cat',
            due: DateTime.utc(2030),
            seen: true,
            reviews: 99,
          ),
          event,
        );
        snapshot = await storage.load();
        expect(snapshot.events, hasLength(1));
        expect(snapshot.cards['cat']?.reviews, 1);

        final notification = LearningEvent(
          id: 'notification-1',
          entryId: 'dog',
          kind: 'notification_requested',
          at: DateTime.utc(2026, 1, 1),
        );
        await storage.commitLearning(
          ReviewCard(entryId: 'dog', due: DateTime.utc(2026), seen: true),
          notification,
        );
        expect((await storage.load()).cards.containsKey('dog'), isFalse);

        final encoded = BackupCodec.encode(await storage.load());
        final restored = BackupCodec.decode(encoded);
        expect(restored.entries.keys, containsAll(['cat', 'dog']));
        final tampered = jsonDecode(encoded) as Map<String, dynamic>;
        (tampered['entries'] as List).first['id'] = 'missing-id';
        expect(
          () => BackupCodec.decode(jsonEncode(tampered)),
          throwsFormatException,
        );
        await storage.dispose();
      },
    );
  });

  test('copy style serializes both allowed values and defaults missing legacy field', () {
    expect(AppSettings().copyStyle, 'plain');
    expect(AppSettings.fromJson({}).copyStyle, 'plain');
    for (final style in ['plain', 'cute']) {
      final snapshot = _validSnapshot();
      snapshot.settings.copyStyle = style;
      expect(AppSettings.fromJson(snapshot.settings.toJson()).copyStyle, style);
      expect(snapshot.clone().settings.copyStyle, style);
      expect(
        BackupCodec.decode(BackupCodec.encode(snapshot)).settings.copyStyle,
        style,
      );
    }
    final legacy = _validSnapshot().toJson();
    legacy['settings'].remove('copyStyle');
    final settingsBefore = Map<String, dynamic>.from(legacy['settings'] as Map);
    final migrated = BackupCodec.decode(jsonEncode(legacy));
    expect(migrated.settings.copyStyle, 'plain');
    final settingsAfter = migrated.settings.toJson()..remove('copyStyle');
    expect(settingsAfter, settingsBefore);
    expect(legacy['settings'].containsKey('copyStyle'), false);
  });
  test('copy style rejects unknown values and invalid types strictly', () {
    for (final value in ['invalid', '', 'Cute', true, 1, null]) {
      final raw = _validSnapshot().toJson();
      raw['settings']['copyStyle'] = value;
      expect(() => BackupCodec.decode(jsonEncode(raw)), throwsFormatException);
    }
    final invalid = _validSnapshot();
    invalid.settings.copyStyle = 'invalid';
    expect(() => BackupCodec.encode(invalid), throwsFormatException);
  });

  test('per-mode sessions migrate legacy backups and round-trip', () {
    final raw = _validSnapshot().toJson();
    expect(raw['activeSessionMode'], 'quick');
    expect((raw['sessions'] as Map)['quick'], raw['session']);
    final decoded = BackupCodec.decode(jsonEncode(raw));
    expect(decoded.sessions.keys, ['quick']);
    expect(decoded.activeSessionMode, 'quick');
    decoded.sessions['typing'] = {
      'mode': 'typing',
      'ids': ['cat'],
      'index': 1,
      'bookId': 'book-1',
    };
    decoded.activeSessionMode = 'typing';
    final again = BackupCodec.decode(BackupCodec.encode(decoded));
    expect(again.sessions.keys.toSet(), {'quick', 'typing'});
    expect(again.activeSessionMode, 'typing');
    expect(again.session['index'], 1);
    expect(again.sessions['quick']!['mode'], 'quick');
    final legacy = jsonDecode(
      BackupCodec.encode(_validSnapshot()),
    ) as Map<String, dynamic>;
    legacy.remove('sessions');
    legacy.remove('activeSessionMode');
    legacy['session'] = {
      'mode': 'typing',
      'ids': ['cat'],
      'index': 1,
      'bookId': 'book-1',
    };
    final migrated = BackupCodec.decode(jsonEncode(legacy));
    expect(migrated.activeSessionMode, 'typing');
    expect(migrated.sessions['typing']!['index'], 1);
    expect(migrated.sessions.keys, ['typing']);
    final sessionsOnly = jsonDecode(
      BackupCodec.encode(_validSnapshot()),
    ) as Map<String, dynamic>;
    sessionsOnly.remove('session');
    sessionsOnly['sessions'] = {
      'formal': {
        'mode': 'formal',
        'ids': ['cat'],
        'index': 0,
      },
    };
    sessionsOnly['activeSessionMode'] = 'formal';
    final normalized = BackupCodec.decode(jsonEncode(sessionsOnly));
    expect(normalized.session['mode'], 'formal');
  });
  test('legacy settings and session migrate before strict validation', () {
    final raw = _validSnapshot().toJson()
      ..remove('sessions')
      ..remove('activeSessionMode');
    raw['settings'] = {'theme': 'light', 'activeBookId': 'book-1'};
    raw['session']['result'] = {'index': 0, 'selected': 0, 'correct': true};
    final saved = BackupCodec.decode(jsonEncode(raw));
    expect(saved.settings.theme, 'light');
    expect(saved.settings.autoTts, false);
    expect(saved.settings.copyStyle, 'plain');
    expect(saved.settings.roundSize, 50);
    expect(saved.session['history']['0']['result']['correct'], true);
    raw['settings']['autoTts'] = 'no';
    expect(() => BackupCodec.decode(jsonEncode(raw)), throwsFormatException);
  });
  test(
    'history rejects malformed indices labels results and orphan options',
    () {
      for (final question in <Map<String, dynamic>>[
        {
          'options': ['cat'],
          'correctIndex': 1,
        },
        {
          'options': ['cat'],
          'optionLabels': [12],
        },
        {
          'options': ['cat'],
          'labels': [],
        },
        {
          'options': ['missing'],
        },
        {
          'options': ['cat'],
          'result': {'index': 0, 'selected': 1, 'correct': true},
        },
        {
          'typingResult': {'index': 1, 'input': 'cat', 'correct': true},
        },
        {
          'quickResult': {'familiar': 'yes'},
        },
      ]) {
        final snapshot = _validSnapshot();
        snapshot.session['history'] = {'0': question};
        expect(() => BackupCodec.encode(snapshot), throwsFormatException);
      }
      for (final alias in ['labels', 'optionLabels']) {
        final snapshot = _validSnapshot();
        snapshot.session['history'] = {
          '0': {
            'options': ['cat'],
            alias: ['猫'],
            'correctIndex': 0,
          },
        };
        expect(
          BackupCodec.decode(BackupCodec.encode(snapshot))
              .session['history']['0'][alias],
          ['猫'],
        );
      }
    },
  );

  test('CSV rich fields roundtrip and original morphology helpers', () {
    final preview = ImportParser.parse(
      'word,meaning,usage,root,synonyms\nhelp,帮助,"help, me",help,assist\n',
      'rich.csv',
    );
    final exported = ImportParser.exportCsv(preview.book, preview.entries);
    final restored = ImportParser.parse(exported, 'restored.csv');
    expect(
      restored.entries['help']!.toJson(),
      preview.entries['help']!.toJson(),
    );
    expect(OfflineMorphology.hints('unhelpful'), isNotEmpty);
    const help = WordEntry(id: 'help', word: 'help', meaning: '帮助');
    const helpful = WordEntry(id: 'helpful', word: 'helpful', meaning: '有帮助');
    expect(OfflineMorphology.family(help, [help, helpful]), hasLength(2));
  });

  group('Windows SQLite real files', () {
    test(
      'per-mode sessions persist independently and drop the legacy row',
      () async {
        await _withFileStorage((storage, path) async {
          await storage.replace(_validSnapshot());
          await storage.saveSessions({
            'quick': {
              'mode': 'quick',
              'ids': ['cat'],
              'index': 0,
              'bookId': 'book-1',
            },
            'typing': {
              'mode': 'typing',
              'ids': ['cat'],
              'index': 1,
              'bookId': 'book-1',
            },
          }, activeSessionMode: 'typing');
          await storage.dispose();
          final reopened = await SqliteStorage.open(databasePath: path);
          try {
            final saved = await reopened.load();
            expect(saved.activeSessionMode, 'typing');
            expect(saved.session['index'], 1);
            expect(saved.sessions.keys.toSet(), {'quick', 'typing'});
            final raw = await databaseFactoryFfi.openDatabase(
              path,
              options: OpenDatabaseOptions(singleInstance: false),
            );
            try {
              final rows = await raw.query('settings');
              final keys = rows.map((row) => row['key']).toList();
              expect(keys, isNot(contains('session')));
              expect(keys, contains('sessions'));
            } finally {
              await raw.close();
            }
            await expectLater(
              reopened.saveSessions({
                'quick': {
                  'mode': 'quick',
                  'ids': ['missing'],
                  'index': 0,
                },
              }, activeSessionMode: 'quick'),
              throwsFormatException,
            );
            expect((await reopened.load()).sessions.keys.toSet(), {
              'quick',
              'typing',
            });
          } finally {
            await reopened.dispose();
          }
        });
      },
    );

    test('persists settings, notes, cards, session, backup and notification handling', () async {
      await _withFileStorage((storage, path) async {
        await storage.replace(_validSnapshot());
        await storage.saveNote('cat', 'persisted note');
        final settings = (await storage.load()).settings..theme = 'dark';
        await storage.saveSettings(settings);
        final cardBefore = (await storage.load()).cards['cat']!.toJson();
        for (final kind in [
          'notification_requested',
          'notification_verified_request',
        ]) {
          await storage.commitLearning(
            ReviewCard(
              entryId: 'cat',
              due: DateTime.utc(2030),
              reviews: 99,
              seen: true,
            ),
            LearningEvent(
              id: kind,
              entryId: 'cat',
              kind: kind,
              at: DateTime.utc(2026),
            ),
          );
        }
        expect((await storage.load()).cards['cat']!.toJson(), cardBefore);
        await storage.dispose();
        final reopened = await SqliteStorage.open(databasePath: path);
        try {
          final saved = await reopened.load();
          expect(saved.settings.theme, 'dark');
          expect(saved.notes['cat'], 'persisted note');
          expect(saved.session, _validSnapshot().session);
          expect(saved.events, hasLength(3));
          expect(saved.cards['cat']!.toJson(), cardBefore);
          await reopened.replace(BackupCodec.decode(BackupCodec.encode(saved)));
          expect((await reopened.load()).notes, saved.notes);
        } finally {
          await reopened.dispose();
        }
      });
    });

    test('legacy database settings and session migrate on load without rewriting payload', () async {
      await _withFileStorage((storage, path) async {
        await storage.replace(_validSnapshot());
        final raw = await databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        try {
          final oldSettings = jsonEncode({
            'theme': 'light',
            'activeBookId': 'book-1',
            'roundSize': 5,
          });
          final oldSession = _validSnapshot().session;
          oldSession['typingResult'] = {
            'index': 0,
            'input': 'cat',
            'correct': true,
          };
          await raw.update(
            'settings',
            {'payload': oldSettings},
            where: 'key = ?',
            whereArgs: ['app'],
          );
          await raw.delete(
            'settings',
            where: 'key = ?',
            whereArgs: ['sessions'],
          );
          await raw.insert('settings', {
            'key': 'session',
            'payload': jsonEncode(oldSession),
          });
          final loaded = await storage.load();
          expect(loaded.settings.roundSize, 5);
          expect(loaded.settings.autoTts, false);
          expect(loaded.settings.copyStyle, 'plain');
          expect(
            loaded.session['history']['0']['typingResult']['input'],
            'cat',
          );
          expect(
            (await raw.query(
              'settings',
              where: 'key = ?',
              whereArgs: ['app'],
            )).single['payload'],
            oldSettings,
          );
          expect(
            (await raw.query(
              'settings',
              where: 'key = ?',
              whereArgs: ['session'],
            )).single['payload'],
            jsonEncode(oldSession),
          );
        } finally {
          await raw.close();
        }
      });
    });

    test(
      'rolls back learning card/event/session when session is malformed',
      () async {
        await _withFileStorage((storage, path) async {
          await storage.replace(_validSnapshot());
          final before = _content(await storage.load());
          await expectLater(
            storage.commitLearning(
              ReviewCard(entryId: 'cat', due: DateTime.utc(2030), reviews: 3),
              LearningEvent(
                id: 'rollback',
                entryId: 'cat',
                kind: 'formal',
                at: DateTime.utc(2026),
              ),
              sessions: {
                'quick': {
                  'mode': 'quick',
                  'ids': ['cat'],
                  'index': 3,
                },
              },
              activeSessionMode: 'quick',
            ),
            throwsFormatException,
          );
          expect(_content(await storage.load()), before);
          await expectLater(
            storage.saveSettings(AppSettings(roundSize: 0)),
            throwsFormatException,
          );
          await expectLater(
            storage.saveSessions({
              'quick': {
                'mode': 'quick',
                'ids': ['missing'],
                'index': 0,
              },
            }, activeSessionMode: 'quick'),
            throwsFormatException,
          );
          expect(_content(await storage.load()), before);
        });
      },
    );

    test('batch failure rolls back replacement and atomic import activeBook; enforces foreign keys', () async {
      await _withFileStorage((storage, path) async {
        await storage.replace(_validSnapshot());
        final before = _content(await storage.load());
        final raw = await databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        try {
          await raw.execute(
            "CREATE TRIGGER fail_books BEFORE INSERT ON books BEGIN SELECT RAISE(ABORT, 'injected disk failure'); END",
          );
          final incoming = ImportParser.parse('dog\t狗', 'incoming.txt');
          await expectLater(
            storage.importBook(incoming),
            throwsA(isA<DatabaseException>()),
          );
          expect(_content(await storage.load()), before);
          await expectLater(
            storage.replace(_validSnapshot()),
            throwsA(isA<DatabaseException>()),
          );
          expect(_content(await storage.load()), before);
          await raw.execute('DROP TRIGGER fail_books');
          await raw.execute(
            "CREATE TRIGGER orphan_member AFTER INSERT ON books BEGIN INSERT INTO book_members(book_id, entry_id, unit, position) VALUES (NEW.id, 'missing', 'unit', 999); END",
          );
          await expectLater(
            storage.importBook(incoming),
            throwsA(isA<DatabaseException>()),
          );
          expect(_content(await storage.load()), before);
          await raw.execute('DROP TRIGGER orphan_member');
          await storage.importBook(incoming);
          expect(
            (await storage.load()).settings.activeBookId,
            incoming.book.id,
          );
        } finally {
          await raw.close();
        }
      });
    });

    test(
      'future user_version is rejected without deleting or changing database',
      () async {
        await _withFileStorage((storage, path) async {
          await storage.replace(_validSnapshot());
          await storage.dispose();
          final raw = await databaseFactoryFfi.openDatabase(
            path,
            options: OpenDatabaseOptions(singleInstance: false),
          );
          await raw.execute('PRAGMA user_version = 2');
          await raw.close();
          final before = await File(path).readAsBytes();
          await expectLater(
            SqliteStorage.open(databasePath: path),
            throwsA(anyOf(isA<StateError>(), isA<DatabaseException>())),
          );
          expect(await File(path).readAsBytes(), before);
          final check = await databaseFactoryFfi.openDatabase(
            path,
            options: OpenDatabaseOptions(singleInstance: false),
          );
          try {
            expect(
              (await check.rawQuery('PRAGMA user_version'))
                  .single
                  .values
                  .single,
              2,
            );
            expect(await check.query('entries'), hasLength(1));
            expect(await check.query('books'), hasLength(1));
          } finally {
            await check.close();
          }
        });
      },
    );

    test('deleting one book preserves shared learning and removes only orphan data', () async {
      await _withFileStorage((storage, path) async {
        await storage.replace(_validSnapshot());
        final incoming = ImportParser.parse('cat\t猫\ndog\t狗', 'two.txt');
        await storage.importBook(incoming);
        await storage.saveNote('dog', 'orphan note');
        await storage.commitLearning(
          ReviewCard(entryId: 'dog', due: DateTime.utc(2026)),
          LearningEvent(
            id: 'dog-event',
            entryId: 'dog',
            kind: 'view',
            at: DateTime.utc(2026),
          ),
        );
        await storage.deleteBook(incoming.book.id);
        final saved = await storage.load();
        expect(saved.entries.keys, ['cat']);
        expect(saved.cards.keys, ['cat']);
        expect(saved.notes.keys, ['cat']);
        expect(saved.events.map((event) => event.id), ['event-1']);
        expect(saved.settings.activeBookId, 'book-1');
        await storage.deleteBook('book-1');
        final empty = await storage.load();
        expect(empty.books, isEmpty);
        expect(empty.entries, isEmpty);
        expect(empty.session, isEmpty);
        expect(empty.settings.activeBookId, '');
      });
    });

    test('benchmarks generated 2331-member import, preserves all original positions after reopen', () async {
      await _withFileStorage((storage, path) async {
        final timer = Stopwatch()..start();
        final preview = ImportParser.parse(
          _syntheticChapterFixture(),
          'synthetic.json',
        );
        final parseMs = timer.elapsedMilliseconds;
        timer.reset();
        await storage.importBook(preview);
        final importMs = timer.elapsedMilliseconds;
        timer.reset();
        final saved = await storage.load();
        final loadMs = timer.elapsedMilliseconds;
        expect(saved.entries, hasLength(2329));
        expect(saved.settings.activeBookId, preview.book.id);
        expect(saved.books.single.toJson(), preview.book.toJson());
        await storage.dispose();
        final reopened = await SqliteStorage.open(databasePath: path);
        try {
          expect(
            (await reopened.load()).books.single.toJson(),
            preview.book.toJson(),
          );
        } finally {
          await reopened.dispose();
        }
        // Report measurements, not a fragile wall-clock performance assertion.
        // ignore: avoid_print
        print(
          'SQLite Windows real-file benchmark: 2331 members/2329 entries; parse=${parseMs}ms import=${importMs}ms load=${loadMs}ms',
        );
      });
    });
  }, skip: !Platform.isWindows ? 'Requires Windows FFI SQLite' : false);

  test(
    'SQLite in-memory storage persists and deduplicates events when available',
    () async {
      if (!Platform.isWindows &&
          !Platform.isAndroid &&
          !Platform.isLinux &&
          !Platform.isMacOS) {
        return;
      }
      final storage = await SqliteStorage.open(databasePath: ':memory:');
      final preview = ImportParser.parse(
        '[{"word":"persist","meaning":"持久"}]',
        'db.json',
      );
      await storage.importBook(preview);
      final event = LearningEvent(
        id: 'same-id',
        entryId: 'persist',
        kind: 'view',
        at: DateTime.utc(2026),
        action: 'new',
      );
      await storage.commitLearning(
        ReviewCard(entryId: 'persist', due: DateTime.utc(2026), seen: true),
        event,
      );
      await storage.commitLearning(
        ReviewCard(
          entryId: 'persist',
          due: DateTime.utc(2030),
          seen: true,
          reviews: 3,
        ),
        event,
      );
      final snapshot = await storage.load();
      expect(snapshot.events, hasLength(1));
      expect(snapshot.cards['persist']?.reviews, 0);
      await storage.dispose();
    },
  );
}

AppSnapshot _validSnapshot() => AppSnapshot(
  books: [
    WordBook(
      id: 'book-1',
      title: 'Book',
      importedAt: DateTime.utc(2026),
      members: const [BookMember(entryId: 'cat', unit: 'unit 1', position: 1)],
    ),
  ],
  entries: const {'cat': WordEntry(id: 'cat', word: 'Cat', meaning: '猫')},
  cards: {
    'cat': ReviewCard(
      entryId: 'cat',
      due: DateTime.utc(2026),
      seen: true,
      reviews: 1,
    ),
  },
  events: [
    LearningEvent(
      id: 'event-1',
      entryId: 'cat',
      kind: 'formal',
      at: DateTime.utc(2026),
      correct: true,
    ),
  ],
  notes: {'cat': 'note'},
  settings: AppSettings(activeBookId: 'book-1'),
  session: {
    'mode': 'quick',
    'ids': ['cat'],
    'index': 0,
    'bookId': 'book-1',
    'startedAt': DateTime.utc(2026).toIso8601String(),
  },
);

Map<String, dynamic> _content(AppSnapshot snapshot) =>
    snapshot.toJson()..remove('exportedAt');

Future<void> _withFileStorage(
  Future<void> Function(SqliteStorage, String) test,
) async {
  final directory = await Directory.systemTemp.createTemp(
    'wordnest-data-test-',
  );
  final path = '${directory.path}/wordnest.sqlite';
  final storage = await SqliteStorage.open(databasePath: path);
  try {
    await test(storage, path);
  } finally {
    await storage.dispose();
    await directory.delete(recursive: true);
  }
}

// Original generated test data: no external vocabulary or personal metadata.
// 10 chapters, 2331 ordered memberships, 2329 distinct synthetic identifiers.
String _syntheticChapterFixture() {
  const sizes = [233, 233, 233, 233, 233, 233, 233, 233, 233, 234];
  var position = 0;
  final chapters = <Map<String, dynamic>>[];
  for (var unit = 0; unit < sizes.length; unit++) {
    final words = <Map<String, String>>[];
    for (var i = 0; i < sizes[unit]; i++) {
      final ordinal = position++;
      final id = ordinal >= 2329 ? ordinal - 2329 : ordinal;
      words.add({'w': 'synthetic$id', 'tr': 'Original test meaning $id'});
    }
    chapters.add({'name': 'unit ${unit + 1}', 'words': words});
  }
  return jsonEncode({
    'book_name': 'Original generated parser fixture',
    'source': 'WordNest self-authored test data',
    'chapters': chapters,
  });
}
