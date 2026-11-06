/// An [HttpClient] for servers on the web, without a network: each host
/// answers with a redirect, or with a body.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// A client whose hosts answer as [redirects] (host → the address they
/// redirect every request to) and [bodies] (host → what they send), noting
/// every address asked for in [asked]. Any other host is unreachable.
final class RedirectingClient implements HttpClient {
  /// The client for these hosts.
  RedirectingClient({
    this.redirects = const {},
    this.bodies = const {},
    List<Uri>? asked,
  }) : asked = asked ?? [];

  /// The hosts that redirect, and where to.
  final Map<String, String> redirects;

  /// The hosts that answer, and with what.
  final Map<String, List<int>> bodies;

  /// Every address asked for, in order.
  final List<Uri> asked;

  @override
  Duration? connectionTimeout;

  @override
  String? userAgent;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    asked.add(url);
    final to = redirects[url.host];
    if (to != null) return _Request(HttpStatus.found, {'location': to}, []);
    final body = bodies[url.host];
    if (body != null) return _Request(HttpStatus.ok, const {}, body);
    throw SocketException('No route to ${url.host}');
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Request implements HttpClientRequest {
  _Request(this.status, this.answer, this.body);

  final int status;
  final Map<String, String> answer;
  final List<int> body;

  @override
  bool followRedirects = true;

  @override
  final HttpHeaders headers = _Headers(const {});

  @override
  Future<HttpClientResponse> close() async => _Response(status, answer, body);

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, this.answer, this.body);

  @override
  final int statusCode;

  final Map<String, String> answer;
  final List<int> body;

  @override
  int get contentLength => body.length;

  @override
  HttpHeaders get headers => _Headers(answer);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.fromIterable([
        if (body.isNotEmpty) Uint8List.fromList(body),
      ]).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Headers implements HttpHeaders {
  _Headers(this._values);

  final Map<String, String> _values;

  @override
  String? value(String name) => _values[name.toLowerCase()];

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
