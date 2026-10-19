/// The store's block in a project's pubspecs, and the pubspec editor it
/// uses — just_core_cli's, which the store builds on. Re-exported here so
/// the store's own imports, and the editor's, stay as they were.
library;

import 'package:just_core_cli/project.dart';

export 'package:just_core_cli/project.dart'
    show
        DependencySpec,
        PathDependency,
        HostedDependency,
        OtherDependency,
        PubspecEditException,
        PubspecEditor,
        ManagedBlock;

/// The Asset Store's block in `pubspec.yaml` and `pubspec_overrides.yaml`:
/// the entries it installs, between the markers projects already hold.
///
/// ```yaml
/// dependency_overrides:
///   # >>> just_asset_store managed (edit in the Asset Store) >>>
///   just_art_knight:
///     path: packages/characters/just_art_knight
///   # <<< just_asset_store managed <<<
/// ```
///
/// Every [PubspecEditor] the store opens edits this block, and no other.
const ManagedBlock storeBlock = ManagedBlock(
  'just_asset_store',
  hint: 'edit in the Asset Store',
);
