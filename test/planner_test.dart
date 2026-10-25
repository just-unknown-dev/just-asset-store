// The planner: dependencies, version conflicts, what the project already
// has, and every reason it refuses.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import 'support/temp_project.dart';
import 'support/test_catalog.dart';

Future<StoreCatalog> catalogOf(
  List<TestItem> items, {
  String id = 'test',
}) async {
  final source = buildCatalog(tempDir('cat'), items, sourceId: id);
  return StoreCatalog([(id, source, (await source.fetchIndex()).index)]);
}

ItemManifest manifest(
  String id, {
  String version = '1.0.0',
  Map<String, String> deps = const {},
}) => ItemManifest.parse(
  jsonEncode({
    'schema': 1,
    'id': id,
    'name': id,
    'version': version,
    'kind': 'kit',
    'category': 'kits',
    'dependencies': deps,
  }),
);

LockedItem locked(
  String id,
  String version, {
  bool direct = true,
  bool system = false,
  String category = 'kits',
}) => LockedItem(
  version: version,
  kind: ItemKind.kit,
  origin: ItemOrigin.vendored,
  category: category,
  path: 'plugins/$category/$id',
  direct: direct,
  system: system,
);

Iterable<String> blockers(InstallPlan p) => p.blockers.map((b) => b.message);

