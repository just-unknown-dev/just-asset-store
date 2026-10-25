/// The part of `package:just_asset_store/just_asset_store.dart` that works
/// on a project on disk — files, downloads, processes: the store itself, its
/// sources, the planner and installer, the creator tools and the
/// `just store` commands. The library exports it everywhere but the web
/// (Windows, macOS, Linux, Android, iOS: where `dart:io` is); on the web —
/// where `dart.library.js_interop` is, with JavaScript or WebAssembly — it
/// exports `web.dart` instead.
library;

export 'asset_store.dart';
export 'commands/creator_commands.dart';
export 'commands/store_command.dart' hide absoluteIn;
export 'commands/template_command.dart';
export 'install/installer.dart';
export 'install/item_source.dart';
export 'install/linker.dart';
export 'install/planner.dart';
export 'install/restore.dart';
export 'project/overrides_target.dart';
export 'project/package_info.dart';
export 'project/pub_runner.dart';
export 'project/reference_scan.dart';
export 'project/registry.dart';
export 'project/store_paths.dart';
export 'project/store_project.dart';
export 'sources/downloader.dart';
export 'sources/store_source.dart';
export 'tools/catalog_builder.dart';
export 'tools/native_scan.dart';
export 'tools/packer.dart';
