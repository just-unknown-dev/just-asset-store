part of 'store_source.dart';

/// A catalog in a folder on disk (a studio's shared drive, a test).
final class FolderStoreSource extends StoreSource {
  /// The catalog at [location]: a folder holding `index.json`, the file
  /// itself, or a `file:` URL to either. [chosen] unless only a project's
  /// lockfile names it; [client] makes the connections for the archives it
  /// names on the web (tests pass a fake).
  FolderStoreSource(String location, {this.chosen = true, this.client})
    : super._() {
    var path = location.startsWith('file:')
        ? Uri.parse(location).toFilePath()
        : location;
    path = path.replaceAll(r'\', '/');
    final file = path.endsWith('.json') ? File(path) : File('$path/index.json');
    indexUri = file.absolute.uri;
  }

  @override
  late final Uri indexUri;

  /// Whether the user chose this catalog — in this run (`--source`) or in
  /// the editor's settings — rather than only the project's lockfile
  /// naming it. Only a chosen one, on this machine (never another
  /// machine's share), vouches for its items: the lockfile is shared with
  /// the project.
  final bool chosen;

  /// Makes the connections for the archives it names on the web.
  final HttpClient Function()? client;

  @override
  bool get vouches => chosen && indexUri.host.isEmpty;

  @override
  Future<FetchedIndex> fetchIndex({bool refresh = false}) async {
    final file = File.fromUri(indexUri);
    if (!file.existsSync()) {
      throw FetchException('There is no catalog here.', uri: indexUri);
    }
    final String text;
    try {
      text = _utf8(await file.readAsBytes());
    } on JsonFormatException catch (e) {
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
      throw FetchException('A piece of the catalog is missing.', uri: uri);
    }
    if (piece.lengthSync() != ref.size) {
      throw JsonFormatException(
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
      return HttpStoreSource(uri, client: client).readBytes(
        uri,
        onProgress: onProgress,
        cancel: cancel,
        maxBytes: maxBytes,
        headers: headers,
      );
    }
    if (uri.scheme != 'file') {
      throw FetchException(
        'A folder catalog can only point to files beside it, or on the web.',
        uri: uri,
      );
    }
    final file = File.fromUri(uri);
    if (!file.existsSync()) {
      throw FetchException('The file is missing.', uri: uri);
    }
    final length = file.lengthSync();
    if (maxBytes != null && length > maxBytes) {
      throw FetchException(
        'The file is larger than the catalog says.',
        uri: uri,
      );
    }
    final bytes = await file.readAsBytes();
    onProgress?.call(bytes.length, bytes.length);
    return bytes;
  }
}
