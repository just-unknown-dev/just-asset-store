/// The core of the Just Asset Store: catalogs, downloads, verification, and
/// installing items into a project as packages.
///
/// Every store item is a Dart package. Content (art, sound, tilesets) is an
/// asset-only package; editor extensions and kits are code. Installed items
/// live in `packages/{category}/{name}/`, so their assets load as
/// `packages/<name>/...` — the same key in the editor and in the game.
///
/// Pure Dart: the editor's store window (just_asset_store_editor), the
/// `store` command-line tool and a catalog's CI all use this same code.
library;

export 'src/archive/safe_paths.dart';
export 'src/archive/zip_reader.dart';
export 'src/archive/zip_writer.dart';
export 'src/catalog/item_manifest.dart';
export 'src/catalog/json.dart';
export 'src/catalog/names.dart';
export 'src/catalog/semver.dart';
export 'src/catalog/store_index.dart';
export 'src/crypto/sha256.dart';
export 'src/project/pubspec_editor.dart';
export 'src/project/codegen.dart';
export 'src/project/lockfile.dart';
export 'src/project/overrides_target.dart';
export 'src/project/package_info.dart';
export 'src/project/pub_runner.dart';
export 'src/project/reference_scan.dart';
export 'src/project/store_project.dart';
export 'src/install/package_check.dart';
export 'src/install/planner.dart';
export 'src/sources/downloader.dart';
export 'src/sources/store_source.dart';
export 'src/install/installer.dart';
export 'src/project/registry.dart';
export 'src/asset_store.dart';
export 'src/install/restore.dart';
export 'src/tools/catalog_builder.dart';
export 'src/tools/packer.dart';
export 'src/commands/creator_commands.dart';
export 'src/commands/store_command.dart';
export 'src/commands/template_command.dart';
export 'src/project/store_paths.dart';
export 'src/install/linker.dart';
