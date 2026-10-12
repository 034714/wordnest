import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../data/importer.dart';
import 'safe_http.dart';

/// An immutable, pinned source record. Source verification is not permission
/// to redistribute: Jimmy entries explicitly retain an unknown-license notice.
class CatalogBook {
  const CatalogBook({
    required this.id,
    required this.title,
    required this.description,
    required this.url,
    required this.filename,
    required this.maxBytes,
    required this.license,
    required this.source,
    required this.attribution,
    this.category = '',
    this.scene = '',
    this.wordCount = 0,
    this.chapterCount = 0,
    this.revision = '',
    this.redistributionKnown = false,
    this.countsVerified = false,
  });

  final String id, title, description, filename, license, source, attribution;
  final String category, scene, revision;
  final Uri url;
  final int maxBytes, wordCount, chapterCount;
  final bool redistributionKnown, countsVerified;

  /// Only canonical records loaded from the bundled manifest are trusted.
  /// Copying an id/URL does not grant caller-controlled metadata any authority.
  bool get isBuiltin => CatalogService.books.contains(this);

  Uri get sourceUrl => Uri.https('github.com', '/$source/blob/$revision/${url.pathSegments.skip(3).join('/')}');
}

class CatalogDownload {
  const CatalogDownload({
    required this.book,
    required this.filename,
    required this.text,
    required this.byteLength,
  });
  final CatalogBook book;
  final String filename, text;
  final int byteLength;
}

class CatalogError implements Exception {
  const CatalogError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Downloads only pinned catalog sources, using the shared bounded, DNS/TLS
/// validated transport (including its explicit trusted-host proxy fallback).
/// Tests inject transport/resolver and never require a live network.
class CatalogService {
  CatalogService({
    AddressResolver? resolver,
    PinnedFetch? transport,
    ProxyProbe? proxyProbe,
    ProxiedFetch? proxiedFetch,
    HostnameFetch? hostnameFetch,
    this.timeout = const Duration(seconds: 20),
  }) : _resolver = resolver ?? InternetAddress.lookup,
       // ignore: prefer_initializing_formals
       _transport = transport,
       // ignore: prefer_initializing_formals
       _proxyProbe = proxyProbe,
       // ignore: prefer_initializing_formals
       _proxiedFetch = proxiedFetch,
       // ignore: prefer_initializing_formals
       _hostnameFetch = hostnameFetch;

  static const hardMaxBytes = 8 * 1024 * 1024;
  static const kylebingRevision = 'c4c6c80879ff17d7025c28fb853a4991c8e6be6a';
  static const jimmyRevision = '4d42b54e73e163cb1121aefd0cdac3c243c7a414';
  static const _allowedHost = 'raw.githubusercontent.com';
  static List<CatalogBook> _books = const [];
  static Future<List<CatalogBook>>? _loading;

  /// The immutable cached catalog, populated by list() without network access.
  static List<CatalogBook> get books => _books;

