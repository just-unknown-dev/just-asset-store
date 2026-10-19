// Catalog sources (a folder, and a real HTTP server on this machine) and
// the downloader's checks and cache.
import 'dart:convert';
import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import 'support/temp_project.dart';
import 'support/test_catalog.dart';

/// A tiny catalog server on 127.0.0.1 serving [root], counting requests,
/// with switches for the cases under test.
class TestServer {
  TestServer._(this.server, this.root);

  static Future<TestServer> start(Directory root) async {
    final s = TestServer._(await HttpServer.bind('127.0.0.1', 0), root);
    s.server.listen(s._handle);
    addTearDown(() => s.server.close(force: true));
    return s;
  }

  final HttpServer server;
  final Directory root;
  final List<String> requests = [];
  int tooManyRequests = 0;
  bool down = false;

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}/$path');

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path.substring(1);
    requests.add('${request.headers.value('if-none-match') ?? '-'} $path');
    final response = request.response;
    if (down) {
      response.statusCode = 500;
      await response.close();
      return;
    }
    if (tooManyRequests > 0) {
      tooManyRequests--;
      response
        ..statusCode = 429
        ..headers.set('retry-after', '1');
      await response.close();
      return;
    }
    if (path == 'moved/index.json') {
      response
        ..statusCode = 302
        ..headers.set('location', uri('index.json').toString());
      await response.close();
      return;
    }
    final file = File('${root.path}/$path');
    if (!file.existsSync()) {
      response.statusCode = 404;
      await response.close();
      return;
    }
    final bytes = file.readAsBytesSync();
    final tag = '"${Sha256.hexOf(bytes).substring(0, 16)}"';
    if (request.headers.value('if-none-match') == tag) {
      response.statusCode = 304;
      await response.close();
      return;
    }
    response.headers.set('etag', tag);
    response.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }
}

