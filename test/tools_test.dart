// The creator and catalog tools — the packer and the catalog builder — and
// restoring a project from its lockfile.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import 'support/temp_project.dart';
import 'support/test_catalog.dart';

/// A package folder on disk for [item], with text files in [eol] endings.
Directory packageFolder(
  TestItem item, {
  String eol = '\n',
  Map<String, String> extra = const {},
}) {
  final dir = tempDir('pkg');
  final files = packageFiles(item, item.versions.first);
  files.forEach((path, bytes) {
    var text = utf8.decode(bytes, allowMalformed: true);
    if (FileHashes.isText(path)) text = text.replaceAll('\n', eol);
    File('${dir.path}/$path')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
  });
  writeFiles(dir, {
    '.dart_tool/package_config.json': '{}',
    '.git/HEAD': 'ref',
    'test/x_test.dart': '',
    'pubspec.lock': '',
    'just_art_knight.iml': '<module/>',
    'Thumbs.db': 'x',
    ...extra,
  });
  return dir;
}

void main() {
  group('Packer', () {
    final knight = TestItem('just_art_knight');

    test('the same bytes from an LF or a CRLF checkout', () {
      final lf = Packer.pack(packageFolder(knight));
      final crlf = Packer.pack(packageFolder(knight, eol: '\r\n'));
      expect(crlf.sha256, lf.sha256);
      expect(lf.fileName, 'just_art_knight-1.0.0.zip');
      final names = ZipArchive.read(lf.bytes).files.map((f) => f.path).toSet();
      expect(names, {
        'pubspec.yaml',
        'just_store.json',
        'sprites/just_art_knight.png',
        'sprites/just_art_knight.json',
      });
    });

    test('the catalog version file it writes', () {
      final r = Packer.pack(packageFolder(knight));
      final json = r.versionJson(
        'https://e.com/k.zip',
        published: DateTime.utc(2026, 10, 7),
      );
      expect(json['version'], '1.0.0');
      expect(json['published'], '2026-10-07');
      final archive = json['archive']! as Map;
      expect(archive['sha256'], r.sha256);
      expect(archive['size'], r.bytes.length);
      // It reads back as a catalog version.
      final v = StoreItemVersion.fromJson(
        JsonFields(jsonDecode(jsonEncode(json))),
        ItemKind.content,
      );
      expect(v.archive!.sha256, r.sha256);
    });

    test('warns about project paths and undeclared packages', () {
      final r = Packer.pack(
        packageFolder(
          knight,
          extra: {
            'sprites/run.json':
                '{"meta": {"image": "assets/sprites/run.png"}, "x": "packages/other_pack/a.png"}',
          },
        ),
      );
      expect(
        r.warnings.join('\n'),
        allOf(
          contains('"assets/sprites/run.png"'),
          contains('package "other_pack"'),
        ),
      );
    });

    test('refuses what the installer would refuse', () {
      expect(
        () => Packer.pack(
          packageFolder(knight, extra: {'sprites/deep/x.png': 'x'}),
        ),
        throwsA(isA<PackageCheckException>()),
      );
      expect(
        () => Packer.pack(tempDir('empty')),
        throwsA(isA<StoreFormatException>()),
      );
    });
  });

  group('CatalogBuilder', () {
    Directory repo({Map<String, String> extra = const {}}) {
      final dir = tempDir('repo');
      writeFiles(dir, {
        'catalog.json': jsonEncode({
          'source': {'id': 'just-official', 'name': 'Just Asset Store'},
          'categories': [
            {'id': 'characters', 'label': 'Characters', 'order': 10},
          ],
          'maintainers': ['just-maintainer'],
        }),
        'publishers/just.json': jsonEncode({
          'id': 'just',
          'name': 'Just',
          'github': ['ju-skb'],
          'trust': 'official',
        }),
        'publishers/pixel_folk.json': jsonEncode({
          'id': 'pixel_folk',
          'name': 'Pixel Folk',
          'github': ['pixelfolk'],
        }),
        'items/just_art_knight/item.json': jsonEncode({
          'id': 'just_art_knight',
          'name': 'Knight',
          'kind': 'content',
          'category': 'characters',
          'publisher': 'just',
          'trust': 'community',
        }),
        'items/just_art_knight/versions/1.0.0.json': jsonEncode({
          'version': '1.0.0',
          'archive': {
            'url': 'https://e.com/k-1.0.0.zip',
            'sha256': 'a' * 64,
            'size': 10,
          },
        }),
        'items/just_art_knight/versions/1.10.0.json': jsonEncode({
          'version': '1.10.0',
          'archive': {
            'url': 'https://e.com/k-1.10.0.zip',
            'sha256': 'b' * 64,
            'size': 10,
          },
        }),
        'items/just_art_knight/thumbnail.png': 'png',
        'items/just_art_knight/previews/1.png': 'png',
        'items/folk_trees/item.json': jsonEncode({
          'id': 'folk_trees',
          'name': 'Trees',
          'kind': 'content',
          'category': 'characters',
          'publisher': 'pixel_folk',
          'trust': 'official',
        }),
        'items/folk_trees/versions/0.1.0.json': jsonEncode({
          'version': '0.1.0',
          'archive': {
            'url': 'https://e.com/t.zip',
            'sha256': 'c' * 64,
            'size': 10,
          },
        }),
        ...extra,
      });
      return dir;
    }

    test('builds an index, trust from the publisher, versions in order', () {
      final build = CatalogBuilder.build(
        repo(),
        now: DateTime.utc(2026, 10, 7),
      );
      final knight = build.index.item('just_art_knight')!;
      expect(knight.trust, TrustLevel.official);
      expect(
        build.index.item('folk_trees')!.trust,
        TrustLevel.community,
        reason: 'an item cannot claim more',
      );
      expect(knight.versions.map((v) => '${v.version}'), ['1.0.0', '1.10.0']);
      expect(knight.thumbnail, 'items/just_art_knight/thumbnail.png');
      expect(knight.previews, ['items/just_art_knight/previews/1.png']);
      expect(
        build.assets.keys,
        containsAll([
          'items/just_art_knight/thumbnail.png',
          'items/just_art_knight/previews/1.png',
        ]),
      );
      expect(build.index.generatedAt, DateTime.utc(2026, 10, 7));
    });

    test('lists every problem, by item', () {
      try {
        CatalogBuilder.build(
          repo(
            extra: {
              'items/wrong_name/item.json': jsonEncode({
                'id': 'other',
                'name': 'X',
                'kind': 'content',
                'category': 'characters',
              }),
              'items/just_art_knight/versions/2.0.0.json': jsonEncode({
                'version': '2.0.1',
              }),
              'items/folk_trees/item.json': jsonEncode({
                'id': 'folk_trees',
                'name': 'Trees',
                'kind': 'content',
                'category': 'characters',
                'publisher': 'nobody',
              }),
            },
          ),
        );
        fail('should not build');
      } on CatalogBuildException catch (e) {
        final text = '$e';
        expect(
          text,
          contains('items/wrong_name/item.json: its "id" must be "wrong_name"'),
        );
        expect(
          text,
          contains('versions/2.0.0.json: its "version" must be "2.0.0"'),
        );
        expect(text, contains('publisher "nobody" has no file'));
      }
    });

    test('schema errors name the item, not its position', () {
      expect(
        () => CatalogBuilder.build(
          repo(
            extra: {
              'items/folk_trees/versions/0.1.0.json': jsonEncode({
                'version': '0.1.0',
                'archive': {
                  'url': 'https://e.com/t.zip',
                  'sha256': 'nope',
                  'size': 10,
                },
              }),
            },
          ),
        ),
        throwsA(
          isA<CatalogBuildException>().having(
            (e) => '$e',
            'text',
            contains('items/folk_trees.versions[0].archive.sha256'),
          ),
        ),
      );
    });

    test('CODEOWNERS gives each publisher its items', () {
      final text = CatalogBuilder.codeowners(repo());
      expect(text, contains('* @just-maintainer\n'));
      expect(
        text,
        contains('/items/folk_trees/ @pixelfolk @just-maintainer\n'),
      );
      expect(
        text,
        contains('/items/just_art_knight/ @ju-skb @just-maintainer\n'),
      );
      // A publisher's file says how far the store vouches for it: only the
      // maintainers approve changes to it, never the publisher.
      expect(text, contains('/publishers/ @just-maintainer\n'));
      expect(text, isNot(contains('/publishers/pixel_folk.json')));
    });
  });

  group('restore', () {
    test('downloads missing folders from the lockfile, checked', () async {
      final dir = tempDir('restore');
      writeFiles(dir, {'pubspec.yaml': pubspecOf('app')});
      final source = buildCatalog(tempDir('catalog'), [
        TestItem('just_art_knight'),
      ]);
      final project = StoreProject(dir.path);
      final store = AssetStore(
        project: project,
        sources: [SourceConfig(source.indexUri.toFilePath())],
        pub: FakePub(),
      );
      final plan = (await store.planner()).install('just_art_knight');
      await store.installer().apply(plan);
      // The project read the official catalog before: it still does.
      expect(project.readLock().sources.map((s) => s.id), ['just', 'test']);
      final before = snapshot(dir);

      project
          .dir('packages/characters/just_art_knight')
          .deleteSync(recursive: true);
      final result = await store.restore();
      expect(result.restored, ['just_art_knight']);
      expect(result.problems, isEmpty);
      expect(snapshot(dir).keys.toSet(), before.keys.toSet());
      expect(
        (await store.restore()).restored,
        isEmpty,
        reason: 'nothing missing',
      );
    });

    test('refuses an archive that changed since it was installed', () async {
      final dir = tempDir('restore');
      writeFiles(dir, {'pubspec.yaml': pubspecOf('app')});
      final catalogDir = tempDir('catalog');
      final source = buildCatalog(catalogDir, [TestItem('just_art_knight')]);
      final store = AssetStore(
        project: StoreProject(dir.path),
        sources: [SourceConfig(source.indexUri.toFilePath())],
        pub: FakePub(),
      );
      await store.installer().apply(
        (await store.planner()).install('just_art_knight'),
      );
      store.project
          .dir('packages/characters/just_art_knight')
          .deleteSync(recursive: true);
      File(
        '${catalogDir.path}/archives/just_art_knight-1.0.0.zip',
      ).writeAsBytesSync([1, 2, 3]);
      final result = await store.restore();
      expect(result.restored, isEmpty);
      expect(result.problems.single, contains('fingerprint'));
    });
  });

  test('StorePaths', () {
    final dir = StorePaths.defaultCacheDir(
      environment: {
        'LOCALAPPDATA': r'C:\Users\x\AppData\Local',
        'HOME': '/home/x',
      },
    );
    expect(dir, endsWith('just_asset_store'));
    expect(dir, isNot(contains(r'\')));
  });

  test(
    'AssetStore reports a source that fails, and keeps the others',
    () async {
      final source = buildCatalog(tempDir('catalog'), [
        TestItem('just_art_knight'),
      ]);
      final store = AssetStore(
        project: StoreProject(tempDir('p').path),
        sources: [
          SourceConfig('${tempDir('nothing').path}/missing'),
          SourceConfig(source.indexUri.toFilePath()),
          const SourceConfig('https://example.com/off.json', enabled: false),
        ],
        pub: FakePub(),
      );
      final loaded = await store.loadCatalog();
      expect(loaded.sources.length, 2);
      expect(loaded.sources.first.loaded, isFalse);
      expect(loaded.sources.first.error, isA<SourceException>());
      expect(loaded.sources.last.items, 1);
      expect(loaded.catalog.entry('just_art_knight'), isNotNull);
    },
  );
}