  static Future<List<CatalogBook>> _loadManifest() async {
    try {
      final root = jsonDecode(await rootBundle.loadString('assets/catalog-manifest.json')) as Map<String, dynamic>;
      if (root['format'] != 1) throw const FormatException('目录版本不受支持');
      final result = <CatalogBook>[];
      final ids = <String>{};
      for (final kind in ['kylebing', 'jimmy']) {
        final group = root[kind] as Map<String, dynamic>;
        final kyle = kind == 'kylebing';
        final repo = kyle ? 'KyleBing/english-vocabulary' : 'Jimmy-Library/Jimmy-Grammar';
        final revision = kyle ? kylebingRevision : jimmyRevision;
        if (group['repository'] != repo || group['revision'] != revision ||
            group['license'] != (kyle ? 'BSD-3-Clause' : 'unknown')) {
          throw const FormatException('目录来源或版本不匹配');
        }
        for (final record in group['books'] as List) {
          final item = record as Map<String, dynamic>;
          final id = item['id'] as String;
          final path = item['path'] as String;
          final filename = item['filename'] as String;
          final words = item['wordCount'] as int;
          final chapters = item['chapterCount'] as int;
          final bytes = item['byteLength'] as int;
          if (!ids.add(id) || !id.startsWith('$kind-') ||
              path.startsWith('/') || path.contains('\\') ||
              path.split('/').any((part) => part.isEmpty || part == '..' || part == '.') ||
              filename != path.split('/').last ||
              !(kyle ? path.endsWith('.txt') : path.startsWith('wordbooks/') && path.endsWith('.json')) ||
              words <= 0 || words > ImportParser.maxRecords || chapters <= 0 ||
              bytes <= 0 || bytes > hardMaxBytes) {
            throw const FormatException('目录词书记录无效');
          }
          final license = kyle ? 'BSD-3-Clause' : '再分发许可未确认';
          result.add(CatalogBook(
            id: id,
            title: item['title'] as String,
            description: kyle
                ? '每行“单词 + Tab + 释义”；完整原文件，重复位置保留。'
                : '原站章节 JSON（单词/释义）；数量来自上游索引，导入前检查实际缺项。',
            url: Uri.https(_allowedHost, '/$repo/$revision/$path'),
            filename: filename,
            maxBytes: kyle ? 2 * 1024 * 1024 : hardMaxBytes,
            license: license,
            source: repo,
            attribution: '$repo · ${kyle ? 'Copyright (c) 2022-2026, KyleBing' : 'Jimmy · 青山沃思'} · $license · https://github.com/$repo',
            category: item['category'] as String,
            scene: item['scene'] as String,
            wordCount: words,
            chapterCount: chapters,
            revision: revision,
            redistributionKnown: kyle,
            countsVerified: kyle,
          ));
        }
      }
      _books = List.unmodifiable(result);
      return _books;
    } catch (error) {
      _loading = null;
      throw CatalogError('内置词库目录无法读取：$error');
    }
  }

  final AddressResolver _resolver;
  final PinnedFetch? _transport;
  final ProxyProbe? _proxyProbe;
  final ProxiedFetch? _proxiedFetch;
  final HostnameFetch? _hostnameFetch;
  final Duration timeout;

  Future<List<CatalogBook>> list() => _loading ??= _loadManifest();

  Future<CatalogDownload> fetch(CatalogBook book, {int? maxBytes}) async {
    final entries = await list();
    if (!entries.contains(book)) {
      throw const CatalogError('该词表不在内置目录中，只允许内置原始来源记录。');
    }
    if (book.url.host != _allowedHost || book.url.scheme != 'https') {
      throw const CatalogError('词表来源不是允许的 HTTPS 地址。');
    }
    final limit = math.min(math.min(maxBytes ?? book.maxBytes, book.maxBytes), hardMaxBytes);
    if (limit <= 0) throw const CatalogError('下载大小限制必须大于零。');
    try {
      final response = await safeHttpGet(
        uri: book.url,
        resolver: _resolver,
        timeout: timeout,
        maxBodyBytes: limit,
        transport: _transport,
        proxyProbe: _proxyProbe,
        proxiedFetch: _proxiedFetch,
        hostnameFetch: _hostnameFetch,
      );
      if (response.statusCode != HttpStatus.ok) {
        throw CatalogError('下载失败：服务器响应 ${response.statusCode}。');
      }
      if (response.body.length > limit) {
        throw const CatalogError('下载内容超过大小限制。');
      }
      final text = utf8.decode(response.body);
      if (text.trim().isEmpty) throw const CatalogError('下载的词表内容为空。');
      final preview = ImportParser.parse(text, book.filename);
      if (preview.missingMeanings == preview.entries.length) {
        throw const CatalogError('下载的词书没有释义，不能作为学习词书导入。');
      }
      return CatalogDownload(book: book, filename: book.filename, text: text, byteLength: response.body.length);
    } on CatalogError {
      rethrow;
    } on FakeIpDnsException catch (error) {
      throw CatalogError(error.toString());
    } on FormatException catch (error) {
      throw CatalogError('下载的词表无效：$error');
    } catch (error) {
      throw CatalogError('下载词表失败：$error');
    }
  }
}
