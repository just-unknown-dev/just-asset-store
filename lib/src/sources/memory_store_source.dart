part of 'store_source.dart';

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

  /// Made by the program itself (`just store vendor`, a test): it vouches
  /// at a `memory:` address, or one in a folder on this machine.
  @override
  bool get vouches =>
      indexUri.scheme == 'memory' ||
      (indexUri.scheme == 'file' && indexUri.host.isEmpty) ||
      super.vouches;

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
    if (bytes == null) throw FetchException('The file is missing.', uri: uri);
    onProgress?.call(bytes.length, bytes.length);
    return bytes;
  }
}
