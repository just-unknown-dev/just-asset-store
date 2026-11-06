// Restoring a project's items from its lockfile.
@TestOn('vm')
library;

import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import '../support/temp_project.dart';
import '../support/test_catalog.dart';

void main() {
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

    test('puts a missing plugin back in plugins/', () async {
      final dir = tempDir('restore');
      writeFiles(dir, {'pubspec.yaml': pubspecOf('app')});
      final source = buildCatalog(tempDir('catalog'), [
        TestItem('just_art_knight'),
        TestItem(
          'just_kit',
          kind: ItemKind.kit,
          category: 'kits',
          dependencies: {'just_art_knight': '^1.0.0'},
          files: {'lib/just_kit.dart': ''},
        ),
      ]);
      final project = StoreProject(dir.path);
      final store = AssetStore(
        project: project,
        sources: [SourceConfig(source.indexUri.toFilePath())],
        pub: FakePub(),
      );
      await store.installer().apply(
        (await store.planner()).install('just_kit'),
      );
      final before = snapshot(dir);
      expect(before.keys, contains('plugins/kits/just_kit/lib/just_kit.dart'));

      // A clone that kept both folders out of git.
      project.dir('plugins').deleteSync(recursive: true);
      project.dir('packages').deleteSync(recursive: true);
      final result = await store.restore();
      expect(result.restored.toSet(), {'just_art_knight', 'just_kit'});
      expect(result.problems, isEmpty);
      expect(snapshot(dir).keys.toSet(), before.keys.toSet());
      expect(project.dir('packages/kits').existsSync(), isFalse);
      expect(project.dir('plugins/characters').existsSync(), isFalse);
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

  test('a pub get that fails after the folders are back says so', () async {
    final dir = tempDir('restore');
    writeFiles(dir, {'pubspec.yaml': pubspecOf('app')});
    final source = buildCatalog(tempDir('catalog'), [
      TestItem('just_art_knight'),
    ]);
    final pub = FakePub();
    final project = StoreProject(dir.path);
    final store = AssetStore(
      project: project,
      sources: [SourceConfig(source.indexUri.toFilePath())],
      pub: pub,
    );
    await store.installer().apply(
      (await store.planner()).install('just_art_knight'),
    );
    project
        .dir('packages/characters/just_art_knight')
        .deleteSync(recursive: true);
    pub.next = const PubResult(1, '', 'Because app depends on nothing…');
    final result = await store.restore();
    expect(result.restored, ['just_art_knight'], reason: 'the folder is back');
    expect(result.problems.single, contains('pub get failed'));
    expect(
      project.dir('packages/characters/just_art_knight').existsSync(),
      isTrue,
    );
  });
}
