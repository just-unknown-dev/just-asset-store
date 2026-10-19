/// Where the store keeps per-user files on this machine.
library;

import 'package:just_core_cli/project.dart' show UserPaths;

/// Per-user folders shared by the editor and the `just` tool, so a version
/// downloaded once installs anywhere.
abstract final class StorePaths {
  /// The download cache: `%LOCALAPPDATA%\just_asset_store` on Windows,
  /// `~/Library/Caches/just_asset_store` on macOS,
  /// `$XDG_CACHE_HOME/just_asset_store` (or `~/.cache/…`) elsewhere. Null
  /// when the home folder can't be found.
  static String? defaultCacheDir({Map<String, String>? environment}) =>
      UserPaths.cacheDir('just_asset_store', environment: environment);
}
