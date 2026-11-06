/// Where catalogs and archives come from — a web address, a folder, a GitHub
/// release, memory — and downloading them, checked and cached, with the
/// just_core_cli names for fetching.
library;

export 'package:just_core_cli/fetch.dart'
    show
        ByteProgress,
        CancelToken,
        CancelledException,
        DownloadCache,
        DownloadException,
        FetchException;

export 'downloader.dart';
export 'store_source.dart';
