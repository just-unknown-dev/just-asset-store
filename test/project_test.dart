// The project-side pieces on disk: the project and its lockfile file, file
// hashes, pub's resolution files, the SDK, the overrides target and the
// reference scan. The lockfile's own format is in lockfile_test.dart.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import 'support/temp_project.dart';

void main() {
  group('StoreRegistry', () {
    test('generated files checked out with CRLF are up to date', () {
      final dir = tempDir('proj');
      final project = StoreProject(dir.path);
      writeFiles(dir, {
        StoreProject.modulesFile: StoreCodegen.modules(
          const [],
        ).replaceAll('\n', '\r\n'),
        StoreProject.extensionsFile: StoreCodegen.extensions(
          const [],
        ).replaceAll('\n', '\r\n'),
      });
      expect(StoreRegistry.outdated(project), isEmpty);
      expect(StoreRegistry.write(project), isEmpty, reason: 'nothing to write');
    });

    test('only the files a project can compile', () {
      final kit = StoreLock(
        items: {
          'just_kit': const LockedItem(
            version: '^1.0.0',
            kind: ItemKind.runtimeLibrary,
            origin: ItemOrigin.hosted,
          ),
        },
      );
      // Nothing installed and nothing generated yet: nothing is out of date.
      final fresh = StoreProject(tempDir('fresh').path);
      writeFiles(Directory(fresh.root), {'pubspec.yaml': pubspecOf('app')});
      expect(StoreRegistry.wanted(fresh, StoreLock()), isEmpty);
      expect(StoreRegistry.outdated(fresh), isEmpty);
      // A plain Flutter project: no file that imports what it doesn't have.
      expect(StoreRegistry.wanted(fresh, kit), isEmpty);
      // A Just Game Engine project gets both.
      final game = StoreProject(tempDir('game').path);
      writeFiles(Directory(game.root), {
        'pubspec.yaml': pubspecOf(
          'game',
          extra:
              'dependencies:\n  just_game_engine: ^1.0.0\n'
              'dev_dependencies:\n  just_game_engine_editor: ^0.1.0\n',
        ),
      });
      expect(StoreRegistry.wanted(game, kit), {
        StoreProject.modulesFile,
        StoreProject.extensionsFile,
      });
    });
  });

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
      expect(
        StoreProject.packagePath('characters', 'k'),
        'packages/characters/k',
      );
      File('${dir.path}/just_store.lock.json').writeAsStringSync('{oops');
      expect(
        project.readLock,
        throwsA(
          isA<StoreFormatException>().having(
            (e) => e.file,
            'file',
            'just_store.lock.json',
          ),
        ),
      );
    });
  });

  group('FileHashes', () {
    test('text ignores CRLF, binary does not', () {
      final lf = utf8.encode('a\nb\n');
      final crlf = utf8.encode('a\r\nb\r\n');
      expect(FileHashes.of('x.json', lf), FileHashes.of('x.json', crlf));
      expect(FileHashes.of('LICENSE', lf), FileHashes.of('LICENSE', crlf));
      expect(FileHashes.of('x.png', lf), isNot(FileHashes.of('x.png', crlf)));
      // A lone CR is content, not a line ending.
      expect(
        FileHashes.of('x.txt', utf8.encode('a\rb')),
        isNot(FileHashes.of('x.txt', utf8.encode('ab'))),
      );
    });

    test('of a folder skips tool folders', () {
      final dir = tempDir('hashes');
      writeFiles(dir, {
        'pubspec.yaml': 'name: x\n',
        'assets/a.json': '{}',
        '.dart_tool/package_config.json': '{}',
        'build/out.txt': 'x',
        'pubspec.lock': '',
      });
      expect(FileHashes.ofFolder(dir).keys.toList(), [
        'assets/a.json',
        'pubspec.yaml',
      ]);
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

  group('ReferenceScan', () {
    test('imports, asset paths and component types', () {
      final dir = tempDir('refs');
      writeFiles(dir, {
        'lib/main_editor.dart':
            "import 'package:just_kit/editor.dart';\nvoid main() {}\n",
        'lib/editor/store_modules.g.dart':
            "import 'package:just_kit/editor.dart' as s0;\n",
        'lib/game/sprites.dart':
            "const p = 'packages/just_kit/assets/hero.json';\n",
        'assets/scenes/level.scene.json':
            '{"entities": [{"components": [{"type": "KitComponent", "fields": {}}]}]}\n',
        'assets/scenes/other.scene.json': '{"type": "TransformComponent"}\n',
        'packages/characters/user_pack/assets/x.json':
            '{"atlas": "packages/just_kit/a.json"}\n',
        'packages/kits/just_kit/assets/self.json':
            '{"a": "packages/just_kit/b.json"}\n',
      });
      final refs = ReferenceScan.find(
        StoreProject(dir.path),
        'just_kit',
        componentTypes: ['KitComponent'],
        alsoSearch: ['packages/characters/user_pack', 'packages/kits/just_kit'],
        excluding: 'packages/kits/just_kit',
      );
      expect(
        {for (final r in refs) '${r.kind.name} ${r.file}'},
        {
          'code lib/main_editor.dart',
          'asset lib/game/sprites.dart',
          'component assets/scenes/level.scene.json',
          'asset packages/characters/user_pack/assets/x.json',
        },
      );
      expect(refs.firstWhere((r) => r.kind == ReferenceKind.code).line, 1);
    });
  });
}
