/// Moved to `package:just_core_cli`, which the store now builds on. Re-exported
/// here so the store's own imports, and the editor's, stay as they were.
library;

import 'package:just_core_cli/project.dart' show PackageNames;

export 'package:just_core_cli/project.dart' show PackageNames;

/// The store's name for [PackageNames]: item ids are package names.
typedef StoreNames = PackageNames;
