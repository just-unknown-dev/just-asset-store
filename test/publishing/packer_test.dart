// Packing a package folder into the archive a catalog pins.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import '../support/package_folder.dart';
import '../support/temp_project.dart';
import '../support/test_catalog.dart';

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
        throwsA(isA<JsonFormatException>()),
      );
    });

    test('lists the native code its packages bring, which it must declare', () {
      // their_tool → nice_lib (pub.dev) → camera_x, a Flutter plugin, and
      // path_x, with build hooks, which every project has already through
      // engine_core, the store item it needs.
      final pubCache = tempDir('cache');
      writeFiles(pubCache, {
        'nice_lib/pubspec.yaml': 'name: nice_lib\nversion: 1.0.0\n',
        'engine_core/pubspec.yaml': 'name: engine_core\nversion: 1.0.0\n',
        'path_x/pubspec.yaml': 'name: path_x\nversion: 1.0.0\n',
        'path_x/hook/build.dart': 'void main(List<String> args) {}\n',
        'camera_x/pubspec.yaml':
            'name: camera_x\nversion: 1.0.0\nflutter:\n  plugin:\n'
            '    platforms:\n      android:\n        package: x\n',
      });
      Map<String, String> resolved(String tool) => {
        '.dart_tool/package_config.json': jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': tool, 'rootUri': '../', 'packageUri': 'lib/'},
            for (final p in ['nice_lib', 'camera_x', 'engine_core', 'path_x'])
              {
                'name': p,
                'rootUri': Directory('${pubCache.path}/$p').uri.toString(),
                'packageUri': 'lib/',
              },
          ],
        }),
        '.dart_tool/package_graph.json': jsonEncode({
          'roots': [tool],
          'packages': [
            {
              'name': tool,
              'version': '1.0.0',
              'dependencies': ['nice_lib', 'engine_core'],
            },
            {
              'name': 'nice_lib',
              'version': '1.0.0',
              'dependencies': ['camera_x', 'path_x'],
            },
            {
              'name': 'engine_core',
              'version': '1.0.0',
              'dependencies': ['path_x'],
            },
            {'name': 'camera_x', 'version': '1.0.0', 'dependencies': []},
            {'name': 'path_x', 'version': '1.0.0', 'dependencies': []},
          ],
        }),
      };
      TestItem tool({List<String> permissions = const []}) => TestItem(
        'their_tool',
        kind: ItemKind.editorExtension,
        category: 'editors',
        pubDependencies: {'nice_lib': '^1.0.0'},
        dependencies: {'engine_core': '^1.0.0'},
        permissions: permissions,
      );

      expect(
        () => Packer.pack(packageFolder(tool(), extra: resolved('their_tool'))),
        throwsA(
          isA<PackageCheckException>().having(
            (e) => e.problems.join('\n'),
            'problems',
            contains('It brings native code (camera_x)'),
          ),
        ),
      );
      final r = Packer.pack(
        packageFolder(
          tool(permissions: ['native']),
          extra: resolved('their_tool'),
        ),
      );
      expect(r.nativePlugins, ['camera_x']);
      final json = r.versionJson('https://e.com/t.zip');
      expect(json['nativePlugins'], ['camera_x']);
      expect(json['permissions'], ['native']);

      // Not resolved: it can't look, and says so.
      final unresolved = Packer.pack(
        packageFolder(tool(permissions: ['native'])),
      );
      expect(unresolved.nativePlugins, isEmpty);
      expect(unresolved.warnings.join('\n'), contains('Run pub get in it'));
    });
  });
}
