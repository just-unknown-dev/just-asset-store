// That Dart compiles and runs the generated registry files, against
// stand-ins for the editor and the engine.
@TestOn('vm')
library;

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import 'support/codegen_items.dart';
import 'support/temp_project.dart';

void main() {
  test('Dart compiles and runs what is generated', () async {
    // Stand-ins for the editor, the engine and three items, so plain Dart
    // can check the generated files without Flutter.
    final dir = tempDir('codegen');
    writeFiles(dir, {
      'pubspec.yaml': pubspecOf(
        'app',
        extra:
            'dependencies:\n'
            '  just_game_engine_editor: {path: stubs/just_game_engine_editor}\n'
            '  just_game_engine: {path: stubs/just_game_engine}\n'
            '  just_platformer_kit: {path: stubs/just_platformer_kit}\n'
            '  just_sprite_editor: {path: stubs/just_sprite_editor}\n'
            '  just_ui_editor: {path: stubs/just_ui_editor}\n',
      ),
      'stubs/just_game_engine_editor/pubspec.yaml': pubspecOf(
        'just_game_engine_editor',
      ),
      'stubs/just_game_engine_editor/lib/just_game_engine_editor.dart':
          'abstract class EditorModule { String get id; }\n',
      'stubs/just_game_engine/pubspec.yaml': pubspecOf('just_game_engine'),
      'stubs/just_game_engine/lib/just_game_engine.dart':
          'abstract interface class ContextExtension { String get id; }\n',
      'stubs/just_platformer_kit/pubspec.yaml': pubspecOf(
        'just_platformer_kit',
        extra:
            'dependencies:\n'
            '  just_game_engine_editor: {path: ../just_game_engine_editor}\n'
            '  just_game_engine: {path: ../just_game_engine}\n',
      ),
      'stubs/just_platformer_kit/lib/editor.dart':
          "import 'package:just_game_engine_editor/just_game_engine_editor.dart';\n"
          "class PlatformerModule extends EditorModule { @override String get id => 'platformer'; }\n",
      'stubs/just_platformer_kit/lib/just_platformer_kit.dart':
          "import 'package:just_game_engine/just_game_engine.dart';\n"
          'abstract final class PlatformerKit { static const ContextExtension extension = _Ext(); }\n'
          "class _Ext implements ContextExtension { const _Ext(); @override String get id => 'platformer'; }\n",
      'stubs/just_sprite_editor/pubspec.yaml': pubspecOf(
        'just_sprite_editor',
        extra:
            'dependencies:\n  just_game_engine_editor: {path: ../just_game_engine_editor}\n',
      ),
      'stubs/just_sprite_editor/lib/editor.dart':
          "import 'package:just_game_engine_editor/just_game_engine_editor.dart';\n"
          "class SpriteStudioModule extends EditorModule { @override String get id => 'sprites'; }\n"
          "class AnimatorModule extends EditorModule { @override String get id => 'animator'; }\n",
      'stubs/just_ui_editor/pubspec.yaml': pubspecOf(
        'just_ui_editor',
        extra:
            'dependencies:\n'
            '  just_game_engine_editor: {path: ../just_game_engine_editor}\n'
            '  just_game_engine: {path: ../just_game_engine}\n',
      ),
      'stubs/just_ui_editor/lib/editor.dart':
          "import 'package:just_game_engine_editor/just_game_engine_editor.dart';\n"
          "class UiEditorModule extends EditorModule { @override String get id => 'ui'; }\n",
      'stubs/just_ui_editor/lib/just_ui_editor.dart':
          "import 'package:just_game_engine/just_game_engine.dart';\n"
          'abstract final class JustGameUi { static const ContextExtension extension = _Ext(); }\n'
          "class _Ext implements ContextExtension { const _Ext(); @override String get id => 'ui'; }\n",
      StoreProject.modulesFile: StoreCodegen.modules([kit(), sprites(), ui()]),
      StoreProject.extensionsFile: StoreCodegen.extensions([
        kit(),
        sprites(),
        ui(),
      ]),
      'bin/main.dart':
          "import '../lib/editor/store_modules.g.dart';\n"
          "import '../lib/game/store_extensions.g.dart';\n"
          'void main() {\n'
          "  print(storeModules().map((m) => m.id).join(','));\n"
          "  print(storeExtensions.map((e) => e.id).join(','));\n"
          '}\n',
    });
    final get = await runDart(['pub', 'get', '--offline'], dir);
    expect(get.exitCode, 0, reason: '${get.stdout}${get.stderr}');
    final run = await runDart(['run', 'bin/main.dart'], dir);
    expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
    expect((run.stdout as String).trim().split(RegExp(r'\r?\n')), [
      'platformer,animator,sprites,ui',
      'platformer,ui',
    ]);
  });
}
