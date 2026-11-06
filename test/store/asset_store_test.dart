// One project's store: its sources and catalog.
@TestOn('vm')
library;

import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import '../support/temp_project.dart';
import '../support/test_catalog.dart';

void main() {
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
      expect(loaded.sources.first.error, isA<FetchException>());
      expect(loaded.sources.last.items, 1);
      expect(loaded.catalog.entry('just_art_knight'), isNotNull);
    },
  );

  group('with a project', () {
    late Directory dir;
    late AssetStore store;

    setUp(() {
      final source = buildCatalog(tempDir('catalog'), [
        TestItem('just_art_knight', versions: ['1.0.0', '1.1.0']),
        TestItem(
          'just_kit',
          kind: ItemKind.kit,
          category: 'kits',
          dependencies: {'just_art_knight': '^1.0.0'},
          files: {'lib/just_kit.dart': ''},
        ),
      ]);
      dir = tempDir('p');
      writeFiles(dir, {'pubspec.yaml': pubspecOf('app')});
      store = AssetStore(
        project: StoreProject(dir.path),
        sources: [SourceConfig(source.indexUri.toFilePath())],
        pub: FakePub(),
      );
    });

    String knight(String rel) =>
        '${dir.path}/packages/characters/just_art_knight/$rel';

    test('an update names the files changed since the install, and keeps '
        'them', () async {
      await store.installer().apply(
        (await store.planner()).install(
          'just_art_knight',
          version: Version.parse('1.0.0'),
        ),
      );
      Future<List<PlanIssue>> edits() async => [
        for (final i in (await store.withLocalEdits(
          (await store.planner()).update('just_art_knight'),
        )).issues)
          if (i.message.contains('changed since it was installed')) i,
      ];
      // A checkout that turned LF into CRLF changed nothing.
      final json = File(knight('sprites/just_art_knight.json'));
      json.writeAsStringSync(json.readAsStringSync().replaceAll('\n', '\r\n'));
      expect(await edits(), isEmpty);

      json.writeAsStringSync('{"edited": true}');
      File(knight('sprites/mine.png')).writeAsStringSync('mine');
      final warning = (await edits()).single;
      expect(warning.level, IssueLevel.warning);
      expect(warning.id, 'just_art_knight');
      expect(warning.message, contains('sprites/just_art_knight.json'));
      expect(warning.message, contains('sprites/mine.png'));

      final plan = await store.withLocalEdits(
        (await store.planner()).update('just_art_knight'),
      );
      expect(plan.canApply, isTrue, reason: 'a warning, not a blocker');
      final result = await store.installer().apply(plan);
      final trash = result.trashFolder!;
      expect(trash, startsWith('.editor_trash/store/'));
      expect(
        File(
          '${dir.path}/$trash/packages/characters/just_art_knight/sprites/'
          'just_art_knight.json',
        ).readAsStringSync(),
        '{"edited": true}',
      );
      expect(File(knight('sprites/mine.png')).existsSync(), isFalse);
    });

    test('a plan that replaces nothing is not hashed', () async {
      final plan = (await store.planner()).install('just_art_knight');
      expect(identical(await store.withLocalEdits(plan), plan), isTrue);
    });

    test('planning an uninstall finds what imports any item going, tests '
        'and tools too', () async {
      await store.installer().apply(
        (await store.planner()).install('just_kit'),
      );
      writeFiles(dir, {
        'test/art_test.dart': "import 'package:just_art_knight/x.dart';\n",
        'lib/main.dart': "import 'package:just_kit/just_kit.dart';\n",
      });
      final plan = await store.planUninstall('just_kit');
      expect(plan.changes.map((c) => c.id), ['just_kit', 'just_art_knight']);
      expect(plan.canApply, isFalse);
      final blockers = [for (final b in plan.blockers) b.message];
      expect(blockers, contains(contains('lib/main.dart:1')));
      expect(
        blockers,
        contains(
          allOf(contains('just_art_knight'), contains('test/art_test.dart:1')),
        ),
      );
      final refs = await store.referencesTo({'just_kit', 'just_art_knight'});
      expect(refs.keys, {'just_kit', 'just_art_knight'});
    });
  });
}
