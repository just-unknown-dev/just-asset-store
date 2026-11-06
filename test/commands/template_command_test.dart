// `just store template`: laying a project template over a project.

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import '../support/run_store.dart';
import '../support/temp_project.dart';
import '../support/test_catalog.dart';

void main() {
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

  test('a template whose items cannot install changes nothing', () async {
    final source = buildCatalog(tempDir('catalog'), [
      TestItem(
        'starter_game',
        kind: ItemKind.template,
        dependencies: {'just_gone': '^1.0.0'},
        files: {'template/lib/main.dart': '// {{title}}\n'},
      ),
    ]);
    final project = tempDir('proj');
    writeFiles(project, {'pubspec.yaml': pubspecOf('rocket_run')});
    final (code, out, _) = await store([
      'template',
      'starter_game',
      '--project',
      project.path,
      '--source',
      source.indexUri.toFilePath(),
    ]);
    expect(code, 1);
    expect(out, contains('"just_gone" (needed by you) is not in any'));
    expect(File('${project.path}/lib/main.dart').existsSync(), isFalse);
  });

  group('templates may not write', () {
    for (final path in [
      '.git/hooks/pre-commit',
      '.dart_tool/just_core_cli/txn/1/journal.json',
      '.just_changes/txn/1/journal.json',
      'packages/x/.Dart_Tool/y.json',
      'just_store.lock.json',
      'just.json',
      'pubspec_overrides.yaml',
      '.flutter-plugins-dependencies',
      '.Just_Trash/just/1/x.json',
      '.editor_trash/store/1/x.json',
    ]) {
      test(path, () async {
        final source = buildCatalog(tempDir('catalog'), [
          TestItem(
            'starter_game',
            kind: ItemKind.template,
            files: {
              'template/lib/main.dart': '// {{title}}\n',
              'template/$path': '{}',
            },
          ),
        ]);
        final project = tempDir('proj');
        writeFiles(project, {'pubspec.yaml': pubspecOf('rocket_run')});
        final (code, _, err) = await store([
          'template',
          'starter_game',
          '--overwrite',
          '--project',
          project.path,
          '--source',
          source.indexUri.toFilePath(),
        ]);
        expect(code, 1);
        expect(err, contains(path));
        expect(
          File('${project.path}/lib/main.dart').existsSync(),
          isFalse,
          reason: 'nothing was changed',
        );
      });
    }
  });

  test("a title with a quote is escaped where it goes", () async {
    final source = buildCatalog(tempDir('catalog'), [
      TestItem(
        'starter_game',
        kind: ItemKind.template,
        files: {
          'template/lib/main.dart': "const title = '{{title.dart}}';\n",
          'template/assets/game.json': '{"title": "{{title.json}}"}\n',
          'template/README.md': '# {{title}}\n',
        },
      ),
    ]);
    final project = tempDir('proj');
    writeFiles(project, {
      'pubspec.yaml': pubspecOf('bobs_game'),
      'just.json': jsonEncode({'title': 'Bob\'s "Best" Game'}),
    });
    final (code, _, err) = await store([
      'template',
      'starter_game',
      '--project',
      project.path,
      '--source',
      source.indexUri.toFilePath(),
    ]);
    expect(code, 0, reason: err);
    expect(
      File('${project.path}/lib/main.dart').readAsStringSync(),
      "const title = 'Bob\\'s \"Best\" Game';\n",
    );
    expect(
      jsonDecode(File('${project.path}/assets/game.json').readAsStringSync()),
      {'title': 'Bob\'s "Best" Game'},
    );
    expect(
      File('${project.path}/README.md').readAsStringSync(),
      '# Bob\'s "Best" Game\n',
    );
  });
}
