// Installing, updating and removing items in a real project folder — and
// proving that a failure at any step, or a crash, leaves it exactly as it
// was.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import 'support/temp_project.dart';
import 'support/test_catalog.dart';

const String pubspecText =
    'name: app\r\n'
    'publish_to: none\r\n'
    'environment:\r\n'
    '  sdk: ^3.0.0\r\n'
    '\r\n'
    '# The game\'s own dependencies. Keep this comment.\r\n'
    'dependencies:\r\n'
    '  flutter:\r\n'
    '    sdk: flutter\r\n'
    '  just_game_engine: ^1.0.0\r\n'
    'dev_dependencies:\r\n'
    '  just_game_engine_editor: ^0.1.0\r\n';

final List<TestItem> items = [
  TestItem(
    'just_art_knight',
    versions: ['1.0.0', '1.1.0'],
    attribution: 'Knight by Tester',
  ),
  TestItem(
    'just_tool',
    kind: ItemKind.editorExtension,
    category: 'editors',
    modules: ['ToolModule'],
    files: {'lib/editor.dart': 'class ToolModule {}'},
  ),
  TestItem(
    'just_kit',
    kind: ItemKind.kit,
    category: 'kits',
    modules: ['KitModule'],
    extensions: ['JustKit.extension'],
    dependencies: {'just_art_knight': '^1.0.0'},
    files: {'lib/editor.dart': '', 'lib/just_kit.dart': ''},
  ),
  TestItem(
    'just_tiled',
    kind: ItemKind.runtimeLibrary,
    category: 'libraries',
    versions: ['0.4.1'],
  ),
  TestItem(
    'just_art_bad',
    mutate: (v, files) => files['sprites/evil.exe'] = [0x4d, 0x5a],
  ),
];

class Fixture {
  Fixture._(
    this.dir,
    this.project,
    this.source,
    this.catalog,
    this.pub,
    this.installer,
  );

  static Future<Fixture> create({
    Map<String, String> extraFiles = const {},
  }) async {
    final dir = tempDir('install');
    writeFiles(dir, {'pubspec.yaml': pubspecText, ...extraFiles});
    final source = buildCatalog(tempDir('catalog'), items);
    final catalog = StoreCatalog([
      ('test', source, (await source.fetchIndex()).index),
    ]);
    final pub = FakePub();
    final project = StoreProject(dir.path);
    return Fixture._(
      dir,
      project,
      source,
      catalog,
      pub,
      StoreInstaller(
        project: project,
        pub: pub,
        clock: () => DateTime.utc(2026, 10, 7, 12),
      ),
    );
  }

  final Directory dir;
  final StoreProject project;
  final FolderStoreSource source;
  final StoreCatalog catalog;
  final FakePub pub;
  final StoreInstaller installer;

  Future<Planner> planner() async => Planner(
    catalog,
    ProjectState.read(project, await OverridesTarget.detect(project)),
  );

  Future<InstallResult> install(String id, {Version? version}) async =>
      installer.apply((await planner()).install(id, version: version));

  String read(String rel) => project.file(rel).readAsStringSync();
  bool exists(String rel) =>
      project.file(rel).existsSync() || project.dir(rel).existsSync();
}

