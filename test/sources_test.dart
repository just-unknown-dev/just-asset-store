// Catalog sources (a folder, and a real HTTP server on this machine) and
// the downloader's checks and cache.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  group('catalogs in pieces', () {
    final ids = [for (var i = 0; i < 120; i++) 'item_$i'];

    StoreIndex catalogOf(
      List<String> ids, {
      Map<String, String> names = const {},
      List<RemovedItem> removed = const [],
      DateTime? at,
    }) => StoreIndex.checked(
      source: const StoreSourceInfo('pieces', 'Pieces'),
      categories: const [StoreCategory('characters', 'Characters')],
      items: [
        for (final id in ids)
          StoreItem(
            id: id,
            name: names[id] ?? id,
            kind: ItemKind.content,
            category: 'characters',
            versions: [
              StoreItemVersion(
                version: Version.parse('1.0.0'),
                archive: StoreArchive(url: '$id.zip', sha256: 'a' * 64, size: 1),
              ),
            ],
          ),
      ],
      removed: removed,
      generatedAt: at,
    );

    CatalogFiles publish(
      Directory dir,
      StoreIndex index, {
      int buckets = 8,
    }) {
      final files = CatalogFiles.of(index, buckets: buckets);
      files.files.forEach((path, bytes) {
        File('${dir.path}/$path')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(bytes);
      });
      return files;
    }

    Iterable<File> cachedPieces(Directory cache) => Directory(
      '${cache.path}/catalogs',
    ).listSync(recursive: true).whereType<File>().where(
      (f) => f.parent.path.endsWith('.pieces'),
    );

    test('the same items make the same bytes, in any order', () {
      final a = CatalogFiles.of(
        catalogOf(ids, at: DateTime.utc(2026)),
        buckets: 8,
      );
      final b = CatalogFiles.of(
        catalogOf(ids.reversed.toList(), at: DateTime.utc(2027)),
        buckets: 8,
      );
      expect(b.pieces.keys, a.pieces.keys);
      for (final path in a.pieces.keys) {
        expect(b.pieces[path], a.pieces[path], reason: path);
      }
      // Only the root says when it was made.
      expect(b.rootText, isNot(a.rootText));
      expect(a.pieces.length, lessThanOrEqualTo(8));
      expect(a.root.pieces.fold(0, (n, p) => n + p.items), ids.length);
    });

    test('a changed item changes only its own piece', () {
      final before = CatalogFiles.of(catalogOf(ids), buckets: 8);
      final after = CatalogFiles.of(
        catalogOf(ids, names: {'item_7': 'Seven'}),
        buckets: 8,
      );
      final changed = after.pieces.keys.toSet().difference(
        before.pieces.keys.toSet(),
      );
      expect(changed, hasLength(1));
      final bucket = catalogBucket('item_7', 8);
      expect(
        after.root.pieces.singleWhere((p) => p.bucket == bucket).path,
        changed.single,
      );
    });

    test('a folder catalog in pieces reads as one catalog', () async {
      final dir = tempDir('pieces');
      publish(
        dir,
        catalogOf(ids, removed: const [RemovedItem('bad_pack', 'Malware.')]),
      );
      final index = (await FolderStoreSource(dir.path).fetchIndex()).index;
      expect(index.items.map((i) => i.id).toSet(), ids.toSet());
      expect(index.removal('bad_pack')?.reason, 'Malware.');
      expect(index.removal('item_1'), isNull);
    });

    test('the featured list travels in index.json, in order', () async {
      final featured = StoreIndex.checked(
        source: const StoreSourceInfo('pieces', 'Pieces'),
        categories: const [StoreCategory('characters', 'Characters')],
        items: catalogOf(ids).items,
        featured: const ['item_9', 'gone_item', 'item_2'],
      );
      final dir = tempDir('pieces');
      final files = publish(dir, featured);
      expect(files.root.featured, ['item_9', 'gone_item', 'item_2']);
      final index = (await FolderStoreSource(dir.path).fetchIndex()).index;
      expect(index.featured, ['item_9', 'gone_item', 'item_2']);
      // An id it doesn't list names nothing.
      expect([for (final i in index.featuredItems) i.id], ['item_9', 'item_2']);
      // Inline too; and none at all stays out of the file.
      expect(StoreIndex.fromJson(JsonFields(featured.toJson())).featured, [
        'item_9',
        'gone_item',
        'item_2',
      ]);
      expect(catalogOf(ids).toJson(), isNot(contains('featured')));
      expect(files.rootText, contains('"featured"'));
    });

    test('a folder catalog missing a piece names it', () async {
      final dir = tempDir('pieces');
      final files = publish(dir, catalogOf(ids));
      File('${dir.path}/${files.pieces.keys.first}').deleteSync();
      await expectLater(
        FolderStoreSource(dir.path).fetchIndex(),
        throwsA(
          isA<SourceException>().having(
            (e) => '${e.uri}',
            'uri',
            endsWith(files.pieces.keys.first),
          ),
        ),
      );
    });

    test('on the web: every piece once, then one request, then one piece '
        'per change', () async {
      final dir = tempDir('web');
      final files = publish(dir, catalogOf(ids));
      final server = await TestServer.start(dir);
      final cache = tempDir('cache');
      final source = HttpStoreSource(
        server.uri('index.json'),
        cacheDir: cache.path,
      );

      final first = await source.fetchIndex();
      expect(first.index.items, hasLength(ids.length));
      expect(server.requests, hasLength(1 + files.pieces.length));

      server.requests.clear();
      final same = await source.fetchIndex();
      expect(same.index.items, hasLength(ids.length));
      expect(server.requests, hasLength(1));
      expect(server.requests.single, isNot(startsWith('- ')));

      server.requests.clear();
      publish(dir, catalogOf(ids, names: {'item_7': 'Seven'}));
      final changed = await source.fetchIndex();
      expect(changed.offline, isFalse);
      expect(changed.index.item('item_7')!.name, 'Seven');
      expect(server.requests, hasLength(2));
      // The piece it no longer uses is dropped from the cache.
      expect(cachedPieces(cache), hasLength(files.pieces.length));
    });

    test('offline, the last whole catalog is read from the cache', () async {
      final dir = tempDir('web');
      publish(dir, catalogOf(ids));
      final server = await TestServer.start(dir);
      final cache = tempDir('cache');
      final source = HttpStoreSource(
        server.uri('index.json'),
        cacheDir: cache.path,
      );
      await source.fetchIndex();
      server.down = true;
      final offline = await source.fetchIndex();
      expect(offline.offline, isTrue);
      expect(offline.index.items, hasLength(ids.length));
    });

    test('a piece that is not what index.json names keeps the last good '
        'catalog', () async {
      final dir = tempDir('web');
      publish(dir, catalogOf(ids));
      final server = await TestServer.start(dir);
      final cache = tempDir('cache');
      final source = HttpStoreSource(
        server.uri('index.json'),
        cacheDir: cache.path,
      );
      await source.fetchIndex();
      // A new catalog whose new piece was damaged on the way.
      final next = publish(dir, catalogOf(ids, names: {'item_7': 'Seven'}));
      final bucket = catalogBucket('item_7', 8);
      final piece = next.root.pieces.singleWhere((p) => p.bucket == bucket);
      File('${dir.path}/${piece.path}').writeAsStringSync('{"tampered": 1}');
      final kept = await source.fetchIndex();
      expect(kept.offline, isTrue);
      expect(kept.error, isA<StoreFormatException>());
      expect(kept.index.item('item_7')!.name, 'item_7');
      // With nothing cached, the damage is the answer.
      await expectLater(
        HttpStoreSource(
          server.uri('index.json'),
          cacheDir: tempDir('fresh').path,
        ).fetchIndex(),
        throwsA(isA<StoreFormatException>()),
      );
    });

    test('a piece is checked against what index.json says of it', () {
      final files = CatalogFiles.of(catalogOf(ids), buckets: 8);
      final ref = files.root.pieces.first;
      final bytes = files.pieces[ref.path]!;
      expect(
        CatalogPiece.read(bytes, ref, buckets: 8).items,
        hasLength(ref.items),
      );
      Matcher refused(String text) => throwsA(
        isA<StoreFormatException>()
            .having((e) => e.file, 'file', ref.path)
            .having((e) => '$e', 'text', contains(text)),
      );
      // Another bucket's name, another count, other bytes.
      expect(
        () => CatalogPiece.read(
          bytes,
          CatalogPieceRef(
            bucket: ref.bucket + 1,
            sha256: ref.sha256,
            size: ref.size,
            items: ref.items,
          ),
          buckets: 8,
        ),
        refused('bucket'),
      );
      expect(
        () => CatalogPiece.read(
          bytes,
          CatalogPieceRef(
            bucket: ref.bucket,
            sha256: ref.sha256,
            size: ref.size,
            items: ref.items + 1,
          ),
          buckets: 8,
        ),
        refused('items'),
      );
      expect(
        () => CatalogPiece.read(
          Uint8List.fromList([...bytes]..[0] ^= 1),
          ref,
          buckets: 8,
        ),
        refused('SHA-256'),
      );
      // Read with another bucket count, its items belong elsewhere.
      final rebucketed = CatalogPieceRef(
        bucket: ref.bucket,
        sha256: ref.sha256,
        size: ref.size,
        items: ref.items,
      );
      expect(
        () => CatalogPiece.read(bytes, rebucketed, buckets: 16),
        refused('another bucket'),
      );
    });

    test('a root naming a bucket twice, or too many, is refused', () {
      final files = CatalogFiles.of(catalogOf(ids), buckets: 8);
      final json = jsonDecode(files.rootText) as Map<String, dynamic>;
      final pieces = json['pieces'] as List;
      json['pieces'] = [...pieces, pieces.first];
      expect(
        () => CatalogRoot.parse(jsonEncode(json)),
        throwsA(isA<StoreFormatException>()),
      );
      json['pieces'] = pieces;
      json['buckets'] = 1000;
      expect(
        () => CatalogRoot.parse(jsonEncode(json)),
        throwsA(isA<StoreFormatException>()),
      );
      // A root is never read as a catalog that lists its items itself.
      expect(
        () => StoreIndex.parse(files.rootText),
        throwsA(isA<StoreFormatException>()),
      );
    });

    test('an item stays in its bucket', () {
      expect(catalogBucket('item_7', 32), catalogBucket('item_7', 32));
      final spread = {for (final id in ids) catalogBucket(id, 8)};
      expect(spread.length, 8, reason: '120 ids land in every bucket');
    });
  });

  test(
    "a web catalog's archives are never on this machine's own address",
    () async {
      final index = StoreIndex.fromJson(
        JsonFields({
          'schema': 1,
          'source': {'id': 'x', 'name': 'X'},
          'categories': [
            {'id': 'characters', 'label': 'Characters'},
          ],
          'items': [
            {
              'id': 'k',
              'name': 'K',
              'kind': 'content',
              'category': 'characters',
              'versions': [
                {
                  'version': '1.0.0',
                  'archive': {
                    'url': 'http://127.0.0.1:8080/admin?x',
                    'sha256': 'a' * 64,
                    'size': 1,
                  },
                },
              ],
            },
          ],
        }),
      );
      final web = MemoryStoreSource(index, const {}, base: 'https://e.com/');
      final item = index.items.single;
      await expectLater(
        web.resolveDownload(item, item.versions.single),
        throwsA(isA<SourceException>()),
      );
    },
  );

  test('which addresses are this machine or its network', () {
    for (final host in [
      '', 'localhost', 'a.localhost', 'printer.local', 'metadata.internal',
      '127.0.0.1', '10.1.2.3', '172.16.0.1', '172.31.255.255',
      '192.168.1.1', '100.64.0.1', '169.254.169.254', '0.0.0.0', '::1',
      'fe80::1', 'fd00::1', '::ffff:127.0.0.1', '::ffff:10.0.0.1', '::',
      // Bare numbers some systems read as IPv4 addresses.
      '2130706433', '0x7f.1', '0177.0.0.1',
    ]) {
      expect(StoreSource.isPrivateHost(host), isTrue, reason: host);
    }
    for (final host in [
      'example.com', '8.8.8.8', '172.32.0.1', '100.128.0.1', '1.1.1.1',
      '2606:4700::1111', '::ffff:8.8.8.8', 'local.example.com',
    ]) {
      expect(StoreSource.isPrivateHost(host), isFalse, reason: host);
    }
  });

  test('a web catalog never leads inside; one tried out here may', () {
    final web = HttpStoreSource(Uri.parse('https://e.com/index.json'));
    expect(web.leadsInside(Uri.parse('http://169.254.169.254/x')), isTrue);
    expect(web.leadsInside(Uri.parse('https://192.168.1.1/a.zip')), isTrue);
    expect(web.leadsInside(Uri.parse('https://cdn.e.com/a.zip')), isFalse);
    final here = HttpStoreSource(Uri.parse('http://localhost:8080/index.json'));
    expect(here.leadsInside(Uri.parse('http://127.0.0.1:9000/a.zip')), isFalse);
  });
}
