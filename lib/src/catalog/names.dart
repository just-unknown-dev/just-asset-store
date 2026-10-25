/// Item ids and category ids, checked by just_core_cli's [PackageNames],
/// which the store builds on.
library;

import 'package:just_core_cli/just_core_cli.dart' show PackageNames;

export 'package:just_core_cli/just_core_cli.dart' show PackageNames;

/// The store's name for [PackageNames]: item ids are package names.
typedef StoreNames = PackageNames;

/// Item ids only the store's own team may use.
///
/// The store installs an item as a package of the same name, and points
/// the whole project at its folder: an item named after a package the
/// game gets elsewhere would replace that package everywhere. So the
/// ecosystem's names (`just`, `just_…`) and the Flutter SDK's packages are
/// the store's own team's alone.
abstract final class ReservedNames {
  /// The ecosystem's prefix.
  static const String prefix = 'just_';

  /// The Flutter SDK's packages.
  static const Set<String> sdk = {
    'flutter',
    'flutter_driver',
    'flutter_goldens',
    'flutter_localizations',
    'flutter_test',
    'flutter_web_plugins',
    'fuchsia_remote_debug_protocol',
    'integration_test',
    'sky_engine',
  };

  /// Whether only an official item may be called [id].
  static bool isReserved(String id) =>
      id == 'just' || id.startsWith(prefix) || sdk.contains(id);
}
