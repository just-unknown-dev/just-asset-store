part of 'store_source.dart';

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
      throw FetchException(
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
        allowRedirect: mayFetch,
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
        throw FetchException(
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
      throw FetchException(
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
      allowRedirect: mayFetch,
    );
    return response.body;
  }

  /// Where this catalog is cached: its host, to read, and the SHA-256 of
  /// its whole address, so two catalogs never share a file (or a pieces
  /// folder), however long their addresses and however alike their ends.
  File? _cacheFile() {
    final dir = cacheDir;
    if (dir == null) return null;
    final host = indexUri.host.replaceAll(RegExp(r'[^\w.-]'), '_');
    final name = host.length > 40 ? host.substring(0, 40) : host;
    final hash = Sha256.hexOf(utf8.encode('$indexUri')).substring(0, 32);
    return File('$dir/catalogs/$name-$hash.json');
  }
}
