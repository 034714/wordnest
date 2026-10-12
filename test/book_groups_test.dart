import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wordnest/data/importer.dart';
import 'package:wordnest/data/storage.dart';
import 'package:wordnest/domain/controller.dart';
import 'package:wordnest/domain/models.dart';
import 'package:wordnest/features/shared_widgets.dart';

class RejectReplace extends MemoryStorage {
  bool reject = false;
  @override
  Future<void> replace(AppSnapshot snapshot) async {
    if (reject) throw StateError('disk full');
    await super.replace(snapshot);
  }
}

Future<AppController> setup(AppStorage storage) async {
  final c = AppController(storage);
  await c.initialize();
  expect(
    await c.importBook(ImportParser.parse('cat\t猫\ndog\t狗', 'source.txt')),
    true,
  );
  return c;
}

void main() {
  test(
    'named books copy/move preserve shared entry notes cards and events',
    () async {
      final c = await setup(MemoryStorage());
      final source = c.book!.id;
      await c.note('cat', 'shared note');
      await c.review('cat', kind: 'view', advanceSession: false);
      final before = c.card('cat').toJson();
      expect(await c.createBook('  我的分组  '), true);
      final target = c.book!.id;
      expect(c.book!.title, '我的分组');
      expect(await c.createBook('我的分组'), false);
      expect(await c.createBook('生词本'), false);
      expect(await c.renameBook(target, '动物'), true);
      expect(await c.copyWord('cat', target), true);
      expect(await c.copyWord('cat', target), true);
      expect(c.book!.members, hasLength(1));
      expect(c.card('cat').toJson(), before);
      expect(c.queue('quick'), isEmpty);
      expect(c.queue('typing'), ['cat']);
      expect(await c.moveWord('cat', source, target), true);
      expect(c.state.books.firstWhere((b) => b.id == source).uniqueIds, [
        'dog',
      ]);
      expect(c.state.notes['cat'], 'shared note');
      expect(c.state.events, hasLength(1));
      expect(await c.setWordGroups('cat', {}), true);
      expect(c.groupsFor('cat'), isEmpty);
      expect(c.state.entries['cat'], isNotNull);
      expect(c.card('cat').toJson(), before);
      expect(await c.deleteBook(target), true);
      expect(c.state.notes['cat'], 'shared note');
      expect(await c.copyWord('cat', source), true);
      expect(await c.deleteBook(source), true);
      expect(c.state.entries, hasLength(2));
      expect(c.state.events, hasLength(1));
      expect(
        BackupCodec.decode(BackupCodec.encode(c.state)).notes['cat'],
        'shared note',
      );
    },
  );

  test('virtual notebook sessions active selection backup and error synchronization', () async {
    final storage = MemoryStorage();
    final c = await setup(storage);
    await c.review(
      'cat',
      kind: 'formal',
      correct: false,
      advanceSession: false,
    );
    await c.updateSettings((s) => s.activeBookId = notebookBookId);
    expect(c.words.map((w) => w.id), ['cat']);
    expect(c.queue('typing'), ['cat']);
    expect(await c.begin('formal', resume: false, ids: ['cat']), true);
    await c.review('cat', kind: 'formal', correct: true, advanceSession: false);
    await c.review('cat', kind: 'formal', correct: true, advanceSession: false);
    expect(c.words, isEmpty);
    expect(c.sessionIds, ['cat']); // frozen queue is still valid after removal
    expect(c.resumable, true);
    final restored = BackupCodec.decode(BackupCodec.encode(c.state));
    expect(restored.settings.activeBookId, notebookBookId);
    expect(await c.restore(restored), true);
    final next = AppController(storage);
    await next.initialize();
    expect(next.book!.id, notebookBookId);
    expect(next.resumable, true);
    expect(await next.copyWord('dog', notebookBookId), true);
    expect(next.words.map((w) => w.id), ['dog']);
    expect(await next.renameBook(notebookBookId, '其他'), false);
    expect(await next.deleteBook(notebookBookId), false);
  });

  test(
    'failed membership edit rolls back all relations and permits retry',
    () async {
      final storage = RejectReplace();
      final c = await setup(storage);
      final source = c.book!.id;
      await c.createBook('目标');
      final target = c.book!.id;
      storage.reject = true;
      expect(await c.moveWord('cat', source, target), false);
      expect(c.groupsFor('cat').map((b) => b.id), [source]);
      expect((await storage.load()).books.first.uniqueIds, contains('cat'));
      storage.reject = false;
      expect(await c.moveWord('cat', source, target), true);
      expect(c.groupsFor('cat').map((b) => b.id), [target]);
      expect(await c.setWordGroups('cat', {source, 'missing'}), false);
      expect(c.groupsFor('cat').map((b) => b.id), [target]);
    },
  );

  test(
    'SQLite membership transaction rollback and virtual session reopen',
    () async {
      if (!Platform.isWindows) return;
      final dir = await Directory.systemTemp.createTemp('book-groups-');
      final path = '${dir.path}/test.sqlite';
      final storage = await SqliteStorage.open(databasePath: path);
      try {
        final c = await setup(storage);
        final source = c.book!.id;
        await c.createBook('目标');
        final target = c.book!.id;
        final raw = await databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        try {
          await raw.execute(
            "CREATE TRIGGER fail_members BEFORE INSERT ON book_members BEGIN SELECT RAISE(ABORT, 'injected failure'); END",
          );
          expect(await c.moveWord('cat', source, target), false);
          expect((await storage.load()).books.first.uniqueIds, contains('cat'));
          expect(c.groupsFor('cat').map((b) => b.id), [source]);
          await raw.execute('DROP TRIGGER fail_members');
        } finally {
          await raw.close();
        }
        expect(await c.moveWord('cat', source, target), true);
        await c.addToNotebook('cat');
        expect(
          await c.updateSettings((s) => s.activeBookId = notebookBookId),
          true,
        );
        expect(await c.begin('typing', resume: false), true);
        await c.review('cat', kind: 'typing', correct: true);
        await storage.dispose();
        final reopened = await SqliteStorage.open(databasePath: path);
        try {
          final next = AppController(reopened);
          await next.initialize();
          expect(next.error, isNull);
          expect(next.book!.id, notebookBookId);
          expect(next.sessionIndex, 1);
          expect(next.words.map((w) => w.id), ['cat']);
          expect(
            BackupCodec.decode(BackupCodec.encode(next.state)).session['ids'],
            ['cat'],
          );
        } finally {
          await reopened.dispose();
        }
      } finally {
        await storage.dispose();
        await dir.delete(recursive: true);
      }
    },
  );

  testWidgets('details exposes grouping without writing a note', (
    tester,
  ) async {
    final c = await setup(MemoryStorage());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showWordDetails(context, c, c.words.first),
              child: const Text('详情'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加 / 复制 / 移动 · 编辑分组'));
    await tester.pumpAndSettle();
    expect(find.text('保存分组'), findsOneWidget);
    expect(find.text('复制到词书'), findsOneWidget);
    expect(find.text('移动到词书'), findsOneWidget);
    expect(c.state.notes, isEmpty);
  });
}
