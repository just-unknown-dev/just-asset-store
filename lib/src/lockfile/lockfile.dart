/// A project's `just_store.lock.json`, the file hashes it records, the text
/// of the registries the store generates, and the store's block in a
/// pubspec — with just_core_cli's pubspec editor. Web-safe.
library;

export 'package:just_core_cli/just_core_cli.dart'
    show
        DependencySpec,
        HostedDependency,
        ManagedBlock,
        OtherDependency,
        PathDependency,
        PubspecEditException,
        PubspecEditor;

export 'file_hashes.dart';
export 'store_block.dart';
export 'store_codegen.dart';
export 'store_lock.dart';
