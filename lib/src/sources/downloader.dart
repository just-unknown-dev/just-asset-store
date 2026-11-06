/// Downloading archives and pictures, checked and cached.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:just_core_cli/fetch.dart';
import 'package:just_core_cli/project.dart';

import '../catalog/store_item.dart';
import 'store_source.dart';

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
  /// [FetchException] when they can't be fetched, and
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
    if (pin.size > StoreArchive.maxSize) {
      throw DownloadException(
        '${item.name} ${version.version} is ${_mib(pin.size)}; the store '
        'downloads archives of up to ${_mib(StoreArchive.maxSize)}.',
      );
    }
    final cache = this.cache;
    // Reading and hashing a large archive takes seconds: on another
    // isolate, never the caller's (the editor's window keeps drawing).
    final cached = cache == null
        ? null
        : await Isolate.run(() => cache.archive(pin.sha256));
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
    final what = '${item.name} ${version.version}';
    await Isolate.run(() {
      checkPinned(bytes, size: pin.size, sha256: pin.sha256, what: what);
      cache?.putArchive(pin.sha256, bytes);
    });
    return bytes;
  }

  static String _mib(int bytes) => '${(bytes / (1 << 20)).ceil()} MiB';

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
    // A picture is fetched as soon as its card shows: from the web only
    // over https, and never from this machine's network for a catalog on
    // the web (a catalog tried out on this machine may use plain http) —
    // nor any redirect there ([StoreSource.mayFetch]).
    if (!source.mayFetch(uri)) return null;
    final c = cache;
    if (c == null) return null;
    final file = _thumbnailFile(c, uri);
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

/// Where the picture at [uri] is cached in [cache] (just_core_cli 0.1.2's
/// `DownloadCache.thumbnailFile`, unchanged).
File _thumbnailFile(DownloadCache cache, Uri uri) {
  final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? 'img' : name.substring(dot + 1).toLowerCase();
  final safeExt = RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext) ? ext : 'img';
  return File(
    '${cache.dir}/thumbnails/${Sha256.hexOf('$uri'.codeUnits).substring(0, 32)}.$safeExt',
  );
}
