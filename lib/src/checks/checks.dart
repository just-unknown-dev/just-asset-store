/// The rules a package must pass before it may enter a project, run on its
/// archive in memory — and just_core_cli's ZIP reader and writer and path
/// rules they use. Web-safe.
library;

export 'package:just_core_cli/just_core_cli.dart'
    show
        SafePaths,
        UnsafePathException,
        ZipArchive,
        ZipDirectory,
        ZipEntry,
        ZipFormatException,
        ZipLimits,
        ZipNeedsBytes,
        ZipWriter;

export 'package_check.dart';