void main() {
  late Directory catalogDir;
  late FolderStoreSource folder;

  setUp(() {
    catalogDir = tempDir('catalog');
    folder = buildCatalog(catalogDir, [
      TestItem('just_art_knight', versions: ['1.0.0', '1.1.0']),
    ]);
  });

  group('FolderStoreSource', () {
    test('reads the catalog and files beside it', () async {
      final fetched = await folder.fetchIndex();
      expect(fetched.offline, isFalse);
      final item = fetched.index.items.single;
      expect('${item.latest!.version}', '1.1.0');
      final uri = await folder.resolveDownload(item, item.latest!);
      expect(uri.scheme, 'file');
      expect((await folder.readBytes(uri)).length, item.latest!.archive!.size);
    });

    test('also accepts the index.json path or a file: URL', () async {
      expect(
        (await FolderStoreSource(
          '${catalogDir.path}/index.json',
        ).fetchIndex()).index.items,
        hasLength(1),
      );
      expect(
        (await FolderStoreSource(
          catalogDir.uri.toString(),
        ).fetchIndex()).index.items,
        hasLength(1),
      );
    });

    test('archives on the web are fetched from a local catalog', () async {
      // A catalog built on disk to preview it, pointing at its releases.
      final server = await TestServer.start(catalogDir);
      final local = tempDir('local');
      final index =
          jsonDecode(File('${catalogDir.path}/index.json').readAsStringSync())
              as Map<String, dynamic>;
      for (final item in index['items'] as List) {
        for (final v in (item as Map)['versions'] as List) {
          final archive = (v as Map)['archive'] as Map;
          archive['url'] = server.uri(archive['url'] as String).toString();
        }
      }
      File('${local.path}/index.json').writeAsStringSync(jsonEncode(index));
      final source = FolderStoreSource(local.path);
      final item = (await source.fetchIndex()).index.items.single;
      final bytes = await Downloader().archive(source, item, item.latest!);
      expect(Sha256.hexOf(bytes), item.latest!.archive!.sha256);
    });

    test('a missing catalog is a SourceException', () {
      expect(
        FolderStoreSource('${catalogDir.path}/nope').fetchIndex(),
        throwsA(isA<SourceException>()),
      );
    });
  });

  group('HttpStoreSource', () {
    test(
      'fetches, then asks with the ETag and uses its cache on 304',
      () async {
        final server = await TestServer.start(catalogDir);
        final cache = tempDir('cache');
        final source = HttpStoreSource(
          server.uri('index.json'),
          cacheDir: cache.path,
        );
        final first = await source.fetchIndex();
        expect(first.index.items.single.id, 'just_art_knight');
        final second = await source.fetchIndex();
        expect(second.index.items.single.id, 'just_art_knight');
        expect(server.requests.first, startsWith('- '));
        expect(
          server.requests.last,
          startsWith('"'),
          reason: 'sent If-None-Match',
        );
        // refresh: true ignores the cache.
        await source.fetchIndex(refresh: true);
        expect(server.requests.last, startsWith('- '));
      },
    );

    test('falls back to the cached catalog when the server fails', () async {
      final server = await TestServer.start(catalogDir);
      final cache = tempDir('cache');
      final source = HttpStoreSource(
        server.uri('index.json'),
        cacheDir: cache.path,
      );
      await source.fetchIndex();
      server.down = true;
      final offline = await source.fetchIndex(refresh: true);
      expect(offline.offline, isTrue);
      expect(offline.index.items, hasLength(1));
      expect(offline.error, isA<SourceException>());
    });

    test('with no cache, a failure is a SourceException', () async {
      final server = await TestServer.start(catalogDir);
      server.down = true;
      expect(
        HttpStoreSource(server.uri('index.json')).fetchIndex(),
        throwsA(
          isA<SourceException>().having((e) => e.statusCode, 'status', 500),
        ),
      );
    });

    test('follows redirects and waits out 429s', () async {
      final server = await TestServer.start(catalogDir);
      expect(
        (await HttpStoreSource(
          server.uri('moved/index.json'),
        ).fetchIndex()).index.items,
        hasLength(1),
      );
      server.tooManyRequests = 1;
      expect(
        (await HttpStoreSource(
          server.uri('index.json'),
        ).fetchIndex()).index.items,
        hasLength(1),
      );
    });

    test('resolves archives beside the catalog and downloads them', () async {
      final server = await TestServer.start(catalogDir);
      final source = HttpStoreSource(server.uri('index.json'));
      final item = (await source.fetchIndex()).index.items.single;
      final uri = await source.resolveDownload(item, item.latest!);
      expect(uri, server.uri('archives/just_art_knight-1.1.0.zip'));
      final progress = <int>[];
      final bytes = await source.readBytes(
        uri,
        onProgress: (got, _) => progress.add(got),
      );
      expect(bytes.length, item.latest!.archive!.size);
      expect(progress.last, bytes.length);
    });

    test('refuses a download larger than the catalog says', () async {
      final server = await TestServer.start(catalogDir);
      final source = HttpStoreSource(server.uri('index.json'));
      expect(
        source.readBytes(server.uri('index.json'), maxBytes: 10),
        throwsA(isA<SourceException>()),
      );
    });

    test('only https, except on this machine', () {
      expect(
        () => HttpStoreSource(Uri.parse('http://example.com/index.json')),
        throwsA(isA<SourceException>()),
      );
      expect(
        HttpStoreSource(Uri.parse('https://example.com/index.json')),
        isNotNull,
      );
      expect(
        HttpStoreSource(Uri.parse('http://localhost:8080/index.json')),
        isNotNull,
      );
    });

    test('cancelling stops a download', () async {
      final server = await TestServer.start(catalogDir);
      final token = CancelToken()..cancel();
      expect(
        HttpStoreSource(
          server.uri('index.json'),
        ).readBytes(server.uri('index.json'), cancel: token),
        throwsA(isA<CancelledException>()),
      );
    });

    test('paid items are refused for now', () async {
      final dir = tempDir('paid');
      final source = buildCatalog(dir, [
        TestItem('just_art_paid', access: 'entitled'),
      ]);
      final item = (await source.fetchIndex()).index.items.single;
      expect(
        source.resolveDownload(item, item.latest!),
        throwsA(
          isA<SourceException>().having(
            (e) => e.message,
            'message',
            contains('paid'),
          ),
        ),
      );
    });
  });

  group('Downloader', () {
    test('checks size and SHA-256, and caches by SHA-256', () async {
      final server = await TestServer.start(catalogDir);
      final source = HttpStoreSource(server.uri('index.json'));
      final item = (await source.fetchIndex()).index.items.single;
      final cache = DownloadCache(tempDir('dl').path);
      final downloader = Downloader(cache: cache);
      final a = await downloader.archive(source, item, item.latest!);
      final before = server.requests.length;
      final b = await downloader.archive(source, item, item.latest!);
      expect(b, a);
      expect(server.requests.length, before, reason: 'served from the cache');
      expect(cache.sizeInBytes, greaterThan(0));
      cache.clear();
      expect(cache.sizeInBytes, 0);
    });

    test('a damaged cache entry is dropped and fetched again', () async {
      final item = (await folder.fetchIndex()).index.items.single;
      final cache = DownloadCache(tempDir('dl').path);
      final sha = item.latest!.archive!.sha256;
      cache.putArchive(sha, utf8.encode('not the archive'));
      expect(cache.archive(sha), isNull);
      final bytes = await Downloader(
        cache: cache,
      ).archive(folder, item, item.latest!);
      expect(Sha256.hexOf(bytes), sha);
    });

    test('refuses bytes that are not what the catalog pinned', () async {
      final item = (await folder.fetchIndex()).index.items.single;
      // Swap the archive after the catalog was written.
      final v = item.latest!;
      File(
        '${catalogDir.path}/${v.archive!.url}',
      ).writeAsBytesSync(List.filled(v.archive!.size, 7));
      await expectLater(
        Downloader().archive(folder, item, v),
        throwsA(
          isA<DownloadException>().having(
            (e) => e.message,
            'message',
            contains('fingerprint'),
          ),
        ),
      );
      File('${catalogDir.path}/${v.archive!.url}').writeAsBytesSync([1, 2, 3]);
      await expectLater(
        Downloader().archive(folder, item, v),
        throwsA(
          isA<DownloadException>().having(
            (e) => e.message,
            'message',
            contains('bytes'),
          ),
        ),
      );
    });

    test('thumbnails are cached files', () async {
      File('${catalogDir.path}/thumbs/k.png')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      final server = await TestServer.start(catalogDir);
      final source = HttpStoreSource(server.uri('index.json'));
      final downloader = Downloader(cache: DownloadCache(tempDir('dl').path));
      final file = await downloader.thumbnail(source, 'thumbs/k.png');
      expect(file!.readAsBytesSync(), [1, 2, 3]);
      expect(await downloader.thumbnail(source, 'thumbs/missing.png'), isNull);
      expect(
        (await downloader.thumbnail(folder, 'thumbs/k.png'))!.existsSync(),
        isTrue,
      );
    });
  });
}
