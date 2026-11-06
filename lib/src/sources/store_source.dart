/// Where catalogs and archives come from: a web address or a folder.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_core_cli/fetch.dart';

import '../catalog/catalog_files.dart';
import '../catalog/item_traits.dart';
import '../catalog/just_release.dart';
import '../catalog/store_index.dart';
import '../catalog/store_item.dart';
import '../version.dart';

part 'folder_store_source.dart';
part 'github_source.dart';
part 'http_store_source.dart';
part 'memory_store_source.dart';

/// What the store sends to a download service to prove a user may download
/// a paid item. Reserved: v1 has none.
abstract interface class Credentials {
  /// The headers to send to [broker].
  Future<Map<String, String>> headersFor(Uri broker);
}

/// A catalog as last fetched, and whether it came from the cache because
/// the source was unreachable.
final class FetchedIndex {
  /// [index], [offline] when read from the cache after a network failure.
  const FetchedIndex(this.index, {this.offline = false, this.error});

  /// The catalog.
  final StoreIndex index;

  /// Whether this is the cached copy because fetching failed.
  final bool offline;

  /// Why fetching failed, when [offline].
  final Object? error;
}

/// The settings of one source: its address and the name it is shown with.
final class SourceConfig {
  /// The source at [url]: an `https:` address of its `index.json`, or a
  /// folder (or `index.json` file) on disk. [fromLockfile] when the
  /// project's lockfile names it, not the user on this machine.
  const SourceConfig(
    this.url, {
    this.name,
    this.enabled = true,
    this.fromLockfile = false,
  });

  /// The official catalog.
  static const SourceConfig official = SourceConfig(
    'https://asset.justunknown.com/index.json',
    name: 'Just Asset Store',
  );

  /// The id the [official] catalog gives itself (its `source.id`).
  static const String officialId = 'just';

  /// Where the catalog is.
  final String url;

  /// The name shown for it, until its catalog gives one.
  final String? name;

  /// Whether the store reads it.
  final bool enabled;

  /// Whether only the project's lockfile names it — a file shared with the
  /// project — rather than the user, in this run or in the editor's
  /// settings. A catalog in a folder vouches for its items
  /// ([StoreSource.vouches]) only when the user chose it. Never saved.
  final bool fromLockfile;

  /// Whether it is on the web rather than on disk.
  bool get isRemote => url.startsWith('https://') || url.startsWith('http://');

  /// This config as JSON.
  Map<String, Object?> toJson() => compactJson({
    'url': url,
    'name': name,
    'enabled': enabled ? null : false,
  });

  /// Reads one from [json].
  factory SourceConfig.fromJson(JsonFields json) => SourceConfig(
    json.string('url'),
    name: json.optString('name'),
    enabled: json.flag('enabled', fallback: true),
  );
}

/// A place the store reads a catalog and its files from.
abstract class StoreSource {
  /// The source for [config]: on the web or on disk. [cacheDir] keeps the
  /// web catalog for offline use.
  factory StoreSource.from(
    SourceConfig config, {
    String? cacheDir,
    HttpClient Function()? client,
  }) {
    final github = GitHubSource.tryFrom(
      config.url,
      cacheDir: cacheDir,
      client: client,
    );
    if (github != null) return github;
    if (config.isRemote) {
      return HttpStoreSource(
        Uri.parse(config.url),
        cacheDir: cacheDir,
        client: client,
      );
    }
    return FolderStoreSource(
      config.url,
      chosen: !config.fromLockfile,
      client: client,
    );
  }

  StoreSource._();

  /// The catalog's address.
  Uri get indexUri;

  /// Fetches the catalog. [refresh] asks the server again even when the
  /// cached copy would do.
  Future<FetchedIndex> fetchIndex({bool refresh = false});

  /// Reads the file at [uri] (from [resolve]).
  Future<Uint8List> readBytes(
    Uri uri, {
    ByteProgress? onProgress,
    CancelToken? cancel,
    int? maxBytes,
    Map<String, String> headers = const {},
  });

  /// [reference] (a URL, or a path relative to the catalog) as an address.
  Uri resolve(String reference) => indexUri.resolve(reference);

  /// Where to download [version] of [item] from.
  ///
  /// Paid items ([AccessLevel.entitled]) ask a download service with
  /// [credentials]; that arrives with paid items, so v1 refuses them.
  Future<Uri> resolveDownload(
    StoreItem item,
    StoreItemVersion version, {
    Credentials? credentials,
  }) async {
    if (version.access == AccessLevel.entitled) {
      throw FetchException(
        '${item.name} is a paid item. Paid items are not available in this '
        'version of the Asset Store yet.',
      );
    }
    final archive = version.archive;
    if (archive == null) {
      throw FetchException('${item.name} ${version.version} has no archive.');
    }
    final uri = resolve(archive.url);
    if ((uri.scheme == 'http' || uri.scheme == 'https') && !mayFetch(uri)) {
      throw FetchException(
        leadsInside(uri) || (uri.scheme == 'http' && isFetchAllowed(uri))
            ? '${item.name} ${version.version}: a catalog on the web points '
                  'its archive at this machine or its network, which the '
                  'store refuses.'
            : '${item.name} ${version.version}: its archive is not on '
                  'https, which the store needs for a download from the web.',
        uri: uri,
      );
    }
    return uri;
  }

