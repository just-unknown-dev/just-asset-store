// Three installed items' manifests, for the generated registry files.
import 'package:just_asset_store/just_asset_store.dart';

ItemManifest kit() => ItemManifest(
  id: 'just_platformer_kit',
  name: 'Platformer Kit',
  version: Version(0, 1, 0),
  kind: ItemKind.kit,
  category: 'kits',
  modules: const [
    ModuleEntry(
      'package:just_platformer_kit/editor.dart',
      'PlatformerModule',
      order: 10,
    ),
  ],
  extensions: const [
    ExtensionEntry(
      'package:just_platformer_kit/just_platformer_kit.dart',
      'PlatformerKit.extension',
      order: 10,
    ),
  ],
);

ItemManifest sprites() => ItemManifest(
  id: 'just_sprite_editor',
  name: 'Sprite Studio',
  version: Version(0, 1, 0),
  kind: ItemKind.editorExtension,
  category: 'editors',
  modules: const [
    ModuleEntry(
      'package:just_sprite_editor/editor.dart',
      'SpriteStudioModule',
      order: 20,
    ),
    ModuleEntry(
      'package:just_sprite_editor/editor.dart',
      'AnimatorModule',
      order: 20,
    ),
  ],
);

ItemManifest ui() => ItemManifest(
  id: 'just_ui_editor',
  name: 'Interface',
  version: Version(0, 1, 0),
  kind: ItemKind.kit,
  category: 'kits',
  modules: const [
    ModuleEntry(
      'package:just_ui_editor/editor.dart',
      'UiEditorModule',
      order: 40,
    ),
  ],
  extensions: const [
    ExtensionEntry(
      'package:just_ui_editor/just_ui_editor.dart',
      'JustGameUi.extension',
      order: 20,
    ),
  ],
);
