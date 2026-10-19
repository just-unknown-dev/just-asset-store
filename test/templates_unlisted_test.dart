// Templates, unlisted installs from GitHub, takedowns, and reading catalogs
// from newer stores.

import 'dart:convert';
import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:just_core_cli/just_core_cli.dart';
import 'package:test/test.dart';

import 'support/temp_project.dart';
import 'support/test_catalog.dart';

Future<(int, String, String)> store(List<String> args, {String? cwd}) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final code = await runJustPlugin(
    ['store', ...args],
    [StoreCommand()],
    context: JustContext(
      workingDirectory: cwd ?? Directory.current.path,
      out: out,
      err: err,
      readLine: () => 'y',
      interactive: true,
      environment: const {},
    ),
  );
  return (code, '$out', '$err');
}

void main() {
  group('a catalog from a newer store', () {
    test('an item of a kind this version does not know is left out', () {
      final index = StoreIndex.parse(
        jsonEncode({
          'schema': 1,
          'source': {'id': 's', 'name': 'S'},
          'categories': [
            {'id': 'characters', 'label': 'C'},
          ],
          'items': [
            {
              'id': 'from_the_future',
              'name': 'F',
              'kind': 'hologram',
              'category': 'characters',
              'versions': [
                {'version': '1.0.0'},
              ],
            },
            {
              'id': 'just_art',
              'name': 'A',
              'kind': 'content',
              'category': 'characters',
              'versions': [
                {
                  'version': '1.0.0',
                  'archive': {
                    'url': 'a.zip',
                    'sha256': '0' * 64,
                    'size': 1,
                  },
                },
              ],
            },
          ],
        }),
      );
      expect(index.items.map((i) => i.id), ['just_art']);
      expect(index.skipped, ['from_the_future']);
    });
  });

  group('the planner', () {
    test('refuses to install a template, saying how to use it', () async {
      final source = buildCatalog(tempDir('catalog'), [
        TestItem('starter_game', kind: ItemKind.template),
      ]);
      final project = tempDir('proj');
      writeFiles(project, {'pubspec.yaml': pubspecOf('app')});
      final (code, out, _) = await store([
        'install',
        'starter_game',
        '--project',
        project.path,
        '--source',
        source.indexUri.toFilePath(),
      ]);
      expect(code, 1);
      expect(out, contains('just create <folder> --template starter_game'));
    });

    test('refuses an item the store stopped offering', () async {
      final dir = tempDir('catalog');
      final source = buildCatalog(dir, [TestItem('just_art_knight')]);
      final index = jsonDecode(File('${dir.path}/index.json').readAsStringSync())
          as Map<String, dynamic>;
      ((index['items'] as List).single as Map)['unavailable'] = true;
      File('${dir.path}/index.json').writeAsStringSync(jsonEncode(index));
      final project = tempDir('proj');
      writeFiles(project, {'pubspec.yaml': pubspecOf('app')});
      final (code, out, _) = await store([
        'install',
        'just_art_knight',
        '--project',
        project.path,
        '--source',
        source.indexUri.toFilePath(),
      ]);
      expect(code, 1);
      expect(out, contains('no longer offered'));
    });
  });

  group('templates', () {
    test("lay their files over the project, filled in for it", () async {
      final source = buildCatalog(tempDir('catalog'), [
        TestItem(
          'starter_game',
          kind: ItemKind.template,
          files: {
            'template/lib/main.dart': "// {{title}}\nclass {{App}} {}\n",
            'template/assets/scenes/scenes.json': '{"scenes": ["intro"]}',
          },
        ),
      ]);
      final project = tempDir('proj');
      writeFiles(project, {
        'pubspec.yaml': pubspecOf('rocket_run'),
        'just.json': '{"title": "Rocket Run"}',
        'lib/main.dart': '// the empty game',
      });
      final args = [
        'template',
        'starter_game',
        '--project',
        project.path,
        '--source',
        source.indexUri.toFilePath(),
      ];
      var (code, out, err) = await store(args);
      expect(code, 1, reason: 'lib/main.dart is the project\'s own');
      expect(err, contains('--overwrite'));
      (code, out, err) = await store([...args, '--overwrite']);
      expect(code, 0, reason: err);
      expect(
        File('${project.path}/lib/main.dart').readAsStringSync(),
        '// Rocket Run\nclass RocketRunApp {}\n',
      );
      expect(
        File('${project.path}/assets/scenes/scenes.json').readAsStringSync(),
        '{"scenes": ["intro"]}',
      );
    });
  });

  group('unlisted packages from GitHub', () {
    test('a URL names the repository and, after @, the release', () {
      final latest = GitHubSource.tryFrom('https://github.com/studio/fancy-kit')!;
      expect('${latest.repo}', 'studio/fancy-kit');
      expect(
        '${latest.indexUri}',
        'https://github.com/studio/fancy-kit/releases/latest/download/just_release.json',
      );
      final tagged = GitHubSource.tryFrom('github.com/studio/fancy-kit@v1.2.0')!;
      expect(tagged.tag, 'v1.2.0');
      final again = GitHubSource.tryFrom('${tagged.indexUri}')!;
      expect(again.tag, 'v1.2.0');
      expect(GitHubSource.tryFrom('https://example.com/a/b'), isNull);
      expect(GitHubSource.tryFrom('just_art_knight'), isNull);
    });

    test('a release becomes one community item pinned to its tag', () {
      final manifest = ItemManifest.parse(
        jsonEncode({
          'schema': 1,
          'id': 'fancy_kit',
          'name': 'Fancy Kit',
          'version': '1.2.0',
          'kind': 'kit',
          'category': 'kits',
        }),
      );
      final release = JustRelease.parse(
        JustRelease(
          tag: 'v1.2.0',
          manifest: manifest,
          version: {
            'version': '1.2.0',
            'archive': {
              'url': 'fancy_kit-1.2.0.zip',
              'sha256': 'a' * 64,
              'size': 10,
            },
          },
        ).toText(),
      );
      final index = GitHubSource.tryFrom(
        'https://github.com/studio/fancy-kit',
      )!.indexFor(release);
      final item = index.items.single;
      expect(item.trust, TrustLevel.community);
      expect(index.source.id, 'github:studio/fancy-kit');
      expect(
        item.versions.single.archive!.url,
        'https://github.com/studio/fancy-kit/releases/download/v1.2.0/fancy_kit-1.2.0.zip',
        reason: 'never latest/download: the lockfile must restore these bytes',
      );
    });

    test('pack writes the release file beside the archive', () async {
      final pkg = tempDir('pkg');
      packageFiles(TestItem('just_art_knight'), '1.0.0').forEach((path, bytes) {
        File('${pkg.path}/$path')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(bytes);
      });
      final outDir = tempDir('dist');
      final (code, _, err) = await store(['pack', pkg.path, '-o', outDir.path]);
      expect(code, 0, reason: err);
      final release = JustRelease.parse(
        File('${outDir.path}/just_release.json').readAsStringSync(),
      );
      expect(release.tag, 'v1.0.0');
      expect(release.manifest.id, 'just_art_knight');
      expect(
        (release.version['archive'] as Map)['url'],
        'just_art_knight-1.0.0.zip',
      );
    });
  });
}
