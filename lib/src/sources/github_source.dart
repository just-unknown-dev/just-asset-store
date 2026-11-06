part of 'store_source.dart';

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
        allowRedirect: mayFetch,
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
    } on JsonFormatException catch (e) {
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
        throw JsonFormatException('The release names a bad file: ${e.message}');
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
      allowRedirect: mayFetch,
    );
    return response.body;
  }
}
