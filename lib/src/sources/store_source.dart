/// Where catalogs and archives come from: a web address or a folder.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_core_cli/fetch.dart';

import '../catalog/item_manifest.dart';
import '../catalog/json.dart';
import '../catalog/store_index.dart';
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
    'https://store.justunknown.com/index.json',
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
    if (uri.scheme == 'http' && indexUri.scheme == 'https') {
      throw SourceException(
        '${item.name} ${version.version}: a catalog on the web points its '
        'archive at this machine, which the store refuses.',
        uri: uri,
      );
    }
    return uri;
  }

  /// The most pages a catalog may be split into.
  static const int maxPages = 100;

  /// [first], the catalog's first page, with every page its `next` links
  /// lead to, read from this source: one catalog.
  Future<StoreIndex> withPages(StoreIndex first) async {
    if (first.next == null) return first;
    final items = [...first.items];
    final categories = {for (final c in first.categories) c.id: c};
    final skipped = [...first.skipped];
    final seen = {'$indexUri'};
    var next = first.next;
    for (var page = 2; next != null; page++) {
      if (page > maxPages) {
        throw SourceException(
          'The catalog has more than $maxPages pages.',
          uri: indexUri,
        );
      }
      final uri = resolve(next);
      if (!seen.add('$uri')) {
        throw SourceException(
          'The catalog\'s pages lead in a circle.',
          uri: uri,
        );
      }
      final StoreIndex part;
      try {
        part = StoreIndex.parse(
          _utf8(await readBytes(uri, maxBytes: 32 * 1024 * 1024)),
        );
      } on StoreFormatException catch (e) {
        throw e.inFile('$uri');
      }
      for (final c in part.categories) {
        categories.putIfAbsent(c.id, () => c);
      }
      items.addAll(part.items);
      skipped.addAll(part.skipped);
      next = part.next;
    }
    final ids = <String>{};
    for (final i in items) {
      if (!ids.add(i.id)) {
        throw StoreFormatException(
          '"${i.id}" is listed on two of the catalog\'s pages.',
          file: '$indexUri',
        );
      }
    }
    return StoreIndex(
      source: first.source,
      categories: categories.values.toList()
        ..sort((a, b) => a.order.compareTo(b.order)),
      items: items,
      generatedAt: first.generatedAt,
      skipped: skipped,
    );
  }
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
    try {
      return FetchedIndex(StoreIndex.parse(await file.readAsString()));
    } on StoreFormatException catch (e) {
      throw e.inFile(file.path);
    }
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

  @override
  Future<FetchedIndex> fetchIndex({bool refresh = false}) async {
    StoreIndex? fresh;
    try {
      final got = await _fetcher.getCached(
        indexUri,
        cache: _cacheFile(),
        refresh: refresh,
        maxBytes: 32 * 1024 * 1024,
        // Parsed before it is cached, so a broken catalog never replaces a
        // good copy.
        decode: (bytes) {
          final text = _utf8(bytes);
          fresh = StoreIndex.parse(text);
          return text;
        },
      );
      return FetchedIndex(
        fresh ?? StoreIndex.parse(got.text),
        offline: got.offline,
        error: got.error,
      );
    } on StoreFormatException catch (e) {
      throw e.inFile('$indexUri');
    }
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
  });

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
    return JustRelease(
      tag: json.string('tag'),
      manifest: ItemManifest.fromJson(json.object('manifest')),
      version: raw.cast<String, Object?>(),
    );
  }

  /// The file's text.
  String toText() => canonicalJson({
    'schema': currentSchema,
    'tag': tag,
    'manifest': manifest.toJson(),
    'version': version,
  });
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
    final item = StoreItem(
      id: m.id,
      name: m.name,
      kind: m.kind,
      category: m.category,
      license: m.license,
      previews: m.previews,
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
