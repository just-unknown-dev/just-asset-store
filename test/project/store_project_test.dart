// The project on disk as the store sees it: its lockfile file, pub's
// resolution files, the SDK and the overrides target.
@TestOn('vm')
library;

import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import '../support/temp_project.dart';

void main() {
  group('StoreProject', () {
    test('paths, the lockfile and atomic writes', () {
      final dir = tempDir('proj');
      final project = StoreProject(dir.path);
      expect(project.readLock().items, isEmpty);
      project.writeLock(
        StoreLock(
          items: {
            'a': const LockedItem(
              version: '^1.0.0',
              kind: ItemKind.runtimeLibrary,
              origin: ItemOrigin.hosted,
            ),
          },
        ),
      );
      expect(project.readLock().items.keys, ['a']);
      expect(
        File('${dir.path}/just_store.lock.json.saving').existsSync(),
        isFalse,
      );
      expect(
        project.relativeOf('${dir.path}/packages/x/y.json'),
        'packages/x/y.json',
      );
      expect(
        project.relativeOf('${dir.path}${Platform.pathSeparator}lib'),
        'lib',
      );
      expect(project.relativeOf(Directory.systemTemp.path), isNull);
      File('${dir.path}/just_store.lock.json').writeAsStringSync('{oops');
      expect(
        project.readLock,
        throwsA(
          isA<JsonFormatException>().having(
            (e) => e.file,
            'file',
            'just_store.lock.json',
          ),
        ),
      );
    });

    test('content goes in packages/, editor tools and kits in plugins/', () {
      expect(StoreProject.packagesDir, 'packages');
      expect(StoreProject.pluginsDir, 'plugins');
      expect(StoreProject.itemRoots, ['packages', 'plugins']);
      expect(
        StoreProject.itemPath(ItemKind.content, 'characters', 'k'),
        'packages/characters/k',
      );
      expect(
        StoreProject.itemPath(ItemKind.kit, 'kits', 'k'),
        'plugins/kits/k',
      );
      expect(
        StoreProject.itemPath(ItemKind.editorExtension, 'editors', 'k'),
        'plugins/editors/k',
      );
      // Every kind copied in goes in one of the roots the planner scans.
      for (final kind in ItemKind.values) {
        expect(kind.isPlugin, kind.isCode && kind.isVendored, reason: kind.id);
        final folder = kind.installFolder;
        if (folder == null) {
          expect(kind.isVendored, isFalse, reason: kind.id);
          expect(
            () => StoreProject.itemPath(kind, 'libraries', 'k'),
            throwsArgumentError,
            reason: kind.id,
          );
          continue;
        }
        expect(StoreProject.itemRoots, contains(folder), reason: kind.id);
        expect(
          folder,
          kind.isPlugin ? StoreProject.pluginsDir : StoreProject.packagesDir,
          reason: kind.id,
        );
      }
    });
  });

  group('what pub resolved', () {
    test(
      'package_config.json and package_graph.json from a real pub get',
      () async {
        final dir = tempDir('resolved');
        writeFiles(dir, {
          'pubspec.yaml': pubspecOf(
            'app',
            extra:
                'dependencies:\n'
                '  just_art_knight:\n    path: packages/characters/just_art_knight\n'
                'dev_dependencies:\n'
                '  tool:\n    path: packages/editors/tool\n',
          ),
          'packages/characters/just_art_knight/pubspec.yaml': pubspecOf(
            'just_art_knight',
            version: '1.2.0',
            extra: 'dependencies:\n  lib_a:\n    path: ../../libs/lib_a\n',
          ),
          'packages/libs/lib_a/pubspec.yaml': pubspecOf(
            'lib_a',
            version: '0.3.0',
          ),
          'packages/editors/tool/pubspec.yaml': pubspecOf(
            'tool',
            version: '0.1.0',
          ),
        });
        final get = await runDart(['pub', 'get', '--offline'], dir);
        expect(get.exitCode, 0, reason: '${get.stdout}${get.stderr}');

        final config = PackageConfig.read(dir.path)!;
        final knight = config.packages['just_art_knight']!;
        expect(
          knight.rootPath,
          endsWith('/packages/characters/just_art_knight'),
        );
        expect(
          knight.libPath,
          endsWith('/packages/characters/just_art_knight/lib'),
        );
        expect(knight.isInPubCache, isFalse);
        expect(knight.rootPath, isNot(contains(r'\')));

        final graph = PackageGraph.read(dir.path)!;
        expect(graph.roots, ['app']);
        expect('${graph.versionOf('just_art_knight')}', '1.2.0');
        expect(graph.dependentsOf('lib_a'), {'just_art_knight'});
        expect(graph.dependentsOf('tool'), {'app'});
        expect(graph.shipsWithApp('lib_a'), isTrue);
        expect(
          graph.shipsWithApp('tool'),
          isFalse,
          reason: 'dev dependency only',
        );
      },
    );

    test('missing or damaged files read as null', () {
      final dir = tempDir('none');
      expect(PackageConfig.read(dir.path), isNull);
      writeFiles(dir, {'.dart_tool/package_graph.json': '{oops'});
      expect(PackageGraph.read(dir.path), isNull);
    });
  });

  group('SdkLocator', () {
    Directory fakeSdk() {
      final dir = tempDir('sdk');
      writeFiles(dir, {
        Platform.isWindows ? 'bin/flutter.bat' : 'bin/flutter': '',
      });
      return dir;
    }

    test('prefers the configured SDK, then FLUTTER_ROOT, then PATH', () {
      final project = tempDir('p');
      final a = fakeSdk();
      final b = fakeSdk();
      expect(
        SdkLocator.locate(
          project.path,
          configured: a.path,
          environment: {'FLUTTER_ROOT': b.path},
        )!.root,
        a.path.replaceAll(r'\', '/'),
      );
      expect(
        SdkLocator.locate(
          project.path,
          environment: {'FLUTTER_ROOT': b.path},
        )!.root,
        b.path.replaceAll(r'\', '/'),
      );
      expect(
        SdkLocator.locate(
          project.path,
          environment: {'PATH': '${a.path}${Platform.pathSeparator}bin'},
        )!.root,
        a.path.replaceAll(r'\', '/'),
      );
      expect(SdkLocator.locate(project.path, environment: const {}), isNull);
      expect(
        SdkLocator.locate(
          project.path,
          configured: '${a.path}/nope',
          environment: const {},
        ),
        isNull,
      );
    });

    test('finds the SDK that resolved the template', () {
      final template = Directory('../..');
      final config = File('${template.path}/.dart_tool/package_config.json');
      if (!config.existsSync()) return;
      final sdk = SdkLocator.locate(template.path, environment: const {});
      expect(sdk, isNotNull);
      expect(File(sdk!.dart).existsSync(), isTrue);
    });
  });

  group('ProcessPubRunner', () {
    test('runs pub get with the SDK and reports failures', () async {
      final sdk = SdkLocator.locate('../..');
      if (sdk == null) return;
      final dir = tempDir('pubrun');
      writeFiles(dir, {'pubspec.yaml': pubspecOf('app')});
      final runner = ProcessPubRunner(sdk);
      final ok = await runner.get(dir.path, offline: true);
      expect(ok.ok, isTrue, reason: ok.summary);
      writeFiles(dir, {
        'pubspec.yaml': pubspecOf(
          'app',
          extra: 'dependencies:\n  nope:\n    path: missing\n',
        ),
      });
      final bad = await runner.get(dir.path, offline: true);
      expect(bad.ok, isFalse);
      expect(bad.summary, contains('missing'));
    });
  });

  group('OverridesTarget', () {
    test('pubspec.yaml when there is no overrides file', () async {
      final dir = tempDir('ot');
      writeFiles(dir, {'pubspec.yaml': pubspecOf('app')});
      final t = await OverridesTarget.detect(StoreProject(dir.path));
      expect(t.active, 'pubspec.yaml');
      expect(t.mirror, isNull);
    });

    test('the overrides file, mirrored when git ignores it', () async {
      final dir = tempDir('ot');
      writeFiles(dir, {
        'pubspec.yaml': pubspecOf('app'),
        'pubspec_overrides.yaml': 'dependency_overrides:\n',
      });
      var t = await OverridesTarget.detect(StoreProject(dir.path));
      expect(t.files, ['pubspec_overrides.yaml']);
      writeFiles(dir, {'.gitignore': 'build/\npubspec_overrides.yaml\n'});
      t = await OverridesTarget.detect(StoreProject(dir.path));
      expect(t.files, ['pubspec_overrides.yaml', 'pubspec.yaml']);
    });

    test('the template: its overrides file is ignored by git', () async {
      final template = StoreProject('../..');
      if (!template.file('pubspec_overrides.yaml').existsSync()) return;
      final t = await OverridesTarget.detect(template);
      expect(t.files, ['pubspec_overrides.yaml', 'pubspec.yaml']);
    });
  });

  test('a folder catalog is recorded by its path from the project', () {
    final project = StoreProject(tempDir('p').path);
    final inside = Uri.file('${project.root}/store_catalog/index.json');
    expect(project.recordedSource(inside), 'store_catalog/index.json');
    final beside = Directory('${project.root}/../catalogs/mine').absolute;
    final outside = Uri.file('${beside.path}/index.json');
    expect(project.recordedSource(outside), '../catalogs/mine/index.json');
    expect(
      project.recordedSource(Uri.parse('https://e.com/index.json')),
      'https://e.com/index.json',
    );
    // Read back from the project, wherever the tool runs from.
    expect(
      File(project.sourceLocation('store_catalog/index.json')).absolute.uri,
      inside,
    );
    expect(
      project.sourceLocation('https://e.com/index.json'),
      'https://e.com/index.json',
    );
    // The same catalog, however the lockfile recorded it.
    expect(project.recordsSource('store_catalog/index.json', inside), isTrue);
    expect(project.recordsSource('store_catalog', inside), isTrue);
    expect(project.recordsSource('$inside', inside), isTrue);
    expect(project.recordsSource('other/index.json', inside), isFalse);
    expect(project.recordsSource('https://e.com/index.json', inside), isFalse);
  });
}
