import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/app.dart';
import 'package:wordnest/data/storage.dart';
import 'package:wordnest/domain/controller.dart';
import 'package:wordnest/domain/models.dart';
import 'package:wordnest/features/shared_widgets.dart';
import 'package:wordnest/platform/appearance_service.dart';

class DelayedSettingsStorage extends MemoryStorage {
  Completer<void>? gate;
  int writes = 0;

  @override
  Future<void> saveSettings(AppSettings settings) async {
    writes++;
    await gate?.future;
    await super.saveSettings(settings);
  }
}

class TestAppearanceService extends AppearanceService {
  TestAppearanceService();
  int loads = 0;

  @override
  Future<Uint8List?> loadBackground(String asset) async {
    loads++;
    return base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=',
    );
  }
}

void main() {
  setUp(() {
    backgroundOpacityPreview.value = null;
    surfaceOpacityPreview.value = null;
  });
  tearDown(() {
    backgroundOpacityPreview.value = null;
    surfaceOpacityPreview.value = null;
  });

  Future<AppController> showSettings(
    WidgetTester tester,
    DelayedSettingsStorage storage,
    TestAppearanceService appearance, {
    String materialMode = 'solid',
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController(storage);
    await c.initialize();
    await c.updateSettings((s) {
      s.materialMode = materialMode;
      s.surfaceOpacity = 1;
      s.backgroundOpacity = .8;
      s.backgroundAsset = 'bg-${'a' * 32}.png';
    });
    await tester.pumpWidget(
      WordNestApp(controller: c, native: false, appearanceService: appearance),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('偏好设置'));
    await tester.pumpAndSettle();
    return c;
  }

  Finder sliderFor(String key) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(Slider),
  );

  void expectSurfaces(WidgetTester tester, double opacity) {
    final surfaces = find.byType(SurfaceMaterial);
    expect(surfaces, findsWidgets);
    for (final surface in surfaces.evaluate()) {
      final material = find
          .descendant(
            of: find.byWidget(surface.widget),
            matching: find.byType(Material),
          )
          .first;
      expect(
        tester.widget<Material>(material).color!.a,
        closeTo(opacity, 1 / 255),
      );
    }
  }

  for (final mode in ['solid', 'glass']) {
    testWidgets(
      '$mode drag updates all surfaces locally and holds delayed save',
      (tester) async {
        final storage = DelayedSettingsStorage();
        final appearance = TestAppearanceService();
        final c = await showSettings(
          tester,
          storage,
          appearance,
          materialMode: mode,
        );
        final slider = sliderFor('surface-opacity');
        await tester.ensureVisible(slider);
        await tester.pumpAndSettle();
        final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
        final sliderState = tester.state(slider);
        final filters = tester
            .widgetList<BackdropFilter>(find.byType(BackdropFilter))
            .toList();
        final writes = storage.writes;
        storage.gate = Completer<void>();
        final rect = tester.getRect(slider);
        final gesture = await tester.startGesture(
          Offset(rect.right - 24, rect.center.dy),
        );
        await gesture.moveBy(const Offset(-80, 0));
        await tester.pump();
        final first = surfaceOpacityPreview.value!;
        expect(first, lessThan(1));
        expectSurfaces(tester, first);
        expect(
          identical(tester.widget<MaterialApp>(find.byType(MaterialApp)), app),
          isTrue,
        );
        expect(identical(tester.state(slider), sliderState), isTrue);
        final currentFilters = tester
            .widgetList<BackdropFilter>(find.byType(BackdropFilter))
            .toList();
        expect(currentFilters.length, filters.length);
        for (var i = 0; i < filters.length; i++) {
          expect(identical(currentFilters[i], filters[i]), isTrue);
        }
        await gesture.moveBy(const Offset(-40, 0));
        await tester.pump();
        final next = surfaceOpacityPreview.value!;
        expect(next, lessThan(first));
        expect(tester.widget<Slider>(slider).value, next);
        expect(storage.writes, writes);
        await gesture.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(c.saving, isTrue);
        expect(c.settings.surfaceOpacity, 1);
        expect(surfaceOpacityPreview.value, next);
        expect(tester.widget<Slider>(slider).value, next);
        expectSurfaces(tester, next);
        expect(storage.writes, writes + 1);
        storage.gate!.complete();
        await tester.pumpAndSettle();
        expect(c.settings.surfaceOpacity, next);
        expect(surfaceOpacityPreview.value, isNull);
        expect(tester.widget<Slider>(slider).value, next);
        expect(identical(tester.state(slider), sliderState), isTrue);
        expectSurfaces(tester, next);
        expect(appearance.loads, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
      },
    );
  }

  for (final background in [false, true]) {
    for (final succeeds in [false, true]) {
      testWidgets(
        '${background ? 'background' : 'surface'} ${succeeds ? 'successful' : 'failed'} delayed save',
        (tester) async {
          final storage = DelayedSettingsStorage();
          final appearance = TestAppearanceService();
          final c = await showSettings(tester, storage, appearance);
          final slider = sliderFor(
            background ? 'background-opacity' : 'surface-opacity',
          );
          final preview = background
              ? backgroundOpacityPreview
              : surfaceOpacityPreview;
          final old = background ? .8 : 1.0;
          await tester.ensureVisible(slider);
          await tester.pumpAndSettle();
          final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
          final image = tester.widget<Image>(find.byType(Image));
          final state = tester.state(slider);
          storage.gate = Completer<void>();
          final rect = tester.getRect(slider);
          final gesture = await tester.startGesture(
            Offset(rect.right - 24, rect.center.dy),
          );
          await gesture.moveBy(const Offset(-80, 0));
          await tester.pump();
          final next = preview.value!;
          expect(next, isNot(old));
          expect(c.saving, isFalse);
          expect(tester.widget<Slider>(slider).value, next);
          if (background) {
            expect(
              tester
                  .widget<Opacity>(
                    find.byKey(const ValueKey('background-image-opacity')),
                  )
                  .opacity,
              next,
            );
            expect(
              identical(tester.widget<Image>(find.byType(Image)), image),
              isTrue,
            );
          } else {
            expectSurfaces(tester, next);
          }
          expect(
            identical(
              tester.widget<MaterialApp>(find.byType(MaterialApp)),
              app,
            ),
            isTrue,
          );
          expect(identical(tester.state(slider), state), isTrue);
          await gesture.up();
          await tester.pump();
          expect(c.saving, isTrue);
          expect(preview.value, next);
          if (succeeds) {
            storage.gate!.complete();
          } else {
            storage.gate!.completeError(StateError('disk full'));
          }
          await tester.pumpAndSettle();
          final expected = succeeds ? next : old;
          expect(preview.value, isNull);
          expect(tester.widget<Slider>(slider).value, expected);
          expect(
            background
                ? c.settings.backgroundOpacity
                : c.settings.surfaceOpacity,
            expected,
          );
          expect(
            find.text('不透明度未保存，已恢复原值。'),
            succeeds ? findsNothing : findsOneWidget,
          );
          if (background) {
            expect(
              tester
                  .widget<Opacity>(
                    find.byKey(const ValueKey('background-image-opacity')),
                  )
                  .opacity,
              expected,
            );
          } else {
            expectSurfaces(tester, expected);
          }
          expect(appearance.loads, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          c.dispose();
        },
      );
    }
  }
}
