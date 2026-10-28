/// Where catalogs and archives come from: a web address or a folder.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_core_cli/fetch.dart';

import '../catalog/catalog_files.dart';
import '../catalog/claim.dart';
import '../catalog/item_manifest.dart';
import '../catalog/json.dart';
import '../catalog/store_index.dart';
import '../crypto/sha256.dart';
import '../version.dart';

export 'package:just_core_cli/fetch.dart'
    show ByteProgress, CancelToken, CancelledException, FetchException;

/// What the store sends to a download service to prove a user may download
/// a paid item. Reserved: v1 has none.
abstract interface class Credentials {
  /// The headers to send to [broker].
  Future<Map<String, String>> headersFor(Uri broker);
}

/// A download or catalog that could not be fetched: the store's name for
/// just_core_cli's [FetchException].
typedef SourceException = FetchException;

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
  /// folder (or `index.json` file) on disk.
  const SourceConfig(this.url, {this.name, this.enabled = true});

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
    return FolderStoreSource(config.url);
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
      throw SourceException(
        '${item.name} is a paid item. Paid items are not available in this '
        'version of the Asset Store yet.',
      );
    }
    final archive = version.archive;
    if (archive == null) {
      throw SourceException('${item.name} ${version.version} has no archive.');
    }
    final uri = resolve(archive.url);
    // Plain http is only ever fetched from this machine: a catalog on the
    // web must not make the store call this machine's own services.
    if ((uri.scheme == 'http' && indexUri.scheme == 'https') ||
        leadsInside(uri)) {
      throw SourceException(
        '${item.name} ${version.version}: a catalog on the web points its '
        'archive at this machine or its network, which the store refuses.',
        uri: uri,
      );
    }
    return uri;
  }

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
      return RegExp(r'^(0x[0-9a-f]+|[0-9]+)(\.(0x[0-9a-f]+|[0-9]+))*$').hasMatch(h);
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
    final mapped = b.sublist(0, 12).every((x) => x == 0) ||
        (b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff);
    return mapped && isPrivateHost(b.sublist(12).join('.'));
  }

  /// The largest `index.json` read: a catalog may list its items itself.
  static const int maxIndexBytes = 32 * 1024 * 1024;

  /// How many of a catalog's pieces are fetched at once.
  static const int piecesAtOnce = 6;

  /// The catalog [text] (the `index.json` at [file]) describes: one that
  /// lists its items itself, or a root whose pieces [piece] reads. Throws
  /// [StoreFormatException] naming the file at fault.
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
    } on StoreFormatException catch (e) {
      throw e.inFile(file);
    }
    final pieces = await _inTurn(
      root.pieces,
      (ref) async =>
          CatalogPiece.read(await piece(ref), ref, buckets: root.buckets),
    );
    try {
      return root.assemble(pieces);
    } on StoreFormatException catch (e) {
      throw e.file == null ? e.inFile(file) : e;
    }
  }
}