void main() {
  test('installs an item, and what it needs', () async {
    final catalog = await catalogOf([
      TestItem('just_art_knight', versions: ['1.0.0', '1.1.0']),
      TestItem(
        'just_kit',
        kind: ItemKind.kit,
        category: 'kits',
        dependencies: {'just_art_knight': '^1.0.0'},
      ),
    ]);
    final plan = Planner(
      catalog,
      ProjectState(lock: StoreLock()),
    ).install('just_kit');
    expect(plan.canApply, isTrue, reason: '${plan.issues}');
    expect(
      plan.changes.map((c) => '${c.id} ${c.version!.version} ${c.direct}'),
      ['just_art_knight 1.1.0 false', 'just_kit 1.0.0 true'],
    );
    expect(plan.changes.first.reason, 'Needed by Just Kit');
    expect(plan.changes.first.path, 'packages/characters/just_art_knight');
    expect(plan.changes.last.path, 'plugins/kits/just_kit');
    expect(plan.needsRestart, isTrue, reason: 'a kit is code');
    expect(plan.downloadBytes, greaterThan(0));
  });

  test('an exact version', () async {
    final catalog = await catalogOf([
      TestItem('just_art_knight', versions: ['1.0.0', '1.1.0']),
    ]);
    final plan = Planner(
      catalog,
      ProjectState(lock: StoreLock()),
    ).install('just_art_knight', version: Version.parse('1.0.0'));
    expect('${plan.changes.single.version!.version}', '1.0.0');
    expect(plan.needsRestart, isFalse, reason: 'content');
  });

  test('installed items keep their constraints', () async {
    final catalog = await catalogOf([
      TestItem(
        'just_core',
        category: 'kits',
        kind: ItemKind.kit,
        versions: ['1.0.0', '1.5.0', '2.0.0'],
      ),
    ]);
    final state = ProjectState(
      lock: StoreLock(
        items: {
          'just_user': locked('just_user', '1.0.0'),
          'just_core': locked('just_core', '1.0.0', direct: false),
        },
      ),
      manifests: {
        'just_user': manifest('just_user', deps: {'just_core': '^1.0.0'}),
      },
    );
    final planner = Planner(catalog, state);
    // An update picks the newest version just_user still accepts.
    final update = planner.update('just_core');
    expect('${update.changes.single.version!.version}', '1.5.0');
    expect(update.changes.single.kind, ChangeKind.update);
    // Asking for 2.0.0 explicitly is refused, naming who needs what.
    final forced = planner.install(
      'just_core',
      version: Version.parse('2.0.0'),
    );
    expect(forced.canApply, isFalse);
    expect(
      blockers(forced).single,
      allOf(
        contains('just_user needs ^1.0.0'),
        contains('you asked for 2.0.0'),
      ),
    );
    expect('${planner.availableUpdate('just_core')!.version}', '2.0.0');
  });

  test('requires is checked against the project', () async {
    final catalog = await catalogOf([
      TestItem(
        'just_kit',
        category: 'kits',
        kind: ItemKind.kit,
        requires: {'just_game_engine': '^3.0.0'},
      ),
    ]);
    final plan = Planner(
      catalog,
      ProjectState(
        lock: StoreLock(),
        environment: {'just_game_engine': Version.parse('2.0.0')},
      ),
    ).install('just_kit');
    expect(
      blockers(plan).single,
      contains('needs just_game_engine ^3.0.0; this project has 2.0.0'),
    );
  });

  test(
    'a package or folder of the same name the store did not install',
    () async {
      final catalog = await catalogOf([TestItem('just_art_knight')]);
      final dir = tempDir('graph');
      writeFiles(dir, {
        '.dart_tool/package_graph.json': jsonEncode({
          'roots': ['app'],
          'packages': [
            {
              'name': 'app',
              'version': '1.0.0',
              'dependencies': ['just_art_knight'],
            },
            {'name': 'just_art_knight', 'version': '0.1.0', 'dependencies': []},
          ],
        }),
      });
      var plan = Planner(
        catalog,
        ProjectState(lock: StoreLock(), graph: PackageGraph.read(dir.path)),
      ).install('just_art_knight');
      expect(blockers(plan).single, contains('already uses a package named'));
      plan = Planner(
        catalog,
        ProjectState(
          lock: StoreLock(),
          existingFolders: {'packages/characters/just_art_knight'},
        ),
      ).install('just_art_knight');
      expect(blockers(plan).single, contains('already exists'));
    },
  );

  test('a folder of the item in either root, in any letter case', () async {
    final catalog = await catalogOf([
      TestItem('just_art_knight'),
      TestItem('just_kit', kind: ItemKind.kit, category: 'kits'),
      TestItem(
        'just_tool',
        kind: ItemKind.editorExtension,
        category: 'editors',
      ),
    ]);
    InstallPlan plan(String id, Set<String> folders) => Planner(
      catalog,
      ProjectState(lock: StoreLock(), existingFolders: folders),
    ).install(id);

    // Its own folder.
    expect(
      blockers(plan('just_kit', {'plugins/kits/just_kit'})).single,
      'plugins/kits/just_kit already exists, and the store did not put it '
      'there. Move it away first.',
    );
    // The same folder in the other root would be a second copy.
    expect(
      blockers(plan('just_kit', {'packages/kits/just_kit'})).single,
      'packages/kits/just_kit already exists, and the store did not put it '
      'there. Just Kit goes in plugins/kits/just_kit, so the project would '
      'have two copies of it. Move it away first.',
    );
    expect(
      blockers(
        plan('just_art_knight', {'plugins/characters/just_art_knight'}),
      ).single,
      contains('Just Art Knight goes in packages/characters/just_art_knight'),
    );
    expect(
      blockers(plan('just_tool', {'packages/editors/just_tool'})).single,
      contains('goes in plugins/editors/just_tool'),
    );
    // Another category or another name is no clash.
    expect(
      plan('just_kit', {
        'plugins/tools/just_kit',
        'plugins/kits/just_kit_extra',
        'packages/kits/other',
      }).blockers,
      isEmpty,
    );
    // Another letter case is, where the file system ignores case.
    final caseless = Platform.isWindows || Platform.isMacOS;
    for (final folder in ['Plugins/Kits/Just_Kit', 'PACKAGES/kits/just_kit']) {
      expect(
        blockers(plan('just_kit', {folder})).toList(),
        caseless ? [startsWith('$folder already exists')] : isEmpty,
        reason: folder,
      );
    }
  });

  test('paid items, community code and native plugins', () async {
    final catalog = await catalogOf([
      TestItem('just_art_paid', access: 'entitled'),
      TestItem(
        'their_tool',
        kind: ItemKind.editorExtension,
        category: 'editors',
        trust: 'community',
        nativePlugins: ['file_selector'],
      ),
      TestItem(
        'their_kit',
        kind: ItemKind.kit,
        category: 'kits',
        nativePlugins: ['audio_x'],
        attribution: 'Art by T.',
      ),
    ]);
    final planner = Planner(
      catalog,
      ProjectState(lock: StoreLock(), graph: const PackageGraph(['game'], {})),
    );
    expect(blockers(planner.install('just_art_paid')).single, contains('paid'));
    final tool = planner.install('their_tool');
    expect(tool.canApply, isTrue);
    final messages = tool.issues
        .map((i) => '${i.level.name}: ${i.message}')
        .join('\n');
    expect(
      messages,
      contains(
        'warning: Their Tool brings native plugins (file_selector). It installs as a dev dependency',
      ),
    );
    expect(
      messages,
      contains('warning: Their Tool is code from Tester (community)'),
    );
    expect(
      messages,
      isNot(contains('Brings native code')),
      reason: 'the native plugins have their own note',
    );
    final kitPlan = planner.install('their_kit');
    expect(
      kitPlan.issues.map((i) => i.message).join('\n'),
      allOf(contains('build into every version'), contains('Art by T.')),
    );
  });

  test('what an item declares it does is shown before it installs',
      () async {
    final catalog = await catalogOf([
      TestItem(
        'their_tool',
        kind: ItemKind.editorExtension,
        category: 'editors',
        trust: 'community',
        permissions: ['processes', 'network'],
      ),
    ]);
    final plan = Planner(
      catalog,
      ProjectState(lock: StoreLock(), graph: const PackageGraph(['game'], {})),
    ).install('their_tool');
    expect(
      plan.issues.map((i) => '${i.level.name}: ${i.message}'),
      contains(
        'warning: Their Tool connects to the internet and runs other '
        'programs, as it declares.',
      ),
    );
    expect(
      ItemPermission.describe(ItemPermission.values.toSet()),
      'connects to the internet, reads or writes files outside the '
      'project, runs other programs and brings native code (Flutter '
      'plugins)',
    );
  });

  test('nothing over 512 MiB is fetched', () async {
    final big = StoreIndex(
      source: const StoreSourceInfo('big', 'Big'),
      categories: const [StoreCategory('kits', 'Kits')],
      items: [
        StoreItem(
          id: 'huge_kit',
          name: 'Huge Kit',
          kind: ItemKind.kit,
          category: 'kits',
          trust: TrustLevel.official,
          versions: [
            StoreItemVersion(
              version: Version(1, 0, 0),
              archive: StoreArchive(
                url: 'a.zip',
                sha256: 'a' * 64,
                size: StoreArchive.maxSize + 1,
              ),
            ),
          ],
        ),
      ],
    );
    final source = MemoryStoreSource(big, const {});
    final plan = Planner(
      StoreCatalog([('big', source, big)]),
      ProjectState(lock: StoreLock(), graph: const PackageGraph(['game'], {})),
    ).install('huge_kit');
    expect(
      blockers(plan).single,
      'Huge Kit 1.0.0 is 513 MiB; the store installs archives of up to '
      '512 MiB.',
    );
    await expectLater(
      Downloader().archive(source, big.items.single, big.items.single.latest!),
      throwsA(isA<DownloadException>()),
    );
  });

  test('an experimental or deprecated item is asked about first', () async {
    final catalog = await catalogOf([
      TestItem(
        'just_new_kit',
        kind: ItemKind.kit,
        category: 'kits',
        stage: 'experimental',
      ),
      TestItem(
        'just_old_kit',
        kind: ItemKind.kit,
        category: 'kits',
        stage: 'deprecated',
        replacedBy: 'just_new_kit',
      ),
      TestItem('just_kit', kind: ItemKind.kit, category: 'kits'),
    ]);
    final planner = Planner(catalog, ProjectState(lock: StoreLock()));
    String warnings(String id) => planner
        .install(id)
        .issues
        .where((i) => i.level == IssueLevel.warning)
        .map((i) => i.message)
        .join('\n');
    expect(
      warnings('just_new_kit'),
      contains('Just New Kit 1.0.0 is experimental: it may change or break'),
    );
    expect(
      warnings('just_old_kit'),
      contains(
        'Just Old Kit is deprecated: it is no longer developed. Use Just New '
        'Kit instead.',
      ),
    );
    expect(warnings('just_kit'), isNot(contains('experimental')));
    expect(catalog.entry('just_old_kit')!.item.replacedBy, 'just_new_kit');
  });

  test('where an item comes from, never what it says', () async {
    final catalog = await catalogOf([
      TestItem('just_kit', kind: ItemKind.kit, category: 'kits'),
      TestItem(
        'their_kit',
        kind: ItemKind.kit,
        category: 'kits',
        trust: 'community',
      ),
    ]);
    final official = catalog.entry('just_kit')!;
    final theirs = catalog.entry('their_kit')!;
    expect(ItemSource.of(entry: official), ItemSource.official);
    expect(ItemSource.of(entry: theirs), ItemSource.thirdParty);
    expect(
      ItemSource.of(
        entry: CatalogEntry('github:octocat/kit', theirs.item),
      ),
      ItemSource.unlisted,
    );
    LockedItem locked({
      ItemOrigin origin = ItemOrigin.vendored,
      String? source,
      bool official = false,
    }) => LockedItem(
      version: '1.0.0',
      kind: ItemKind.kit,
      origin: origin,
      path: 'plugins/kits/x',
      source: source,
      official: official,
    );
    // What the project recorded wins over the catalog.
    expect(
      ItemSource.of(entry: official, installed: locked(origin: ItemOrigin.linked)),
      ItemSource.local,
    );
    expect(
      ItemSource.ofInstalled(locked(source: 'github:octocat/kit')),
      ItemSource.unlisted,
    );
    expect(ItemSource.ofInstalled(locked(official: true)), ItemSource.official);
    expect(ItemSource.ofInstalled(locked(source: 'studio')), ItemSource.thirdParty);
    expect(
      [for (final s in ItemSource.values) s.label],
      ['Official', 'Third Party', 'Unlisted', 'Local'],
    );
  });

  test('names only official items may have', () async {
    final catalog = await catalogOf([
      TestItem(
        'just_fake',
        category: 'kits',
        kind: ItemKind.kit,
        trust: 'community',
      ),
      TestItem(
        'flutter_test',
        category: 'kits',
        kind: ItemKind.kit,
        trust: 'community',
      ),
      TestItem('just_kit', category: 'kits', kind: ItemKind.kit),
    ]);
    final planner = Planner(
      catalog,
      ProjectState(lock: StoreLock(), graph: const PackageGraph(['game'], {})),
    );
    for (final id in ['just_fake', 'flutter_test']) {
      expect(
        blockers(planner.install(id)).single,
        contains("a name only the store's own team gives its items"),
        reason: id,
      );
    }
    expect(planner.install('just_kit').blockers, isEmpty);
    expect(ReservedNames.isReserved('just'), isTrue);
    expect(ReservedNames.isReserved('justice'), isFalse);
  });

  test(
    'a community item is not added to a project pub never resolved',
    () async {
      final catalog = await catalogOf([
        TestItem(
          'their_kit',
          category: 'kits',
          kind: ItemKind.kit,
          trust: 'community',
        ),
        TestItem('just_kit', category: 'kits', kind: ItemKind.kit),
      ]);
      final unresolved = Planner(catalog, ProjectState(lock: StoreLock()));
      expect(
        blockers(unresolved.install('their_kit')).single,
        startsWith('Run pub get in this project first'),
      );
      expect(
        unresolved.install('just_kit').blockers,
        isEmpty,
        reason: 'an official item is trusted with its name',
      );
    },
  );

  test(
    'no item takes the place of a package another one gets from pub.dev',
    () async {
      final catalog = await catalogOf([
        TestItem(
          'their_lib',
          category: 'kits',
          kind: ItemKind.kit,
          trust: 'community',
        ),
        TestItem(
          'their_kit',
          category: 'kits',
          kind: ItemKind.kit,
          trust: 'community',
          dependencies: {'their_lib': '^1.0.0'},
          pubDependencies: {'their_lib': '^1.0.0'},
        ),
      ]);
      final planner = Planner(
        catalog,
        ProjectState(
          lock: StoreLock(),
          graph: const PackageGraph(['game'], {}),
        ),
      );
      expect(
        blockers(planner.install('their_kit')),
        contains(
          'Their Kit needs the package "their_lib" from pub.dev, and Their Lib '
          'would take its place.',
        ),
      );
    },
  );

  test("a developer's own checkout is left alone", () async {
    final catalog = await catalogOf([
      TestItem('just_core', category: 'kits', kind: ItemKind.kit),
      TestItem(
        'just_kit',
        category: 'kits',
        kind: ItemKind.kit,
        dependencies: {'just_core': '^1.0.0'},
      ),
    ]);
    final state = ProjectState(
      lock: StoreLock(),
      foreignOverrides: {
        'just_core': const PathDependency('packages/just_core'),
      },
    );
    final plan = Planner(catalog, state).install('just_kit');
    expect(plan.changes.map((c) => c.id), ['just_kit']);
    expect(
      blockers(Planner(catalog, state).install('just_core')).single,
      contains('your own checkout'),
    );
  });

  test('already installed is not a change', () async {
    final catalog = await catalogOf([
      TestItem('just_kit', kind: ItemKind.kit, category: 'kits'),
    ]);
    final plan = Planner(
      catalog,
      ProjectState(
        lock: StoreLock(items: {'just_kit': locked('just_kit', '1.0.0')}),
      ),
    ).install('just_kit');
    expect(plan.changes, isEmpty);
    expect(plan.canApply, isFalse);
    expect(plan.issues.single.message, contains('already installed'));
  });

  test('items missing from every source', () async {
    final catalog = await catalogOf([
      TestItem(
        'just_kit',
        kind: ItemKind.kit,
        category: 'kits',
        dependencies: {'just_gone': '^1.0.0'},
      ),
    ]);
    final plan = Planner(
      catalog,
      ProjectState(lock: StoreLock()),
    ).install('just_kit');
    expect(
      blockers(plan).single,
      contains(
        '"just_gone" (needed by Just Kit) is not in any of your sources',
      ),
    );
  });

  test('runtime libraries are planned as pub dependencies', () async {
    final catalog = await catalogOf([
      TestItem(
        'just_tiled',
        kind: ItemKind.runtimeLibrary,
        category: 'libraries',
        versions: ['0.4.1'],
      ),
    ]);
    final plan = Planner(
      catalog,
      ProjectState(lock: StoreLock()),
    ).install('just_tiled');
    expect(plan.changes.single.itemKind, ItemKind.runtimeLibrary);
    expect(plan.changes.single.path, isNull);
    expect('${plan.changes.single.version!.pubConstraint}', '^0.4.1');
  });

  test('updateAll updates items installed on purpose', () async {
    final catalog = await catalogOf([
      TestItem(
        'just_a',
        kind: ItemKind.kit,
        category: 'kits',
        versions: ['1.0.0', '1.2.0'],
      ),
      TestItem(
        'just_b',
        kind: ItemKind.kit,
        category: 'kits',
        versions: ['1.0.0', '1.3.0'],
      ),
    ]);
    final plan = Planner(
      catalog,
      ProjectState(
        lock: StoreLock(
          items: {
            'just_a': locked('just_a', '1.0.0'),
            'just_b': locked('just_b', '1.0.0'),
          },
        ),
      ),
    ).updateAll();
    expect(plan.changes.map((c) => '${c.id} ${c.version!.version}'), [
      'just_a 1.2.0',
      'just_b 1.3.0',
    ]);
  });

  group('uninstall', () {
    test('takes dependencies nothing else needs', () async {
      final catalog = await catalogOf(const []);
      final state = ProjectState(
        lock: StoreLock(
          items: {
            'just_kit': locked('just_kit', '1.0.0'),
            'just_core': locked('just_core', '1.0.0', direct: false),
            'just_shared': locked('just_shared', '1.0.0', direct: false),
            'just_other': locked('just_other', '1.0.0'),
          },
        ),
        manifests: {
          'just_kit': manifest(
            'just_kit',
            deps: {'just_core': '^1.0.0', 'just_shared': '^1.0.0'},
          ),
          'just_other': manifest('just_other', deps: {'just_shared': '^1.0.0'}),
        },
      );
      final plan = Planner(catalog, state).uninstall('just_kit');
      expect(plan.canApply, isTrue);
      expect(plan.changes.map((c) => '${c.id} ${c.reason}'), [
        'just_kit You asked',
        'just_core No longer needed',
      ]);
    });

    test(
      'is refused while others need it, for system items, and while code imports it',
      () async {
        final catalog = await catalogOf(const []);
        final state = ProjectState(
          lock: StoreLock(
            items: {
              'just_core': locked('just_core', '1.0.0'),
              'just_user': locked('just_user', '1.0.0'),
              'just_editor': locked('just_editor', '0.1.0', system: true),
            },
          ),
          manifests: {
            'just_user': manifest('just_user', deps: {'just_core': '^1.0.0'}),
          },
        );
        final planner = Planner(catalog, state);
        expect(
          blockers(planner.uninstall('just_core')).single,
          contains('just_user needs just_core'),
        );
        expect(
          blockers(planner.uninstall('just_editor')).single,
          contains('part of the editor'),
        );
        expect(
          blockers(planner.uninstall('nope')).single,
          contains('not installed'),
        );
        final refs = planner.uninstall(
          'just_user',
          references: const [
            PackageReference(
              'lib/main_editor.dart',
              4,
              ReferenceKind.code,
              "import 'package:just_user/editor.dart';",
            ),
            PackageReference(
              'assets/scenes/a.scene.json',
              9,
              ReferenceKind.asset,
              '"packages/just_user/a.png"',
            ),
          ],
        );
        expect(blockers(refs).single, contains('lib/main_editor.dart:4'));
        expect(
          refs.issues
              .where((i) => i.level == IssueLevel.warning)
              .single
              .message,
          contains('assets/scenes/a.scene.json'),
        );
      },
    );
  });

  test(
    'two sources listing one id: the first wins, the clash is reported',
    () async {
      final a = buildCatalog(tempDir('a'), [
        TestItem('just_art_knight', versions: ['1.0.0']),
      ], sourceId: 'a');
      final b = buildCatalog(tempDir('b'), [
        TestItem('just_art_knight', versions: ['9.0.0']),
      ], sourceId: 'b');
      final catalog = StoreCatalog([
        ('a', a, (await a.fetchIndex()).index),
        ('b', b, (await b.fetchIndex()).index),
      ]);
      expect(
        '${catalog.entry('just_art_knight')!.item.latest!.version}',
        '1.0.0',
      );
      expect(catalog.clashes.single, contains('the store uses a'));
    },
  );

  test('ProjectState reads a real project', () async {
    final dir = tempDir('state');
    final project = StoreProject(dir.path);
    writeFiles(dir, {
      'pubspec.yaml': pubspecOf('app'),
      'pubspec_overrides.yaml':
          'dependency_overrides:\n  just_core:\n    path: ../dev/just_core\n',
      'plugins/kits/just_kit/just_store.json': jsonEncode(
        manifest('just_kit', deps: {'just_core': '^1.0.0'}).toJson(),
      ),
      'packages/characters/someone_elses/pubspec.yaml': pubspecOf(
        'someone_elses',
      ),
      'plugins/editors/their_tool/pubspec.yaml': pubspecOf('their_tool'),
    });
    project.writeLock(
      StoreLock(items: {'just_kit': locked('just_kit', '1.0.0')}),
    );
    final state = ProjectState.read(
      project,
      await OverridesTarget.detect(project),
    );
    expect(state.manifests.keys, ['just_kit']);
    expect(state.dependenciesOf('just_kit').keys, ['just_core']);
    expect(state.foreignOverrides.keys, ['just_core']);
    // Both roots: content's and the plugins'.
    expect(state.existingFolders, {
      'plugins/kits/just_kit',
      'packages/characters/someone_elses',
      'plugins/editors/their_tool',
    });
    expect('${state.installedVersion('just_kit')}', '1.0.0');
    expect(File('${dir.path}/just_store.lock.json').existsSync(), isTrue);
  });

  group('updates', () {
    /// A catalog of [items], its JSON changed by [edit] first: versions
    /// yanked, items withdrawn.
    Future<StoreCatalog> edited(
      List<TestItem> items,
      void Function(Map<String, Map<String, Object?>> items) edit,
    ) async {
      final dir = tempDir('cat');
      final source = buildCatalog(dir, items);
      final file = File('${dir.path}/index.json');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      edit({
        for (final i in json['items'] as List)
          (i as Map<String, Object?>)['id'] as String: i,
      });
      file.writeAsStringSync(jsonEncode(json));
      return StoreCatalog([
        ('test', source, (await source.fetchIndex()).index),
      ]);
    }

    ProjectState installed(Map<String, String> versions) => ProjectState(
      lock: StoreLock(
        items: {
          for (final e in versions.entries)
            e.key: locked(e.key, e.value, category: 'characters'),
        },
      ),
    );

    void yank(Map<String, Object?> item, String version) {
      for (final v in item['versions'] as List) {
        if ((v as Map)['version'] == version) v['yanked'] = true;
      }
    }

    test('never go back to an older version', () async {
      // 1.1.0 was withdrawn after this project installed it.
      final catalog = await edited([
        TestItem('k', versions: ['1.0.0', '1.1.0']),
      ], (items) => yank(items['k']!, '1.1.0'));
      final planner = Planner(catalog, installed({'k': '1.1.0'}));
      for (final plan in [planner.update('k'), planner.updateAll()]) {
        expect(plan.changes, isEmpty, reason: '${plan.issues}');
        expect(plan.blockers, isEmpty);
      }
      expect(planner.update('k').issues.single.level, IssueLevel.info);

      // A pre-release installed: a lower release is not an update, a newer
      // pre-release is.
      final pre = await catalogOf([
        TestItem('p', versions: ['1.5.0', '2.0.0-beta.2']),
      ]);
      final update = Planner(pre, installed({'p': '2.0.0-beta.1'})).update('p');
      expect('${update.changes.single.version!.version}', '2.0.0-beta.2');
      final none = await catalogOf([
        TestItem('p', versions: ['1.5.0']),
      ]);
      expect(
        Planner(none, installed({'p': '2.0.0-beta.1'})).update('p').changes,
        isEmpty,
      );
    });

    test('of something not installed are refused', () async {
      final catalog = await catalogOf([TestItem('k')]);
      final plan = Planner(
        catalog,
        ProjectState(lock: StoreLock()),
      ).update('k');
      expect(plan.changes, isEmpty);
      expect(blockers(plan).single, contains('not installed'));
    });

    test('of everything skip what is no longer offered', () async {
      final catalog = await edited(
        [
          TestItem('good', versions: ['1.0.0', '1.1.0']),
          TestItem('gone', versions: ['1.0.0', '1.1.0']),
          TestItem('pulled', versions: ['1.0.0']),
        ],
        (items) {
          items['gone']!['unavailable'] = true;
          yank(items['pulled']!, '1.0.0');
        },
      );
      final plan = Planner(
        catalog,
        installed({'good': '1.0.0', 'gone': '1.0.0', 'pulled': '1.0.0'}),
      ).updateAll();
      expect(plan.canApply, isTrue, reason: '${plan.issues}');
      expect(plan.changes.map((c) => '${c.id} ${c.version!.version}'), [
        'good 1.1.0',
      ]);
      expect(
        plan.issues.map((i) => i.message),
        contains(contains('no longer offered')),
      );
    });
  });

  group('resolving', () {
    TestItem kit(
      String id,
      List<String> versions, [
      Map<String, String>? deps,
    ]) => TestItem(
      id,
      kind: ItemKind.kit,
      category: 'kits',
      versions: versions,
      dependencies: deps ?? const {},
    );

    test("an update forgets what the versions it replaces needed", () async {
      // d 1.0.0 → a ^1 → b ^1 installed; d 2.0.0 → a ^2 → b ^2 offered.
      final dir = tempDir('cat');
      final source = buildCatalog(dir, [
        kit('a', ['1.0.0', '2.0.0']),
        kit('b', ['1.0.0', '2.0.0']),
        kit('d', ['1.0.0', '2.0.0']),
      ]);
      final file = File('${dir.path}/index.json');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      for (final item in (json['items'] as List).cast<Map<String, Object?>>()) {
        for (final v
            in (item['versions'] as List).cast<Map<String, Object?>>()) {
          final major = (v['version'] as String).split('.').first;
          v['dependencies'] = switch (item['id']) {
            'd' => {'a': '^$major.0.0'},
            'a' => {'b': '^$major.0.0'},
            _ => <String, String>{},
          };
        }
      }
      file.writeAsStringSync(jsonEncode(json));
      final catalog = StoreCatalog([
        ('test', source, (await source.fetchIndex()).index),
      ]);
      final state = ProjectState(
        lock: StoreLock(
          items: {
            'd': locked('d', '1.0.0'),
            'a': locked('a', '1.0.0', direct: false),
            'b': locked('b', '1.0.0', direct: false),
          },
        ),
        manifests: {
          'd': manifest('d', deps: {'a': '^1.0.0'}),
          'a': manifest('a', deps: {'b': '^1.0.0'}),
        },
      );
      final plan = Planner(catalog, state).updateAll();
      expect(plan.canApply, isTrue, reason: '${plan.issues}');
      expect(plan.changes.map((c) => '${c.id} ${c.version!.version}'), [
        'a 2.0.0',
        'b 2.0.0',
        'd 2.0.0',
      ]);
    });

    test('goes back on a choice that leads nowhere', () async {
      // t needs x and z; x 2.0.0 needs y ^2, but z needs x below 2.0.0.
      final dir = tempDir('cat');
      final source = buildCatalog(dir, [
        kit('t', ['1.0.0'], {'x': 'any', 'z': 'any'}),
        kit('x', ['1.0.0', '2.0.0']),
        kit('y', ['1.0.0', '2.0.0']),
        kit('z', ['1.0.0'], {'x': '<2.0.0'}),
      ]);
      final file = File('${dir.path}/index.json');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      for (final item in (json['items'] as List).cast<Map<String, Object?>>()) {
        if (item['id'] != 'x') continue;
        for (final v
            in (item['versions'] as List).cast<Map<String, Object?>>()) {
          final major = (v['version'] as String).split('.').first;
          v['dependencies'] = {'y': '^$major.0.0'};
        }
      }
      file.writeAsStringSync(jsonEncode(json));
      final catalog = StoreCatalog([
        ('test', source, (await source.fetchIndex()).index),
      ]);
      final plan = Planner(
        catalog,
        ProjectState(lock: StoreLock()),
      ).install('t');
      expect(plan.canApply, isTrue, reason: '${plan.issues}');
      expect(plan.changes.map((c) => '${c.id} ${c.version!.version}'), [
        't 1.0.0',
        'x 1.0.0',
        'y 1.0.0',
        'z 1.0.0',
      ]);
    });

    test(
      'a version the project can run before a newer one it cannot',
      () async {
        final dir = tempDir('cat');
        final source = buildCatalog(dir, [
          kit('k', ['1.0.0', '2.0.0']),
        ]);
        final file = File('${dir.path}/index.json');
        final json =
            jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        final versions =
            ((json['items'] as List).single as Map)['versions'] as List;
        (versions.last as Map)['requires'] = {'just_game_engine': '^3.0.0'};
        file.writeAsStringSync(jsonEncode(json));
        final plan = Planner(
          StoreCatalog([('test', source, (await source.fetchIndex()).index)]),
          ProjectState(
            lock: StoreLock(),
            environment: {'just_game_engine': Version.parse('2.0.0')},
          ),
        ).install('k');
        expect('${plan.changes.single.version!.version}', '1.0.0');
        expect(plan.canApply, isTrue);
      },
    );

    test(
      'installing a dependency on purpose keeps it when the other goes',
      () async {
        final catalog = await catalogOf([
          TestItem('art'),
          kit('kit', ['1.0.0'], {'art': '^1.0.0'}),
        ]);
        final state = ProjectState(
          lock: StoreLock(
            items: {
              'kit': locked('kit', '1.0.0'),
              'art': locked(
                'art',
                '1.0.0',
                direct: false,
                category: 'characters',
              ),
            },
          ),
          manifests: {
            'kit': manifest('kit', deps: {'art': '^1.0.0'}),
          },
        );
        final plan = Planner(catalog, state).install('art');
        expect(plan.canApply, isTrue);
        final change = plan.changes.single;
        expect(change.kind, ChangeKind.adopt);
        expect(change.reason, contains('it was there for Kit'));
        expect(plan.downloadBytes, 0);
        expect(plan.needsRestart, isFalse);
      },
    );
  });

  test('items that need each other go together', () async {
    final catalog = await catalogOf(const []);
    final state = ProjectState(
      lock: StoreLock(
        items: {
          'a': locked('a', '1.0.0'),
          'b': locked('b', '1.0.0', direct: false),
        },
      ),
      manifests: {
        'a': manifest('a', deps: {'b': '^1.0.0'}),
        'b': manifest('b', deps: {'a': '^1.0.0'}),
      },
    );
    final plan = Planner(catalog, state).uninstall('a');
    expect(plan.canApply, isTrue, reason: '${plan.issues}');
    expect(plan.changes.map((c) => c.id), ['a', 'b']);
  });

  test('only the official catalog, or one on this machine, vouches', () async {
    final index = StoreIndex(
      source: const StoreSourceInfo('elsewhere', 'Elsewhere'),
      categories: const [StoreCategory('kits', 'Kits')],
      items: [
        StoreItem(
          id: 'their_kit',
          name: 'Their Kit',
          kind: ItemKind.kit,
          category: 'kits',
          versions: [StoreItemVersion(version: Version(1, 0, 0))],
          trust: TrustLevel.official,
        ),
      ],
    );
    TrustLevel trustFrom(String base) => StoreCatalog([
      ('x', MemoryStoreSource(index, const {}, base: base), index),
    ]).entry('their_kit')!.item.trust;
    expect(trustFrom('https://catalog.example.com/'), TrustLevel.community);
    expect(trustFrom('memory:/'), TrustLevel.official);
    expect(trustFrom('file:///C:/catalog/'), TrustLevel.official);
    expect(
      trustFrom('file://server/share/catalog/'),
      TrustLevel.community,
      reason: 'another machine\'s share is not this machine',
    );
    expect(
      trustFrom(
        SourceConfig.official.url.substring(
          0,
          SourceConfig.official.url.length - 'index.json'.length,
        ),
      ),
      TrustLevel.official,
    );
  });

  test('a version its catalog took down is named in every plan', () async {
    final dir = tempDir('cat');
    final source = buildCatalog(dir, [
      TestItem('k', versions: ['1.0.0', '1.1.0']),
      TestItem('other'),
    ]);
    final file = File('${dir.path}/index.json');
    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final k = (json['items'] as List).cast<Map<String, Object?>>().first;
    ((k['versions'] as List).first as Map)['blocked'] = true;
    file.writeAsStringSync(jsonEncode(json));
    final planner = Planner(
      StoreCatalog([('test', source, (await source.fetchIndex()).index)]),
      ProjectState(
        lock: StoreLock(
          items: {'k': locked('k', '1.0.0', category: 'characters')},
        ),
      ),
    );
    expect(
      planner.install('other').issues.map((i) => i.message),
      contains(contains('was taken down')),
    );
    final update = planner.update('k');
    expect('${update.changes.single.version!.version}', '1.1.0');
    expect(
      update.issues.map((i) => i.message),
      isNot(contains(contains('was taken down'))),
      reason: 'the update replaces it',
    );
  });

  test('an item the store removed is named in every plan, as its source '
      'or a vouching catalog says', () async {
    StoreIndex removing(String sourceId) => StoreIndex.checked(
      source: StoreSourceInfo(sourceId, sourceId),
      categories: const [],
      items: const [],
      removed: const [RemovedItem('k', 'It held malware.')],
    );
    final source = buildCatalog(tempDir('cat'), [TestItem('other')]);
    final listing = (await source.fetchIndex()).index;
    final state = ProjectState(
      lock: StoreLock(
        items: {
          'k': LockedItem(
            version: '1.0.0',
            kind: ItemKind.content,
            origin: ItemOrigin.vendored,
            category: 'characters',
            path: 'packages/characters/k',
            source: 'studio',
          ),
        },
      ),
    );
    final web = MemoryStoreSource(
      removing('stranger'),
      const {},
      base: 'https://stranger.example.com/',
    );
    // Another web catalog can't take down what it didn't provide…
    var catalog = StoreCatalog([
      ('test', source, listing),
      ('stranger', web, web.index),
    ]);
    expect(catalog.removal('k', source: 'studio'), isNull);
    expect(
      Planner(catalog, state).install('other').issues.map((i) => i.message),
      isNot(contains(contains('taken down'))),
    );
    // …but the catalog it came from can.
    final studio = MemoryStoreSource(
      removing('studio'),
      const {},
      base: 'https://studio.example.com/',
    );
    catalog = StoreCatalog([
      ('test', source, listing),
      ('studio', studio, studio.index),
    ]);
    expect(catalog.removal('k', source: 'studio')?.reason, 'It held malware.');
    expect(
      Planner(catalog, state).install('other').issues.map((i) => i.message),
      contains('k was taken down by the store: It held malware. Uninstall it.'),
    );
    // A catalog on this machine (or the official one) vouches for all.
    final local = MemoryStoreSource(removing('local'), const {});
    catalog = StoreCatalog([('local', local, local.index)]);
    expect(catalog.removal('k', source: 'studio'), isNotNull);
  });

  test('uninstalling refuses to take a dependency your code imports', () async {
    final catalog = await catalogOf([
      TestItem('art'),
      TestItem(
        'kit',
        kind: ItemKind.kit,
        category: 'kits',
        dependencies: {'art': '^1.0.0'},
      ),
    ]);
    final state = ProjectState(
      lock: StoreLock(
        items: {
          'kit': locked('kit', '1.0.0'),
          'art': locked('art', '1.0.0', direct: false, category: 'characters'),
        },
      ),
      manifests: {
        'kit': manifest('kit', deps: {'art': '^1.0.0'}),
      },
    );
    final searched = <String, Set<String>>{};
    final plan = Planner(catalog, state).uninstall(
      'kit',
      referencesOf: (id, going) {
        searched[id] = going;
        return [
          if (id == 'art')
            const PackageReference(
              'lib/main.dart',
              1,
              ReferenceKind.code,
              "import 'package:art/art.dart';",
            ),
        ];
      },
    );
    expect(plan.changes.map((c) => c.id), ['kit', 'art']);
    expect(plan.canApply, isFalse);
    expect(blockers(plan).single, contains('lib/main.dart:1'));
    expect(searched['art'], {'kit', 'art'}, reason: 'their folders are going');
  });
}
