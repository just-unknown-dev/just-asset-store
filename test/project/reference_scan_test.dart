// What in a project still uses a package.
@TestOn('vm')
library;

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import '../support/temp_project.dart';

void main() {
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
        'plugins/kits/just_kit/assets/self.json':
            '{"a": "packages/just_kit/b.json"}\n',
      });
      final refs = ReferenceScan.find(
        StoreProject(dir.path),
        [
          const ReferenceTarget('just_kit', componentTypes: ['KitComponent']),
        ],
        alsoSearch: ['packages/characters/user_pack', 'plugins/kits/just_kit'],
        excluding: ['plugins/kits/just_kit'],
      )['just_kit']!;
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

    test('reads the tests, tools and examples too, not only lib/', () {
      final dir = tempDir('refs');
      writeFiles(dir, {
        'test/input_editor_module_test.dart':
            "import 'package:just_input_editor/just_input_editor.dart';\n",
        'integration_test/app_test.dart':
            "import 'package:just_input_editor/editor.dart';\n",
        'tool/make_maps.dart':
            "export 'package:just_input_editor/just_input_editor.dart';\n",
        'example/main.dart': "import 'package:just_input_editor/x.dart';\n",
        'lib/editor/store_modules.g.dart':
            "import 'package:just_input_editor/just_input_editor.dart' as s0;\n",
        'build/tmp/x.dart': "import 'package:just_input_editor/x.dart';\n",
      });
      final refs = ReferenceScan.find(StoreProject(dir.path), [
        const ReferenceTarget('just_input_editor'),
      ])['just_input_editor']!;
      expect(
        {for (final r in refs) '${r.kind.name} ${r.file}'},
        {
          'code test/input_editor_module_test.dart',
          'code integration_test/app_test.dart',
          'code tool/make_maps.dart',
          'code example/main.dart',
        },
      );
    });

    test('one pass finds every package it is asked about', () {
      final dir = tempDir('refs');
      writeFiles(dir, {
        'lib/main.dart':
            "import 'package:just_kit/kit.dart';\n"
            "import 'package:just_art/art.dart';\n",
        'assets/scenes/a.scene.json': '{"a": "packages/just_art/hero.png"}\n',
      });
      final refs = ReferenceScan.find(StoreProject(dir.path), [
        const ReferenceTarget('just_kit'),
        const ReferenceTarget('just_art'),
        const ReferenceTarget('just_other'),
      ]);
      expect(refs.keys, {'just_kit', 'just_art', 'just_other'});
      expect([for (final r in refs['just_kit']!) r.file], ['lib/main.dart']);
      expect(
        {for (final r in refs['just_art']!) '${r.kind.name} ${r.file}'},
        {'code lib/main.dart', 'asset assets/scenes/a.scene.json'},
      );
      expect(refs['just_other'], isEmpty);
    });
  });
}
