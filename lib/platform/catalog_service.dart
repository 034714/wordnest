import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'safe_http.dart';

/// One allowlisted public word list. Entries are compile-time constants:
/// v1 never accepts a user-supplied catalog URL. Every source repository's
/// license was verified through the GitHub license API before inclusion:
/// `KyleBing/english-vocabulary` (BSD-3-Clause), `dwyl/english-words`
/// (Unlicense/public domain), `wordnik/wordlist` (MIT) and
/// `tabatkins/wordle-list` (MIT).
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
  });

  final String id;
  final String title;
  final String description;
  final Uri url;
  final String filename;
  final int maxBytes;
  final String license;
  final String source;

  /// Display-ready credit line: repository, license and repository URL.
  final String attribution;

  /// True when this exact entry (id and URL) is in the built-in catalog.
  bool get isBuiltin =>
      CatalogService.books.any((b) => b.id == id && b.url == url);
}

/// Downloaded word list text plus the filename the importer should see.
class CatalogDownload {
  const CatalogDownload({
    required this.book,
    required this.filename,
    required this.text,
    required this.byteLength,
  });

  final CatalogBook book;
  final String filename;
  final String text;
  final int byteLength;
}

/// Chinese-language failure for catalog listing/downloading.
class CatalogError implements Exception {
  const CatalogError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Allowlisted word-list downloads reusing the same hardened transport rules
/// as update checks: http/https only, pre-validated public DNS answers only,
/// direct pinned connections with TLS for https, no proxy, manual redirect
/// validation, overall timeout and a bounded response body. Nothing is ever
/// executed. Tests must inject resolver/transport; no network in tests.
class CatalogService {
  CatalogService({
    AddressResolver? resolver,
    PinnedFetch? transport,
    this.timeout = const Duration(seconds: 20),
  }) : _resolver = resolver ?? InternetAddress.lookup,
       // Public named parameter cannot be a private initializing formal.
       // ignore: prefer_initializing_formals
       _transport = transport;

  /// Hard cap for every catalog download, independent of the update feed
  /// limit (64 KiB).
  static const hardMaxBytes = 8 * 1024 * 1024;
  static const _allowedHost = 'raw.githubusercontent.com';
  static const _kylebing = 'KyleBing/english-vocabulary';
  static const _kylebingAttribution =
      'KyleBing/english-vocabulary · BSD-3-Clause · '
      'https://github.com/KyleBing/english-vocabulary';

  static CatalogBook _kylebingBook({
    required String id,
    required String title,
    required String description,
    required String filename,
    required int maxBytes,
  }) => CatalogBook(
    id: id,
    title: title,
    description: description,
    url: Uri.parse(
      'https://raw.githubusercontent.com/$_kylebing/master/'
      '${Uri.encodeComponent(filename)}',
    ),
    filename: filename,
    maxBytes: maxBytes,
    license: 'BSD-3-Clause',
    source: _kylebing,
    attribution: _kylebingAttribution,
  );

