/// A project on disk as the store sees it: its lockfile and generated files,
/// what uses an installed item, an item folder's hashes — and the
/// just_core_cli names for pub and atomic writes.
library;

export 'package:just_core_cli/project.dart'
    show
        FlutterSdk,
        GraphNode,
        OverridesTarget,
        PackageConfig,
        PackageGraph,
        ProcessPubRunner,
        PubResult,
        PubRunner,
        ResolvedPackage,
        SdkLocator,
        retryOnLock,
        writeBytesAtomic,
        writeTextAtomic;

export 'folder_hashes.dart';
export 'local_edits.dart';
export 'reference_scan.dart';
export 'store_paths.dart';
export 'store_project.dart';
export 'store_registry.dart';
