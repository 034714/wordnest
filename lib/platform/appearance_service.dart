import 'package:flutter/foundation.dart';

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';

/// Live drag previews so opacity sliders feel instant instead of applying
/// only after release (the value is still persisted on change-end).
final ValueNotifier<double?> backgroundOpacityPreview = ValueNotifier(null);
final ValueNotifier<double?> surfaceOpacityPreview = ValueNotifier(null);

class AppearanceService {
  AppearanceService({
    this.enabled = true,
    Future<Directory> Function()? supportDirectory,
    Future<String?> Function()? pickPath,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _pickPath = pickPath ?? _nativePickPath;

  static const maxBytes = 10 * 1024 * 1024;
  static const maxPixels = 16 * 1000 * 1000;
  final bool enabled;
  final Future<Directory> Function() _supportDirectory;
  final Future<String?> Function() _pickPath;

  static Future<String?> _nativePickPath() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
      allowMultiple: false,
      withData: false,
    );
    return result?.files.single.path;
  }

  Future<Directory> _directory() async {
    final support = await _supportDirectory();
    return Directory(p.join(support.path, 'appearance'));
  }

  Future<String?> pickBackground() async {
    if (!enabled) return null;
    final path = await _pickPath();
    if (path == null) return null;
    return importBackground(path);
  }

  Future<String> importBackground(String pickerPath) async {
    if (!enabled) throw StateError('本地背景图片服务未启用');
    final bytes = await _readBounded(File(pickerPath));
    final extension = await validateImage(bytes);
    final random = Random.secure();
    final token = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final asset = 'bg-$token.$extension';
    final directory = await _directory();
    await directory.create(recursive: true);
    final pending = File(p.join(directory.path, '$asset.pending'));
    try {
      await pending.writeAsBytes(bytes, flush: true);
      await pending.rename(p.join(directory.path, asset));
      return asset;
    } finally {
      if (await pending.exists()) await pending.delete();
    }
  }

  Future<Uint8List?> loadBackground(String asset) async {
    if (!enabled || asset.isEmpty || !isValidBackgroundAsset(asset)) {
      return null;
    }
    try {
      final directory = await _directory();
      final file = File(p.join(directory.path, asset));
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final bytes = await _readBounded(file);
      final extension = await validateImage(bytes);
      return asset.endsWith('.$extension') ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteBackground(String asset) async {
    if (!enabled || asset.isEmpty || !isValidBackgroundAsset(asset)) return;
    final directory = await _directory();
    final file = File(p.join(directory.path, asset));
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.file) {
      await file.delete();
    }
  }

  static Future<Uint8List> _readBounded(File file) async {
    if (await file.length() > maxBytes) {
      throw const FormatException('背景图片不能超过 10 MB，请先压缩后再选。');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(0, maxBytes + 1)) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        throw const FormatException('背景图片不能超过 10 MB，请先压缩后再选。');
      }
    }
    return builder.takeBytes();
  }

  static Future<String> validateImage(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('背景图片为空或超过 10 MB，请先压缩后再选。');
    }
    final png =
        bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a;
    final jpg =
        bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff;
    final webp =
        bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50;
    if (!png && !jpg && !webp) {
      throw const FormatException('只支持 PNG、JPEG 或 WebP 图片；HEIC/PDF/动图请先转换后再选。');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width <= 0 ||
          descriptor.height <= 0 ||
          descriptor.width * descriptor.height > maxPixels) {
        throw const FormatException('背景图片不能超过 1600 万像素');
      }
      codec = await descriptor.instantiateCodec();
      if (codec.frameCount != 1) {
        throw const FormatException('背景图片只支持静态图片');
      }
      final frame = await codec.getNextFrame();
      frame.image.dispose();
      return png
          ? 'png'
          : jpg
          ? 'jpg'
          : 'webp';
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('图片无法解码，请换一张 PNG/JPEG/WebP 图片。');
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}