void main() {
  test('content: the folder, both pubspec blocks, the lockfile', () async {
    final f = await Fixture.create();
    final progress = <String>[];
    final plan = (await f.planner()).install('just_art_knight');
    final result = await f.installer.apply(
      plan,
      onProgress: (p) => progress.add(p.message),
    );

    expect(
      f.exists(
        'packages/characters/just_art_knight/sprites/just_art_knight.png',
      ),
      isTrue,
    );
    expect(
      f.exists('packages/characters/just_art_knight/just_store.json'),
      isTrue,
    );
    final pubspec = f.read('pubspec.yaml');
    // Every line the project had is still there, in order: the store only
    // adds its block.
    final lines = pubspec.split('\r\n');
    var at = 0;
    for (final line in pubspecText.split('\r\n').where((l) => l.isNotEmpty)) {
      at = lines.indexOf(line, at);
      expect(at, isNot(-1), reason: line);
      at++;
    }
    expect(
      pubspec,
      contains("# The game's own dependencies. Keep this comment.\r\n"),
    );
    expect(
      pubspec,
      isNot(contains(RegExp(r'[^\r]\n'))),
      reason: 'CRLF throughout',
    );
    final editor = PubspecEditor.parse(pubspec, marker: storeBlock);
    expect(editor.managed('dependencies'), {
      'just_art_knight': const PathDependency(
        'packages/characters/just_art_knight',
      ),
    });
    expect(editor.managed('dependency_overrides').keys, ['just_art_knight']);
    expect(editor.managed('dev_dependencies'), isEmpty);

    final lock = f.project.readLock();
    final item = lock.items['just_art_knight']!;
    expect(item.version, '1.1.0');
    expect(item.origin, ItemOrigin.vendored);
    expect(item.source, 'test');
    expect(item.archive!.url, startsWith('file:'));
    expect(item.files.keys, contains('sprites/just_art_knight.json'));
    expect(item.installedAt, DateTime.utc(2026, 10, 7, 12));

    expect(f.read(StoreProject.modulesFile), contains('storeModules() => [];'));
    expect(
      f.read(StoreProject.extensionsFile),
      contains('storeExtensions = [];'),
    );
    expect(
      result.changedAssets,
      contains('packages/just_art_knight/sprites/just_art_knight.png'),
    );
    expect(result.needsRestart, isFalse);
    expect(f.pub.calls, ['get']);
    expect(
      progress,
      containsAll([
        'Downloading Just Art Knight 1.1.0',
        'Resolving packages (pub get)',
        'Done',
      ]),
    );
    expect(f.exists('.dart_tool/just_core_cli/txn'), isFalse);
    expect(f.exists('.dart_tool/just_core_cli/staging'), isFalse);
    expect(f.exists('.dart_tool/just_core_cli/lock'), isFalse);
  });

  test(
    'an editor extension is a dev dependency and registers its module',
    () async {
      final f = await Fixture.create();
      final result = await f.install('just_tool');
      final editor = PubspecEditor.parse(
        f.read('pubspec.yaml'),
        marker: storeBlock,
      );
      expect(editor.managed('dev_dependencies').keys, ['just_tool']);
      expect(editor.managed('dependencies'), isEmpty);
      expect(
        f.read(StoreProject.modulesFile),
        contains("import 'package:just_tool/editor.dart' as s0;"),
      );
      expect(f.read(StoreProject.modulesFile), contains('  s0.ToolModule(),'));
      expect(result.needsRestart, isTrue);
    },
  );

  test(
    'a kit brings its dependency, registers both lists, and asks for setup',
    () async {
      final f = await Fixture.create();
      final result = await f.install('just_kit');
      final lock = f.project.readLock();
      expect(lock.items.keys, ['just_art_knight', 'just_kit']);
      expect(lock.items['just_art_knight']!.direct, isFalse);
      final editor = PubspecEditor.parse(
        f.read('pubspec.yaml'),
        marker: storeBlock,
      );
      expect(editor.managed('dependencies').keys, [
        'just_kit',
      ], reason: 'only what was asked for');
      expect(editor.managed('dependency_overrides').keys, [
        'just_art_knight',
        'just_kit',
      ]);
      expect(
        f.read(StoreProject.extensionsFile),
        contains('  s0.JustKit.extension,'),
      );
      expect(result.setupSnippets, {'Just Kit': '// set up just_kit'});
    },
  );

  test('a runtime library is a hosted dependency, nothing copied', () async {
    final f = await Fixture.create();
    await f.install('just_tiled');
    final editor = PubspecEditor.parse(
      f.read('pubspec.yaml'),
      marker: storeBlock,
    );
    expect(editor.managed('dependencies'), {
      'just_tiled': const HostedDependency('^0.4.1'),
    });
    expect(editor.managed('dependency_overrides'), isEmpty);
    expect(f.exists('packages/libraries'), isFalse);
    expect(f.project.readLock().items['just_tiled']!.origin, ItemOrigin.hosted);
  });

  test(
    'overrides go to pubspec_overrides.yaml, mirrored when it is git-ignored',
    () async {
      const overrides =
          '# melos_managed_dependency_overrides: melos_pkg\n'
          'dependency_overrides:\n'
          '  melos_pkg:\n'
          '    path: ../melos_pkg\n';
      final f = await Fixture.create(
        extraFiles: {
          'pubspec_overrides.yaml': overrides,
          '.gitignore': 'pubspec_overrides.yaml\n',
        },
      );
      await f.install('just_art_knight');
      final active = PubspecEditor.parse(
        f.read('pubspec_overrides.yaml'),
        marker: storeBlock,
      );
      expect(active.managed('dependency_overrides').keys, ['just_art_knight']);
      expect(active.unmanaged('dependency_overrides').keys, ['melos_pkg']);
      expect(f.read('pubspec_overrides.yaml'), startsWith(overrides));
      final mirror = PubspecEditor.parse(
        f.read('pubspec.yaml'),
        marker: storeBlock,
      );
      expect(mirror.managed('dependency_overrides').keys, ['just_art_knight']);
    },
  );

  test('update swaps the folder and keeps the old one in the trash', () async {
    final f = await Fixture.create();
    await f.install('just_art_knight', version: Version.parse('1.0.0'));
    expect(
      f.read('packages/characters/just_art_knight/sprites/just_art_knight.png'),
      'png-1.0.0',
    );
    final plan = (await f.planner()).update('just_art_knight');
    expect(plan.changes.single.kind, ChangeKind.update);
    await f.installer.apply(plan);
    expect(
      f.read('packages/characters/just_art_knight/sprites/just_art_knight.png'),
      'png-1.1.0',
    );
    expect(f.project.readLock().items['just_art_knight']!.version, '1.1.0');
    final trash = Directory('${f.dir.path}/.editor_trash/store');
    expect(
      trash
          .listSync(recursive: true)
          .whereType<File>()
          .any((x) => x.readAsStringSync() == 'png-1.0.0'),
      isTrue,
    );
  });

  test('uninstall gives back the original pubspec, byte for byte', () async {
    final f = await Fixture.create();
    await f.install('just_kit');
    final plan = (await f.planner()).uninstall('just_kit');
    expect(plan.changes.map((c) => c.id), ['just_kit', 'just_art_knight']);
    final result = await f.installer.apply(plan);
    expect(f.read('pubspec.yaml'), pubspecText);
    expect(f.exists('packages/kits/just_kit'), isFalse);
    expect(f.exists('packages/characters/just_art_knight'), isFalse);
    expect(f.project.readLock().items, isEmpty);
    expect(
      f.read(StoreProject.extensionsFile),
      contains('storeExtensions = [];'),
    );
    expect(
      result.changedAssets,
      contains('packages/just_art_knight/sprites/just_art_knight.png'),
    );
  });

  group('all or nothing', () {
    for (final step in InstallStep.values) {
      test('a failure after ${step.name} changes nothing', () async {
        final f = await Fixture.create();
        await f.install('just_art_knight', version: Version.parse('1.0.0'));
        final before = snapshot(f.dir);
        f.installer.failAfter = step;
        final plan = (await f.planner()).install('just_kit');
        await expectLater(
          f.installer.apply(plan),
          throwsA(
            isA<InstallFailure>().having(
              (e) => e.rolledBack,
              'rolledBack',
              isTrue,
            ),
          ),
        );
        _expectSame(snapshot(f.dir), before);
        expect(f.exists('.dart_tool/just_core_cli/txn'), isFalse);
        expect(f.exists('.dart_tool/just_core_cli/lock'), isFalse);
      });
    }

    test('an update that fails puts the old version back', () async {
      final f = await Fixture.create();
      await f.install('just_art_knight', version: Version.parse('1.0.0'));
      final before = snapshot(f.dir);
      f.installer.failAfter = InstallStep.locked;
      await expectLater(
        f.installer.apply((await f.planner()).update('just_art_knight')),
        throwsA(isA<InstallFailure>()),
      );
      _expectSame(snapshot(f.dir), before);
    });

    test('pub get failing undoes the install and says why', () async {
      final f = await Fixture.create();
      final before = snapshot(f.dir);
      f.pub.next = const PubResult(
        1,
        '',
        'Because app depends on x, version solving failed.',
      );
      await expectLater(
        f.install('just_art_knight'),
        throwsA(
          isA<InstallFailure>().having(
            (e) => e.message,
            'message',
            contains('version solving failed'),
          ),
        ),
      );
      _expectSame(snapshot(f.dir), before);
    });

    test('a crash mid-install is rolled back next time', () async {
      final f = await Fixture.create();
      final before = snapshot(f.dir);
      f.installer.crashAfter = InstallStep.pubspecs;
      await expectLater(
        f.install('just_art_knight'),
        throwsA(isA<SimulatedCrash>()),
      );
      expect(
        f.exists('packages/characters/just_art_knight'),
        isTrue,
        reason: 'left half done',
      );
      expect(await StoreInstaller.recover(f.project), isTrue);
      _expectSame(snapshot(f.dir), before);
      expect(await StoreInstaller.recover(f.project), isFalse);
      // And the next install works.
      f.installer.crashAfter = null;
      await f.install('just_art_knight');
      expect(f.project.readLock().items, contains('just_art_knight'));
    });

    test('a package that fails its checks never touches the project', () async {
      final f = await Fixture.create();
      final before = snapshot(f.dir);
      await expectLater(
        f.install('just_art_bad'),
        throwsA(
          isA<InstallFailure>()
              .having((e) => e.rolledBack, 'rolledBack', isFalse)
              .having((e) => e.message, 'message', contains('evil.exe')),
        ),
      );
      _expectSame(snapshot(f.dir), before);
    });

    test('cancelling before the project is touched', () async {
      final f = await Fixture.create();
      final before = snapshot(f.dir);
      final token = CancelToken()..cancel();
      await expectLater(
        f.installer.apply(
          (await f.planner()).install('just_art_knight'),
          cancel: token,
        ),
        throwsA(isA<CancelledException>()),
      );
      _expectSame(snapshot(f.dir), before);
    });

    test('one install at a time; a stale lock is cleared', () async {
      final f = await Fixture.create();
      final lock = f.project.file('.dart_tool/just_core_cli/lock')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('1234');
      await expectLater(
        f.install('just_art_knight'),
        throwsA(
          isA<InstallFailure>().having(
            (e) => e.message,
            'message',
            contains('Another install'),
          ),
        ),
      );
      lock.setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 11)),
      );
      await f.install('just_art_knight');
      expect(f.project.readLock().items, contains('just_art_knight'));
    });

    test('a plan with blockers is refused', () async {
      final f = await Fixture.create();
      await f.install('just_art_knight');
      final plan = (await f.planner()).install('just_art_knight');
      await expectLater(
        f.installer.apply(plan),
        throwsA(isA<InstallFailure>()),
      );
    });
  });

  test('a dependency installed on purpose joins the pubspec', () async {
    final f = await Fixture.create();
    await f.install('just_kit');
    expect(f.project.readLock().items['just_art_knight']!.direct, isFalse);
    final before = Map.of(f.project.readLock().items['just_art_knight']!.files);
    final result = await f.install('just_art_knight');
    expect(result.changes.single.kind, ChangeKind.adopt);
    expect(result.needsRestart, isFalse);
    final knight = f.project.readLock().items['just_art_knight']!;
    expect(knight.direct, isTrue);
    expect(knight.files, before, reason: 'nothing replaced');
    expect(
      PubspecEditor.parse(
        f.read('pubspec.yaml'),
        marker: storeBlock,
      ).managed('dependencies').keys,
      containsAll(['just_art_knight', 'just_kit']),
    );
    // Now the kit can go, and the knight stays.
    final plan = (await f.planner()).uninstall('just_kit');
    expect(plan.changes.map((c) => c.id), ['just_kit']);
  });

  test("a package may not depend on a store item it doesn't declare", () async {
    final dir = tempDir('install');
    writeFiles(dir, {'pubspec.yaml': pubspecText});
    final source = buildCatalog(tempDir('catalog'), [
      TestItem('just_art_knight'),
      TestItem(
        'sneaky_kit',
        kind: ItemKind.kit,
        category: 'kits',
        files: {'lib/sneaky_kit.dart': ''},
        // Its pubspec needs the knight; neither its manifest nor the
        // catalog says so, so the store would not install it.
        mutate: (v, files) => files['pubspec.yaml'] = utf8.encode(
          'name: sneaky_kit\nversion: $v\nenvironment:\n  sdk: ^3.0.0\n'
          "dependencies:\n  just_art_knight: '^1.0.0'\n",
        ),
      ),
    ]);
    final catalog = StoreCatalog([
      ('test', source, (await source.fetchIndex()).index),
    ]);
    final project = StoreProject(dir.path);
    final plan = Planner(
      catalog,
      ProjectState.read(project, await OverridesTarget.detect(project)),
    ).install('sneaky_kit');
    final before = snapshot(dir);
    await expectLater(
      StoreInstaller(project: project, pub: FakePub()).apply(plan),
      throwsA(
        isA<InstallFailure>().having(
          (e) => e.message,
          'message',
          contains('pub would look for another package named just_art_knight'),
        ),
      ),
    );
    expect(snapshot(dir), before);
  });

  test("the manifest and the catalog agree on what it needs", () async {
    final dir = tempDir('install');
    writeFiles(dir, {'pubspec.yaml': pubspecText});
    final catalogDir = tempDir('catalog');
    final source = buildCatalog(catalogDir, [
      TestItem('just_art_knight'),
      TestItem(
        'just_kit',
        kind: ItemKind.kit,
        category: 'kits',
        dependencies: {'just_art_knight': '^1.0.0'},
        files: {'lib/just_kit.dart': ''},
      ),
    ]);
    // The catalog forgets the kit's dependency.
    final file = File('${catalogDir.path}/index.json');
    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    for (final item in (json['items'] as List).cast<Map<String, Object?>>()) {
      if (item['id'] != 'just_kit') continue;
      ((item['versions'] as List).single as Map)['dependencies'] =
          <String, String>{};
    }
    file.writeAsStringSync(jsonEncode(json));
    final project = StoreProject(dir.path);
    final plan = Planner(
      StoreCatalog([('test', source, (await source.fetchIndex()).index)]),
      ProjectState.read(project, await OverridesTarget.detect(project)),
    ).install('just_kit');
    await expectLater(
      StoreInstaller(project: project, pub: FakePub()).apply(plan),
      throwsA(
        isA<InstallFailure>().having(
          (e) => e.message,
          'message',
          contains('disagree on the store items it needs'),
        ),
      ),
    );
  });

  test(
    'a catalog claiming a recorded source id gets an id of its own',
    () async {
      final f = await Fixture.create();
      await f.install('just_art_knight');
      expect(f.project.readLock().sources.map((s) => s.id), ['just', 'test']);
      // Another catalog, also calling itself "test".
      final other = buildCatalog(tempDir('other'), [
        TestItem('just_art_other'),
      ]);
      final plan = Planner(
        StoreCatalog([('test', other, (await other.fetchIndex()).index)]),
        ProjectState.read(f.project, await OverridesTarget.detect(f.project)),
      ).install('just_art_other');
      await f.installer.apply(plan);
      final lock = f.project.readLock();
      expect(lock.sources.map((s) => s.id), ['just', 'test', 'test-2']);
      expect(lock.sources[1].url, '${f.source.indexUri}', reason: 'unchanged');
      expect(lock.items['just_art_other']!.source, 'test-2');
    },
  );

  test('end to end with real pub get, then the generated files run', () async {
    // The project depends on stand-ins for the engine and the editor. The
    // kit asks for them by version, as published packages do; the project's
    // own overrides point them at the stand-ins, and the store's block
    // points the kit at its installed copy.
    final dir = tempDir('e2e');
    writeFiles(dir, {
      'pubspec.yaml': pubspecOf(
        'app',
        extra:
            'dependencies:\n'
            '  just_game_engine_editor: {path: stubs/just_game_engine_editor}\n'
            '  just_game_engine: {path: stubs/just_game_engine}\n'
            'dependency_overrides:\n'
            '  just_game_engine_editor:\n'
            '    path: stubs/just_game_engine_editor\n'
            '  just_game_engine:\n'
            '    path: stubs/just_game_engine\n',
      ),
      'stubs/just_game_engine_editor/pubspec.yaml': pubspecOf(
        'just_game_engine_editor',
        version: '1.2.0',
      ),
      'stubs/just_game_engine_editor/lib/just_game_engine_editor.dart':
          'abstract class EditorModule { String get id; }\n',
      'stubs/just_game_engine/pubspec.yaml': pubspecOf(
        'just_game_engine',
        version: '2.0.0',
      ),
      'stubs/just_game_engine/lib/just_game_engine.dart':
          'abstract interface class ContextExtension { String get id; }\n',
      'bin/main.dart':
          "import '../lib/editor/store_modules.g.dart';\n"
          "import '../lib/game/store_extensions.g.dart';\n"
          'void main() {\n'
          "  print(storeModules().map((m) => m.id).join(','));\n"
          "  print(storeExtensions.map((e) => e.id).join(','));\n"
          '}\n',
    });
    final source = buildCatalog(tempDir('catalog'), [
      TestItem(
        'just_kit',
        kind: ItemKind.kit,
        category: 'kits',
        modules: ['KitModule'],
        extensions: ['JustKit.extension'],
        pubDependencies: {
          'just_game_engine_editor': '^1.0.0',
          'just_game_engine': '^2.0.0',
        },
        files: {
          'lib/editor.dart':
              "import 'package:just_game_engine_editor/just_game_engine_editor.dart';\n"
              "class KitModule extends EditorModule { @override String get id => 'kit'; }\n",
          'lib/just_kit.dart':
              "import 'package:just_game_engine/just_game_engine.dart';\n"
              'abstract final class JustKit { static const ContextExtension extension = _Ext(); }\n'
              "class _Ext implements ContextExtension { const _Ext(); @override String get id => 'kit'; }\n",
        },
      ),
    ]);
    final catalog = StoreCatalog([
      ('test', source, (await source.fetchIndex()).index),
    ]);
    final project = StoreProject(dir.path);
    final get = await runDart(['pub', 'get', '--offline'], dir);
    expect(get.exitCode, 0, reason: '${get.stdout}${get.stderr}');
    final planner = Planner(
      catalog,
      ProjectState.read(project, await OverridesTarget.detect(project)),
    );
    final installer = StoreInstaller(project: project, pub: _DartPub());
    await installer.apply(planner.install('just_kit'));
    final run = await runDart(['run', 'bin/main.dart'], dir);
    expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
    expect((run.stdout as String).trim().split(RegExp(r'\r?\n')), [
      'kit',
      'kit',
    ]);
    // The resolution really points at the installed copy.
    final config = PackageConfig.read(dir.path)!;
    expect(
      config.packages['just_kit']!.rootPath,
      endsWith('/packages/kits/just_kit'),
    );

    // And uninstalling resolves again without it.
    final again = Planner(
      catalog,
      ProjectState.read(project, await OverridesTarget.detect(project)),
    );
    await installer.apply(again.uninstall('just_kit'));
    expect(PackageConfig.read(dir.path)!.packages, isNot(contains('just_kit')));
    final rerun = await runDart(['run', 'bin/main.dart'], dir);
    expect((rerun.stdout as String).trim().split(RegExp(r'\r?\n')).first, '');
  });
}

/// Real `dart pub get --offline`, with the Dart running the tests.
class _DartPub implements PubRunner {
  @override
  Future<PubResult> get(String projectRoot, {bool offline = false}) async {
    final r = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: projectRoot);
    return PubResult(r.exitCode, '${r.stdout}', '${r.stderr}');
  }
}

void _expectSame(Map<String, List<int>> after, Map<String, List<int>> before) {
  expect(after.keys.toSet(), before.keys.toSet());
  for (final key in before.keys) {
    expect(
      utf8.decode(after[key]!, allowMalformed: true),
      utf8.decode(before[key]!, allowMalformed: true),
      reason: key,
    );
  }
}