  /// Whether this catalog may make the store fetch [target], one of its
  /// addresses or an address a server redirected a fetch to: `https:`, or
  /// plain `http:` to this machine only, and never `http:` for a catalog
  /// on `https:` ([isFetchAllowed]); and never from the web into this
  /// machine or its network ([leadsInside]).
  ///
  /// Every fetch a source makes passes it to just_core_cli's
  /// [HttpFetcher] as its redirect rule, so a server on the web can't send
  /// the store to a router or a cloud's metadata address either: it is
  /// asked about every redirect before anything is sent there. (It reads
  /// host names, not the addresses they resolve to.)
  bool mayFetch(Uri target) =>
      isFetchAllowed(target) &&
      !(target.scheme == 'http' && indexUri.scheme == 'https') &&
      !leadsInside(target);

  /// Whether this catalog may say how far the store vouches for its items
  /// ([StoreItem.trust]): the official catalog does; so does one made in
  /// memory, and one in a folder on this machine that the user chose
  /// ([FolderStoreSource.chosen]). Every other catalog's items are
  /// community items, whatever it claims.
  bool get vouches => '$indexUri' == SourceConfig.official.url;

  /// Whether [target], an address this catalog names, leads from the web
  /// to this machine or its private network: a catalog on the web must not
  /// make the store call the services there (a router, a cloud's metadata
  /// address). A catalog served from such an address — one being tried out
  /// on this machine — may name its neighbours.
  bool leadsInside(Uri target) {
    if (target.scheme != 'http' && target.scheme != 'https') return false;
    if (indexUri.scheme != 'http' && indexUri.scheme != 'https') return false;
    return isPrivateHost(target.host) && !isPrivateHost(indexUri.host);
  }

  /// Whether [host] is this machine or on a private network: `localhost`,
  /// loopback, private, shared and link-local addresses, `.local` and
  /// `.internal` names — and an address written as a bare number, which
  /// some systems read as an IPv4 address.
  static bool isPrivateHost(String host) {
    final h = host.toLowerCase();
    if (h.isEmpty ||
        h == 'localhost' ||
        h.endsWith('.localhost') ||
        h.endsWith('.local') ||
        h.endsWith('.internal')) {
      return true;
    }
    final ip = InternetAddress.tryParse(h);
    if (ip == null) {
      // `2130706433`, `0x7f.1`, `0177.0.0.1`: numbers, not names.
      return RegExp(
        r'^(0x[0-9a-f]+|[0-9]+)(\.(0x[0-9a-f]+|[0-9]+))*$',
      ).hasMatch(h);
    }
    if (ip.isLoopback || ip.isLinkLocal || ip.isMulticast) return true;
    final b = ip.rawAddress;
    if (ip.type == InternetAddressType.IPv4) {
      return b[0] == 0 ||
          b[0] == 10 ||
          (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && b[1] == 168);
    }
    // IPv6: unique local fc00::/7, and IPv4 inside IPv6 (::ffff:a.b.c.d).
    if ((b[0] & 0xfe) == 0xfc) return true;
    final mapped =
        b.sublist(0, 12).every((x) => x == 0) ||
        (b.sublist(0, 10).every((x) => x == 0) &&
            b[10] == 0xff &&
            b[11] == 0xff);
    return mapped && isPrivateHost(b.sublist(12).join('.'));
  }

  /// The largest `index.json` read: a catalog may list its items itself.
  static const int maxIndexBytes = 32 * 1024 * 1024;

  /// How many of a catalog's pieces are fetched at once.
  static const int piecesAtOnce = 6;

  /// The catalog [text] (the `index.json` at [file]) describes: one that
  /// lists its items itself, or a root whose pieces [piece] reads. Throws
  /// [JsonFormatException] naming the file at fault.
  static Future<StoreIndex> _catalogFrom(
    String text,
    Future<Uint8List> Function(CatalogPieceRef ref) piece, {
    required String file,
  }) async {
    final CatalogRoot root;
    try {
      final json = JsonFields.parse(text);
      if (!CatalogRoot.isSplit(json)) return StoreIndex.fromJson(json);
      root = CatalogRoot.fromJson(json);
    } on JsonFormatException catch (e) {
      throw e.inFile(file);
    }
    final pieces = await _inTurn(
      root.pieces,
      (ref) async =>
          CatalogPiece.read(await piece(ref), ref, buckets: root.buckets),
    );
    try {
      return root.assemble(pieces);
    } on JsonFormatException catch (e) {
      throw e.file == null ? e.inFile(file) : e;
    }
  }
}

/// [work] done for every one of [list], [StoreSource.piecesAtOnce] at a
/// time, the results in [list]'s order.
Future<List<R>> _inTurn<T, R>(List<T> list, Future<R> Function(T) work) async {
  final out = List<R?>.filled(list.length, null);
  var next = 0;
  Future<void> worker() async {
    while (next < list.length) {
      final i = next++;
      out[i] = await work(list[i]);
    }
  }

  await Future.wait([
    for (var w = 0; w < StoreSource.piecesAtOnce && w < list.length; w++)
      worker(),
  ]);
  return out.cast<R>();
}

String _utf8(Uint8List bytes) {
  try {
    return const Utf8Decoder().convert(bytes);
  } on FormatException {
    throw const JsonFormatException('The catalog is not UTF-8 text.');
  }
}
