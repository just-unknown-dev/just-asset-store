// `just store` end to end: a creator packs, a catalog builds, a project
// installs, lists, checks and uninstalls — with real `dart pub get`.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:just_core_cli/just_core_cli.dart';
import 'package:test/test.dart';

import 'support/temp_project.dart';
import 'support/test_catalog.dart';

/// Runs `just store <args>` as `just` would run the plugin, answering
/// [answer] to any question.
Future<(int, String, String)> store(
  List<String> args, {
  String? cwd,
  String answer = 'y',
}) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final context = JustContext(
    workingDirectory: cwd ?? Directory.current.path,
    out: out,
    err: err,
    readLine: () => answer,
    interactive: true,
    environment: const {},
  );
  final code = await runJustPlugin(
    ['store', ...args],
    [StoreCommand()],
    context: context,
  );
  return (code, '$out', '$err');
}

void main() {
  test('usage', () async {
    final (code, _, err) = await store([]);
    expect(code, 2);
    expect(err, contains('Usage: just store <subcommand>'));
    expect((await store(['--help'])).$1, 0);
    expect(
      (await store(['frobnicate'], cwd: tempDir('x').path)).$1,
      2,
      reason: 'an unknown command is bad usage, project or not',
    );
    final (noId, _, idErr) = await store(['install', '--project', '.']);
    expect(noId, 2, reason: 'checked before any catalog is read');
    expect(idErr, contains('install needs an item id'));
  });

  test('outside a project, it says so', () async {
    final (code, _, err) = await store(['list'], cwd: tempDir('none').path);
    expect(code, 1);
    expect(err, contains('No pubspec.yaml'));
  });

  group('in a project', () {
    test('adding a source keeps the official catalog', () async {
      final project = tempDir('proj');
      writeFiles(project, {'pubspec.yaml': pubspecOf('app')});
      final source = buildCatalog(tempDir('catalog'), [TestItem('k')]);
      final (code, _, err) = await store([
        'sources',
        'add',
        source.indexUri.toFilePath(),
        '--project',
        project.path,
      ]);
      expect(code, 0, reason: err);
      expect(StoreProject(project.path).readLock().sources.map((s) => s.id), [
        'just',
        'test',
      ]);
    });

    test('relative folders are read from where you are', () async {
      final here = tempDir('here');
      writeFiles(here, {
        'checkout/just_tool/pubspec.yaml': pubspecOf('just_tool'),
        'checkout/just_tool/just_store.json': jsonEncode({
          'schema': 1,
          'id': 'just_tool',
          'name': 'Tool',
          'version': '1.0.0',
          'kind': 'editor-extension',
          'category': 'editors',
        }),
      });
      final project = tempDir('proj');
      writeFiles(project, {'pubspec.yaml': pubspecOf('app')});
      final (code, _, err) = await store([
        'link',
        'checkout/just_tool',
        '--project',
        project.path,
      ], cwd: here.path);
      expect(code, 0, reason: err);
      final linked = StoreProject(project.path).readLock().items['just_tool']!;
      expect(
        Directory(
          '${project.path}/${linked.path}',
        ).resolveSymbolicLinksSync().replaceAll(r'\', '/'),
        Directory(
          '${here.path}/checkout/just_tool',
        ).resolveSymbolicLinksSync().replaceAll(r'\', '/'),
      );
    });

    test('a project that never used the store passes the check', () async {
      final project = tempDir('proj');
      writeFiles(project, {'pubspec.yaml': pubspecOf('app')});
      final (code, _, err) = await store([
        'generate',
        '--check',
        '--project',
        project.path,
      ]);
      expect(code, 0, reason: err);
    });
  });

  group('pack and validate', () {
    Directory packageFolder({Map<String, List<int>> extra = const {}}) {
      final pkg = tempDir('pkg');
      ({
        ...packageFiles(TestItem('just_art_knight'), '1.0.0'),
        ...extra,
      }).forEach((path, bytes) {
        File('${pkg.path}/$path')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(bytes);
      });
      return pkg;
    }

    test('list what a refused package must fix, and exit 1', () async {
      final pkg = packageFolder(
        extra: {
          'sprites/run.exe': [0],
        },
      );
      for (final args in [
        ['pack', pkg.path, '-o', tempDir('out').path],
        ['validate', pkg.path],
      ]) {
        final (code, _, err) = await store(args);
        expect(code, 1, reason: args.first);
        expect(err, contains('"sprites/run.exe" is a .exe file'));
        expect(err, isNot(contains('Unexpected error')));
      }
    });

    test('an output folder inside the package is left out of it', () async {
      final pkg = packageFolder();
      for (var run = 0; run < 2; run++) {
        final (code, _, err) = await store([
          'pack',
          pkg.path,
          '-o',
          '${pkg.path}/dist',
        ]);
        expect(code, 0, reason: 'run $run: $err');
      }
    });

    test('without --url, the placeholder names the release tag', () async {
      final out = tempDir('out');
      final (code, _, err) = await store([
        'pack',
        packageFolder().path,
        '-o',
        out.path,
        '--json',
      ]);
      expect(code, 0, reason: err);
      final version =
          jsonDecode(
                File(
                  '${out.path}/just_art_knight-1.0.0.json',
                ).readAsStringSync(),
              )
              as Map;
      expect(
        (version['archive'] as Map)['url'],
        'https://github.com/OWNER/REPO/releases/download/v1.0.0/'
        'just_art_knight-1.0.0.zip',
      );
      final release =
          jsonDecode(
                File('${out.path}/${JustRelease.fileName}').readAsStringSync(),
              )
              as Map;
      expect(release['tag'], 'v1.0.0');
    });
  });

  test(
    'pack, index build, install, list, generate --check, uninstall',
    () async {
      final sdk = SdkLocator.locate('../..');
      if (sdk == null) return; // needs a Flutter SDK for pub get

      // A creator's package folder.
      final pkg = tempDir('pkg');
      packageFiles(TestItem('just_art_knight'), '1.0.0').forEach((path, bytes) {
        File('${pkg.path}/$path')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(bytes);
      });

      // A catalog repository, its archive hosted beside the built site.
      final repo = tempDir('repo');
      final site = Directory('${repo.path}/site');
      var (code, out, err) = await store([
        'pack',
        pkg.path,
        '-o',
        site.path,
        '--url',
        '.',
      ]);
      expect(code, 0, reason: err);
      expect(out, contains('sha256 '));
      final version =
          jsonDecode(
                File(
                  '${site.path}/just_art_knight-1.0.0.json',
                ).readAsStringSync(),
              )
              as Map;
      expect((version['archive'] as Map)['url'], './just_art_knight-1.0.0.zip');
      writeFiles(repo, {
        'catalog.json': jsonEncode({
          'source': {'id': 'test', 'name': 'Test'},
          'categories': [
            {'id': 'characters', 'label': 'Characters'},
          ],
        }),
        'publishers/just.json': jsonEncode({
          'id': 'just',
          'name': 'Just',
          'trust': 'official',
        }),
        'items/just_art_knight/item.json': jsonEncode({
          'id': 'just_art_knight',
          'name': 'Knight',
          'kind': 'content',
          'category': 'characters',
        }),
        'items/just_art_knight/versions/1.0.0.json': jsonEncode({
          ...version,
          'archive': {
            ...(version['archive'] as Map),
            'url': 'just_art_knight-1.0.0.zip',
          },
        }),
      });
      (code, out, err) = await store([
        'index',
        'build',
        repo.path,
        '-o',
        site.path,
      ]);
      expect(code, 0, reason: err);
      (code, out, err) = await store([
        'validate',
        '${site.path}/just_art_knight-1.0.0.zip',
      ]);
      expect(code, 0, reason: err);
      expect(out, contains('would install'));

      // A project installs it.
      // A game project, which has its generated files (empty) already.
      final project = tempDir('proj');
      writeFiles(project, {
        'pubspec.yaml': pubspecOf('app'),
        StoreProject.modulesFile: StoreCodegen.modules(const []),
        StoreProject.extensionsFile: StoreCodegen.extensions(const []),
      });
      final common = [
        '--project',
        project.path,
        '--sdk',
        sdk.root,
        '--cache',
        tempDir('cache').path,
      ];
      (code, out, err) = await store([
        'install',
        'just_art_knight',
        '--source',
        site.path,
        ...common,
      ]);
      expect(code, 0, reason: '$out\n$err');
      expect(out, contains('+ install   just_art_knight 1.0.0'));
      expect(out, contains('Done.'));
      expect(
        File(
          '${project.path}/.dart_tool/package_config.json',
        ).readAsStringSync(),
        contains('just_art_knight'),
      );

      (code, out, err) = await store(['list', ...common]);
      expect(out, contains('just_art_knight 1.0.0  (content, vendored)'));
      (code, out, err) = await store(['list', '--json', ...common]);
      final doc = jsonDecode(out) as Map;
      expect(doc['ok'], isTrue);
      expect((doc['result'] as Map).keys, ['just_art_knight']);
      (code, out, err) = await store(['generate', '--check', ...common]);
      expect(code, 0, reason: err);
      File(
        '${project.path}/${StoreProject.modulesFile}',
      ).writeAsStringSync('// edited');
      (code, out, err) = await store(['generate', '--check', ...common]);
      expect(code, 1);
      expect(err, contains('store_modules.g.dart'));
      (code, out, err) = await store(['generate', ...common]);
      expect(code, 0);

      // Saying no leaves it be; the lockfile remembers the source.
      (code, out, err) = await store([
        'uninstall',
        'just_art_knight',
        ...common,
      ], answer: 'n');
      expect(code, 1);
      expect(
        Directory(
          '${project.path}/packages/characters/just_art_knight',
        ).existsSync(),
        isTrue,
      );
      (code, out, err) = await store([
        'uninstall',
        'just_art_knight',
        '-y',
        ...common,
      ]);
      expect(code, 0, reason: err);
      expect(
        Directory(
          '${project.path}/packages/characters/just_art_knight',
        ).existsSync(),
        isFalse,
      );
      expect(
        File('${project.path}/pubspec.yaml').readAsStringSync(),
        pubspecOf('app'),
      );
    },
  );

  test('a blocked plan exits 1 and says why', () async {
    final source = buildCatalog(tempDir('catalog'), [
      TestItem('just_art_paid', access: 'entitled'),
    ]);
    final project = tempDir('proj');
    writeFiles(project, {'pubspec.yaml': pubspecOf('app')});
    final (code, out, _) = await store([
      'install',
      'just_art_paid',
      '--project',
      project.path,
      '--source',
      source.indexUri.toFilePath(),
    ]);
    expect(code, 1);
    expect(out, contains('x Just Art Paid is a paid item'));
  });

  test('index codeowners and check', () async {
    final repo = tempDir('repo');
    writeFiles(repo, {
      'catalog.json': jsonEncode({
        'source': {'id': 's', 'name': 'S'},
        'categories': [
          {'id': 'characters', 'label': 'C'},
        ],
        'maintainers': ['boss'],
      }),
      'publishers/just.json': jsonEncode({
        'id': 'just',
        'name': 'Just',
        'github': ['me'],
      }),
    });
    var (code, out, _) = await store(['index', 'codeowners', repo.path]);
    expect(out, contains('/publishers/ @boss'));
    // Written as UTF-8 by the tool itself, whatever the shell would do.
    final owners = '${repo.path}/.github/CODEOWNERS';
    (code, out, _) = await store([
      'index',
      'codeowners',
      repo.path,
      '--file',
      owners,
    ]);
    expect(code, 0);
    expect(File(owners).readAsStringSync(), contains('/publishers/ @boss'));
    (code, _, _) = await store(['index', 'check', repo.path, '--only', 'x']);
    expect(code, 2, reason: '--only goes with --download');
    (code, out, _) = await store(['index', 'check', repo.path]);
    expect(code, 0);
    expect(out, contains('0 items build'));
  });
}
