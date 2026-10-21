/// Item ids and category ids, checked by just_core_cli's [PackageNames],
/// which the store builds on.
library;

import 'package:just_core_cli/just_core_cli.dart' show PackageNames;

export 'package:just_core_cli/just_core_cli.dart' show PackageNames;

/// The store's name for [PackageNames]: item ids are package names.
typedef StoreNames = PackageNames;
