import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/data/storage.dart';
import 'package:wordnest/domain/controller.dart';
import 'package:wordnest/domain/models.dart';
import 'package:wordnest/features/study_page.dart';

void main() {
  testWidgets('typing auto-advances after a correct answer when enabled', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.resetPhysicalSize);

    final c = AppController(MemoryStorage());
    await c.initialize();
    await c.importBook(
      ImportPreview(
        book: WordBook(
          id: 'b',
          title: 't',
          importedAt: DateTime.now(),
          members: const [
            BookMember(entryId: 'w0', unit: 'U', position: 0),
            BookMember(entryId: 'w1', unit: 'U', position: 1),
          ],
        ),
        entries: const {
          'w0': WordEntry(id: 'w0', word: 'focus', meaning: '集中'),
          'w1': WordEntry(id: 'w1', word: 'read', meaning: '阅读'),
        },
        total: 2,
        duplicates: 0,
        missingMeanings: 0,
        missingExamples: 2,
      ),
    );
    await c.updateSettings((s) {
      s.autoAdvance = true;
      s.typingReveal = false;
      s.autoTts = false;
      s.tts = false;
    });
    await c.begin('typing', ids: ['w0', 'w1']);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudyPage(
            controller: c,
            mode: 'typing',
            onBack: () async {},
            onRestart: () async {},
            onSpeak: (_) async {},
            onToggleCompact: () async {},
            onPause: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'focus');
    await tester.pump();
    await tester.tap(find.text('检查拼写 · Enter'));
    await tester.pump();
    expect(c.sessionIndex, 0, reason: 'still showing the same word');
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();
    expect(c.sessionIndex, 1, reason: 'advanced to the next word');
  });
}