/// [work] done for every one of [list], [StoreSource.piecesAtOnce] at a
/// time, the results in [list]'s order.
Future<List<R>> _inTurn<T, R>(
  List<T> list,
  Future<R> Function(T) work,
) async {
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

/// A catalog held in memory: an index and its archives' bytes — what
/// `just store vendor` installs from, and tests.
final class MemoryStoreSource extends StoreSource {
  /// [index], with [files] (path relative to it → bytes).
  MemoryStoreSource(this.index, this.files, {String base = 'memory:/'})
    : indexUri = Uri.parse('${base}index.json'),
      super._();

  /// The catalog.
  final StoreIndex index;

  /// The files beside it, by relative path.
  final Map<String, Uint8List> files;

  @override
  final Uri indexUri;

  @override
  Future<FetchedIndex> fetchIndex({bool refresh = false}) async =>
      FetchedIndex(index);

  @override
  Future<Uint8List> readBytes(
    Uri uri, {
    ByteProgress? onProgress,
    CancelToken? cancel,
    int? maxBytes,
    Map<String, String> headers = const {},
  }) async {
    cancel?.check();
    final base = '$indexUri'.substring(
      0,
      '$indexUri'.length - 'index.json'.length,
    );
    final key = '$uri'.startsWith(base)
        ? '$uri'.substring(base.length)
        : '$uri';
    final bytes = files[key];
    if (bytes == null) throw SourceException('The file is missing.', uri: uri);
    onProgress?.call(bytes.length, bytes.length);
    return bytes;
  }
}

/// A catalog in a folder on disk (a studio's shared drive, a test).
final class FolderStoreSource extends StoreSource {
  /// The catalog at [location]: a folder holding `index.json`, the file
  /// itself, or a `file:` URL to either.
  FolderStoreSource(String location) : super._() {
    var path = location.startsWith('file:')
        ? Uri.parse(location).toFilePath()
        : location;
    path = path.replaceAll(r'\', '/');
    final file = path.endsWith('.json') ? File(path) : File('$path/index.json');
    indexUri = file.absolute.uri;
  }

  @override
  late final Uri indexUri;

  @override
  Future<FetchedIndex> fetchIndex({bool refresh = false}) async {
    final file = File.fromUri(indexUri);
    if (!file.existsSync()) {
      throw SourceException('There is no catalog here.', uri: indexUri);
    }
    final String text;
    try {
      text = _utf8(await file.readAsBytes());
    } on StoreFormatException catch (e) {
      throw e.inFile(file.path);
    }
    return FetchedIndex(
      await StoreSource._catalogFrom(text, _readPiece, file: file.path),
    );
  }

  Future<Uint8List> _readPiece(CatalogPieceRef ref) async {
    final uri = resolve(ref.path);
    final piece = File.fromUri(uri);
    if (!piece.existsSync()) {
      throw SourceException('A piece of the catalog is missing.', uri: uri);
    }
    if (piece.lengthSync() != ref.size) {
      throw StoreFormatException(
        'It is not the piece index.json names (its size differs).',
        file: piece.path,
      );
    }
    return piece.readAsBytes();
  }

  @override
  Future<Uint8List> readBytes(
    Uri uri, {
    ByteProgress? onProgress,
    CancelToken? cancel,
    int? maxBytes,
    Map<String, String> headers = const {},
  }) async {
    cancel?.check();
    // A catalog built locally (to preview it before it is published) points
    // at archives on GitHub Releases: fetch those as a web catalog would.
    if (uri.scheme == 'https' || uri.scheme == 'http') {
      return HttpStoreSource(uri).readBytes(
        uri,
        onProgress: onProgress,
        cancel: cancel,
        maxBytes: maxBytes,
        headers: headers,
      );
    }
    if (uri.scheme != 'file') {
      throw SourceException(
        'A folder catalog can only point to files beside it, or on the web.',
        uri: uri,
      );
    }
    final file = File.fromUri(uri);
    if (!file.existsSync()) {
      throw SourceException('The file is missing.', uri: uri);
    }
    final length = file.lengthSync();
    if (maxBytes != null && length > maxBytes) {
      throw SourceException(
        'The file is larger than the catalog says.',
        uri: uri,
      );
    }
    final bytes = await file.readAsBytes();
    onProgress?.call(bytes.length, bytes.length);
    return bytes;
  }
}

/// A catalog on the web, cached on disk so the store still opens offline.
///
/// It sends `If-None-Match` with the cached copy's ETag, so an unchanged
/// catalog costs one small request; retries politely when the server asks
/// it to slow down (429/503); and only talks plain `http:` to this machine.
final class HttpStoreSource extends StoreSource {
  /// The catalog at [indexUri], cached in [cacheDir].
  HttpStoreSource(this.indexUri, {this.cacheDir, HttpClient Function()? client})
    : _fetcher = HttpFetcher(userAgent: userAgent, client: client),
      super._() {
    if (!isFetchAllowed(indexUri)) {
      throw SourceException(
        'Catalogs on the web must use https.',
        uri: indexUri,
      );
    }
  }

  @override
  final Uri indexUri;

  /// Where the catalog and its ETag are cached.
  final String? cacheDir;

  final HttpFetcher _fetcher;

  /// What the store tells servers it is.
  static const String userAgent =
      'just_asset_store/$justAssetStoreVersion '
      '(+https://github.com/just-unknown-dev/just-asset-store)';

  /// Reads the catalog: `index.json` (an unchanged one costs one small
  /// request), then — for a catalog in pieces — only the pieces not cached
  /// yet, a few at a time. A catalog that can't be read whole never
  /// replaces the last good one; offline, that one is read from the cache.
  @override
  Future<FetchedIndex> fetchIndex({bool refresh = false}) =>
      _fetchIndex(refresh: refresh, retried: false);

  Future<FetchedIndex> _fetchIndex({
    required bool refresh,
    required bool retried,
  }) async {
    final pieces = _pieceCache();
    StoreIndex? fresh;
    Set<String>? freshPieces;
    try {
      final got = await _fetcher.getCached(
        indexUri,
        cache: _cacheFile(),
        refresh: refresh,
        maxBytes: StoreSource.maxIndexBytes,
        // Read whole before it is cached, so a broken catalog never
        // replaces a good copy.
        decode: (bytes) async {
          final text = _utf8(bytes);
          final (index, used) = await _read(text, pieces, online: true);
          fresh = index;
          freshPieces = used;
          return text;
        },
      );
      final index = fresh;
      if (index != null) {
        pieces?.retainOnly(freshPieces!);
        return FetchedIndex(index);
      }
      final (cached, _) = await _read(got.text, pieces, online: !got.offline);
      return FetchedIndex(cached, offline: got.offline, error: got.error);
    } on FetchException catch (e) {
      // A piece the new index.json names is gone: another catalog was
      // published between the two requests. Ask for index.json once more.
      if (e.statusCode == 404 && e.uri != indexUri && !retried) {
        return _fetchIndex(refresh: true, retried: true);
      }
      rethrow;
    }
  }

  /// The catalog [text] describes, its pieces read from [cache] or — when
  /// [online] — fetched; and the SHA-256 of every piece it uses.
  Future<(StoreIndex, Set<String>)> _read(
    String text,
    HashedFiles? cache, {
    required bool online,
  }) async {
    final used = <String>{};
    final index = await StoreSource._catalogFrom(text, (ref) async {
      used.add(ref.sha256);
      final cached = cache?.read(ref.sha256);
      if (cached != null) return cached;
      final uri = resolve(ref.path);
      if (!online) {
        throw SourceException(
          'Part of the catalog was never downloaded, and the catalog can\'t '
          'be reached.',
          uri: uri,
        );
      }
      final bytes = await readBytes(uri, maxBytes: ref.size);
      // Only what matches its name is kept (CatalogPiece.read checks it
      // again, and says what is wrong).
      if (bytes.length == ref.size && Sha256.hexOf(bytes) == ref.sha256) {
        cache?.write(ref.sha256, bytes);
      }
      return bytes;
    }, file: '$indexUri');
    return (index, used);
  }

  /// Where this catalog's pieces are cached, beside its `index.json`.
  HashedFiles? _pieceCache() {
    final file = _cacheFile();
    if (file == null) return null;
    final path = file.path;
    return HashedFiles(
      '${path.substring(0, path.length - '.json'.length)}.pieces',
      ext: 'json',
    );
  }

  @override
  Future<Uint8List> readBytes(
    Uri uri, {
    ByteProgress? onProgress,
    CancelToken? cancel,
    int? maxBytes,
    Map<String, String> headers = const {},
  }) async {
    if (uri.scheme == 'file') {
      throw SourceException(
        'A web catalog cannot point to files on this machine.',
        uri: uri,
      );
    }
    final response = await _fetcher.get(
      uri,
      headers: headers,
      onProgress: onProgress,
      cancel: cancel,
      maxBytes: maxBytes,
    );
    return response.body;
  }

  File? _cacheFile() {
    final dir = cacheDir;
    if (dir == null) return null;
    final key = Uri.encodeComponent('$indexUri').replaceAll('%', '_');
    final short = key.length > 120 ? key.substring(key.length - 120) : key;
    return File('$dir/catalogs/$short.json');
  }
}

String _utf8(Uint8List bytes) {
  try {
    return const Utf8Decoder().convert(bytes);
  } on FormatException {
    throw const StoreFormatException('The catalog is not UTF-8 text.');
  }
}

/// What a package's GitHub release says it holds: `just_release.json`, a
/// file with a fixed name in every release (`just store pack` writes it), so
/// the newest is at `releases/latest/download/just_release.json` — a CDN
/// download, not the rate-limited GitHub API.
final class JustRelease {
  /// The release [tag], holding [manifest]'s package as [version] (its
  /// catalog version entry; the archive's `url` relative to the release).
  const JustRelease({
    required this.tag,
    required this.manifest,
    required this.version,
    this.claim,
  });

  /// The claim code ([claimCode]) of the store account that may publish
  /// it, when its maker put one in.
  final String? claim;

  /// The file's name in every release.
  static const String fileName = GitHubRepo.manifestFile;

  /// The newest format this version reads.
  static const int currentSchema = 1;

  /// The release's tag.
  final String tag;

  /// The package's `just_store.json`.
  final ItemManifest manifest;

  /// The version's catalog entry: archive, SHA-256, requirements.
  final Map<String, Object?> version;

  /// [text] as a release file. Throws [StoreFormatException].
  factory JustRelease.parse(String text) {
    final json = JsonFields.parse(text);
    final schema = json.integer('schema', min: 1);
    if (schema > currentSchema) {
      throw json.error(
        'schema',
        'This release needs a newer Asset Store (format $schema).',
      );
    }
    final raw = json.raw('version');
    if (raw is! Map) throw json.error('version', 'Expected an object.');
    final claim = json.optString('claim');
    if (claim != null && !isClaimCode(claim)) {
      throw json.error('claim', 'Not a claim code (jas1-…).');
    }
    return JustRelease(
      tag: json.string('tag'),
      manifest: ItemManifest.fromJson(json.object('manifest')),
      version: raw.cast<String, Object?>(),
      claim: claim,
    );
  }

  /// The file's text.
  String toText() => canonicalJson(
    compactJson({
      'schema': currentSchema,
      'tag': tag,
      'claim': claim,
      'manifest': manifest.toJson(),
      'version': version,
    }),
  );
}

/// A package straight from its GitHub releases, listed in no catalog: what
/// `just add https://github.com/<owner>/<repo>` installs from.
///
/// Its catalog is one item, read from the release's [JustRelease]. Its
/// archive is pinned to the release's tag (never `latest`), so a lockfile
/// that recorded it restores the same bytes after newer releases. The item
/// is `community`: nobody reviewed it.
final class GitHubSource extends StoreSource {
  /// The releases of [repo] — [tag]'s, or the newest when null.
  GitHubSource(
    this.repo, {
    this.tag,
    this.cacheDir,
    HttpClient Function()? client,
  }) : _fetcher = HttpFetcher(
         userAgent: HttpStoreSource.userAgent,
         client: client,
       ),
       super._();

  /// The repository.
  final GitHubRepo repo;

  /// The release, or null for the newest.
  final String? tag;

  /// Where the release file is cached.
  final String? cacheDir;

  final HttpFetcher _fetcher;

  /// The source id items from it are recorded under.
  String get id => 'github:$repo';

  /// The source for [url] when it names a GitHub repository — the page
  /// (`https://github.com/<owner>/<repo>[@<tag>]`) or a release's
  /// `just_release.json` — else null.
  static GitHubSource? tryFrom(
    String url, {
    String? cacheDir,
    HttpClient Function()? client,
  }) {
    final release = RegExp(
      r'^https://github\.com/([^/]+)/([^/]+)/releases/(?:latest/download|download/([^/]+))/just_release\.json$',
    ).firstMatch(url);
    if (release != null) {
      final repo = GitHubRepo.tryParse('${release[1]}/${release[2]}');
      if (repo == null) return null;
      return GitHubSource(
        repo,
        tag: release[3],
        cacheDir: cacheDir,
        client: client,
      );
    }
    final lower = url.toLowerCase();
    if (!lower.startsWith('https://github.com/') &&
        !lower.startsWith('github.com/')) {
      return null;
    }
    final at = url.lastIndexOf('@');
    final repo = GitHubRepo.tryParse(at < 0 ? url : url.substring(0, at));
    if (repo == null) return null;
    return GitHubSource(
      repo,
      tag: at < 0 ? null : url.substring(at + 1),
      cacheDir: cacheDir,
      client: client,
    );
  }

  @override
  Uri get indexUri => repo.manifest(tag: tag);

  @override
  Future<FetchedIndex> fetchIndex({bool refresh = false}) async {
    final dir = cacheDir;
    final key = '$repo@${tag ?? 'latest'}'.replaceAll(RegExp(r'[^\w.@-]'), '_');
    try {
      final got = await _fetcher.getCached(
        indexUri,
        cache: dir == null ? null : File('$dir/github/$key.json'),
        refresh: refresh,
        maxBytes: 1024 * 1024,
        decode: (bytes) {
          final text = _utf8(bytes);
          JustRelease.parse(text);
          return text;
        },
      );
      final release = JustRelease.parse(got.text);
      return FetchedIndex(
        indexFor(release),
        offline: got.offline,
        error: got.error,
      );
    } on StoreFormatException catch (e) {
      throw e.inFile('$indexUri');
    }
  }

  /// The one-item catalog [release] makes, its archive pinned to the tag.
  StoreIndex indexFor(JustRelease release) {
    final m = release.manifest;
    final version = <String, Object?>{...release.version};
    final archive = version['archive'];
    if (archive is Map) {
      // Pinned to the tag: `latest` moves on, a lockfile must not.
      final file = '${archive['url']}'.split('/').last;
      final Uri url;
      try {
        url = repo.releaseFile(file, tag: release.tag);
      } on ArgumentError catch (e) {
        throw StoreFormatException(
          'The release names a bad file: ${e.message}',
        );
      }
      version['archive'] = {...archive.cast<String, Object?>(), 'url': '$url'};
    }
    // What it may do, and how finished it is, is what its manifest says,
    // whatever the entry claims.
    version['permissions'] = [
      for (final p in ItemPermission.values)
        if (m.permissions.contains(p)) p.id,
    ];
    version
      ..remove('stage')
      ..remove('replacedBy');
    if (m.stage case final stage?) version['stage'] = stage.id;
    if (m.replacedBy case final by?) version['replacedBy'] = by;
    final item = StoreItem(
      id: m.id,
      name: m.name,
      kind: m.kind,
      category: m.category,
      summary: m.summary,
      description: m.description,
      tags: m.tags,
      author: m.author,
      license: m.license,
      // Its pictures are release files beside the archive (`just store
      // pack` puts them there), as the store's own pages find them.
      previews: [
        for (final path in m.previews)
          '${repo.releaseFile(path.split('/').last, tag: release.tag)}',
      ],
      trust: TrustLevel.community,
      publisher: repo.owner,
      sourceRepo: '${repo.url}',
      versions: [StoreItemVersion.fromJson(JsonFields(version), m.kind)],
    );
    return StoreIndex(
      source: StoreSourceInfo(id, '$repo (unlisted)', homepage: '${repo.url}'),
      categories: [StoreCategory(m.category, m.category)],
      items: [item],
    );
  }

  @override
  Future<Uint8List> readBytes(
    Uri uri, {
    ByteProgress? onProgress,
    CancelToken? cancel,
    int? maxBytes,
    Map<String, String> headers = const {},
  }) async {
    final response = await _fetcher.get(
      uri,
      headers: headers,
      onProgress: onProgress,
      cancel: cancel,
      maxBytes: maxBytes,
    );
    return response.body;
  }
}
