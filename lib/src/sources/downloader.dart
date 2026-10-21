/// Downloading archives and pictures, checked and cached.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:just_core_cli/fetch.dart';

import '../catalog/store_index.dart';
import '../project/store_project.dart';
import 'store_source.dart';

export 'package:just_core_cli/fetch.dart' show DownloadCache, DownloadException;

/// Fetches archives and thumbnails through a [DownloadCache].
final class Downloader {
  /// A downloader keeping what it fetches in [cache] (none: always fetch).
  Downloader({this.cache});

  /// Where downloads are kept.
  final DownloadCache? cache;

  /// The archive of [version] of [item], from the cache or [source],
  /// checked against the size and SHA-256 the catalog pinned.
  ///
  /// Throws [DownloadException] when the bytes don't match,
  /// [SourceException] when they can't be fetched, and
  /// [CancelledException].
  Future<Uint8List> archive(
    StoreSource source,
    StoreItem item,
    StoreItemVersion version, {
    ByteProgress? onProgress,
    CancelToken? cancel,
    Credentials? credentials,
  }) async {
    final pin = version.archive;
    if (pin == null) {
      throw DownloadException(
        '${item.name} ${version.version} has no archive.',
      );
    }
    final cached = cache?.archive(pin.sha256);
    if (cached != null) {
      onProgress?.call(cached.length, cached.length);
      return cached;
    }
    final uri = await source.resolveDownload(
      item,
      version,
      credentials: credentials,
    );
    final bytes = await source.readBytes(
      uri,
      onProgress: onProgress,
      cancel: cancel,
      maxBytes: pin.size,
    );
    checkPinned(
      bytes,
      size: pin.size,
      sha256: pin.sha256,
      what: '${item.name} ${version.version}',
    );
    cache?.putArchive(pin.sha256, bytes);
    return bytes;
  }

  /// The picture at [reference] (relative to [source]'s catalog), as a
  /// cached file; null when it can't be fetched. Only a catalog in a folder
  /// on this machine has pictures on disk: never one on the web, and never
  /// on another machine's share.
  Future<File?> thumbnail(StoreSource source, String reference) async {
    final uri = source.resolve(reference);
    if (uri.scheme == 'file') {
      if (source.indexUri.scheme != 'file' || uri.host.isNotEmpty) return null;
      final file = File.fromUri(uri);
      return file.existsSync() ? file : null;
    }
    final c = cache;
    if (c == null) return null;
    final file = c.thumbnailFile(uri);
    if (file.existsSync()) return file;
    try {
      final bytes = await source.readBytes(uri, maxBytes: 4 * 1024 * 1024);
      writeBytesAtomic(file, bytes);
      return file;
    } on Object {
      return null;
    }
  }
}