  /// Built-in catalog. The seven KyleBing lists are `单词<TAB>释义` lines and
  /// import directly through the TXT importer. Sources without a verified
  /// permissive license are deliberately excluded (for example
  /// `zhenghaoyang24/english-vocabulary` reports no license, so it stays out).
  static final List<CatalogBook> books = List.unmodifiable(<CatalogBook>[
    _kylebingBook(
      id: 'kylebing-junior',
      title: '初中词汇（乱序）',
      description: 'KyleBing 初中词表：每行“单词 + Tab + 释义”，可直接导入。',
      filename: '1 初中-乱序.txt',
      maxBytes: 2 * 1024 * 1024,
    ),
    _kylebingBook(
      id: 'kylebing-highschool',
      title: '高中词汇（乱序）',
      description: 'KyleBing 高中词表：每行“单词 + Tab + 释义”，可直接导入。',
      filename: '2 高中-乱序.txt',
      maxBytes: 2 * 1024 * 1024,
    ),
    _kylebingBook(
      id: 'kylebing-cet4',
      title: '四级词汇（乱序）',
      description: 'KyleBing 大学英语四级词表：每行“单词 + Tab + 释义”，可直接导入。',
      filename: '3 四级-乱序.txt',
      maxBytes: 2 * 1024 * 1024,
    ),
    _kylebingBook(
      id: 'kylebing-cet6',
      title: '六级词汇（乱序）',
      description: 'KyleBing 大学英语六级词表：每行“单词 + Tab + 释义”，可直接导入。',
      filename: '4 六级-乱序.txt',
      maxBytes: 2 * 1024 * 1024,
    ),
    _kylebingBook(
      id: 'kylebing-postgrad',
      title: '考研词汇（乱序）',
      description: 'KyleBing 考研词表：每行“单词 + Tab + 释义”，可直接导入。',
      filename: '5 考研-乱序.txt',
      maxBytes: 2 * 1024 * 1024,
    ),
    _kylebingBook(
      id: 'kylebing-toefl',
      title: '托福词汇（乱序）',
      description: 'KyleBing 托福词表：每行“单词 + Tab + 释义”，可直接导入。',
      filename: '6 托福-乱序.txt',
      maxBytes: 2 * 1024 * 1024,
    ),
    _kylebingBook(
      id: 'kylebing-sat',
      title: 'SAT 词汇（乱序）',
      description: 'KyleBing SAT 词表：每行“单词 + Tab + 释义”，可直接导入。',
      filename: '7 SAT-乱序.txt',
      maxBytes: 2 * 1024 * 1024,
    ),
    CatalogBook(
      id: 'english-words-alpha',
      title: '英语完整单词表（仅单词·无释义）',
      description:
          'dwyl/english-words 的 words_alpha.txt：约 37 万个纯字母英语单词，每行一个，没有释义。',
      url: Uri.parse(
        'https://raw.githubusercontent.com/dwyl/english-words/master/words_alpha.txt',
      ),
      filename: 'words_alpha.txt',
      maxBytes: 6 * 1024 * 1024,
      license: 'Unlicense（公有领域）',
      source: 'dwyl/english-words',
      attribution:
          'dwyl/english-words · Unlicense（公有领域） · '
          'https://github.com/dwyl/english-words',
    ),
    CatalogBook(
      id: 'wordnik-wordlist',
      title: 'Wordnik 英语常用词表（仅单词·无释义）',
      description: 'wordnik/wordlist 的单词表：约 30 万条常见英语单词，每行一个，没有释义。',
      url: Uri.parse(
        'https://raw.githubusercontent.com/wordnik/wordlist/main/wordlist-20210729.txt',
      ),
      filename: 'wordlist-20210729.txt',
      maxBytes: 4 * 1024 * 1024,
      license: 'MIT',
      source: 'wordnik/wordlist',
      attribution:
          'wordnik/wordlist · MIT · https://github.com/wordnik/wordlist',
    ),
    CatalogBook(
      id: 'wordle-five-letter',
      title: '五个字母单词表（仅单词·无释义）',
      description: 'tabatkins/wordle-list 的 words 文件：14855 个五个字母的英语单词，每行一个，没有释义，体积小，适合快速导入。',
      url: Uri.parse(
        'https://raw.githubusercontent.com/tabatkins/wordle-list/main/words',
      ),
      filename: 'wordle-words.txt',
      maxBytes: 512 * 1024,
      license: 'MIT',
      source: 'tabatkins/wordle-list',
      attribution: 'tabatkins/wordle-list · MIT · https://github.com/tabatkins/wordle-list',
    ),
  ]);

  final AddressResolver _resolver;
  final PinnedFetch? _transport;
  final Duration timeout;

  /// Allowlisted entries only. No network request is made by this call.
  Future<List<CatalogBook>> list() async => books;

  /// Downloads one allowlisted book through the hardened transport and
  /// returns decoded text and the filename for the existing importer.
  Future<CatalogDownload> fetch(CatalogBook book, {int? maxBytes}) async {
    final allowed = books.where((b) => b.id == book.id && b.url == book.url);
    if (allowed.isEmpty) {
      throw const CatalogError('该词表不在内置目录中，v1 只允许内置词表来源。');
    }
    final entry = allowed.first;
    if (entry.url.host != _allowedHost || entry.url.scheme != 'https') {
      throw const CatalogError('词表来源不是允许的 HTTPS 地址。');
    }
    final limit = math.min(maxBytes ?? entry.maxBytes, hardMaxBytes);
    try {
      final response = await safeHttpGet(
        uri: entry.url,
        resolver: _resolver,
        timeout: timeout,
        maxBodyBytes: limit,
        transport: _transport,
      );
      if (response.statusCode != HttpStatus.ok) {
        throw CatalogError('下载失败：服务器响应 ${response.statusCode}。');
      }
      if (response.body.length > limit) {
        throw const CatalogError('下载内容超过大小限制。');
      }
      final text = utf8.decode(response.body);
      if (text.trim().isEmpty) {
        throw const CatalogError('下载的词表内容为空。');
      }
      return CatalogDownload(
        book: entry,
        filename: entry.filename,
        text: text,
        byteLength: response.body.length,
      );
    } on CatalogError {
      rethrow;
    } on FormatException catch (error) {
      throw CatalogError('下载的词表无效：$error');
    } catch (error) {
      throw CatalogError('下载词表失败：$error');
    }
  }
}
