import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/storage.dart';
import 'data/default_book.dart';
import 'domain/controller.dart';
import 'app.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'ECDICT',
    ], await rootBundle.loadString('assets/ECDICT-LICENSE.txt'));
  });
  try {
    final storage = await SqliteStorage.open();
    final controller = AppController(storage);
    await controller.initialize();
    await ensureDemoBook(controller);
    runApp(WordNestApp(controller: controller));
  } catch (error) {
    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh', 'CN')],
        home: Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.storage_rounded, size: 48),
                    const SizedBox(height: 20),
                    const Text('暂时无法打开本地数据库', style: TextStyle(fontSize: 24)),
                    const SizedBox(height: 12),
                    const Text('为保护已有进度，应用没有创建替代空数据库。请检查磁盘空间或数据目录权限后重试。'),
                    const SizedBox(height: 16),
                    SelectableText('$error'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
