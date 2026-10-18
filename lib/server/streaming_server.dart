import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

typedef ActionCallback = void Function(String action, Map<String, dynamic> data);

class StreamingServer {
  final int port;
  final ActionCallback onClientAction;

  HttpServer? _server;
  final List<WebSocketChannel> _clients = [];

  StreamingServer({this.port = 8080, required this.onClientAction});

  int get clientCount => _clients.length;
  bool get isRunning => _server != null;
  bool isMirroringActive = false;

  /// Start local HTTP and WebSocket server
  Future<void> start() async {
    if (_server != null) return;

    final wsHandler = webSocketHandler((WebSocketChannel webSocket, [String? subprotocol]) {
      _clients.add(webSocket);

      // Send initial status to newly connected client
      try {
        webSocket.sink.add(jsonEncode({
          'event': 'status',
          'isMirroring': isMirroringActive,
        }));
      } catch (_) {}

      webSocket.stream.listen(
        (message) {
          try {
            if (message is String) {
              final data = jsonDecode(message) as Map<String, dynamic>;
              final action = data['action'] as String? ?? '';
              onClientAction(action, data);
            }
          } catch (e) {
            // ignore malformed message
          }
        },
        onDone: () {
          _clients.remove(webSocket);
        },
        onError: (_) {
          _clients.remove(webSocket);
        },
      );
    });

    final handler = const Pipeline()
        .addMiddleware(logRequests())
        .addHandler((Request request) async {
      final path = request.url.path;

      if (path == 'ws' || path == '/ws') {
        return wsHandler(request);
      }

      if (path == '' || path == '/' || path == 'index.html') {
        try {
          final content = await rootBundle.loadString('assets/web/index.html');
          return Response.ok(
            content,
            headers: {
              'content-type': 'text/html; charset=utf-8',
              'cache-control': 'no-store, no-cache, must-revalidate, max-age=0, post-check=0, pre-check=0',
              'pragma': 'no-cache',
              'expires': 'Thu, 01 Jan 1970 00:00:00 GMT',
            },
          );
        } catch (e) {
          return Response.internalServerError(body: 'Failed to load index.html: $e');
        }
      }

      if (path == 'manifest.json') {
        try {
          final content = await rootBundle.loadString('assets/web/manifest.json');
          return Response.ok(
            content,
            headers: {'content-type': 'application/json'},
          );
        } catch (e) {
          return Response.notFound('manifest not found');
        }
      }

      return Response.notFound('Not found');
    });

    try {
      _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
    } catch (e) {
      rethrow;
    }
  }

  int _broadcastCount = 0;

  /// Broadcast compressed JPEG frame to all connected viewfinder clients
  void broadcastFrame(Uint8List jpegBytes) {
    // Drop frames immediately if mirroring is paused/stopped or no clients connected
    if (!isMirroringActive || _clients.isEmpty || jpegBytes.isEmpty) return;

    _broadcastCount++;
    if (_broadcastCount % 60 == 0) {
      // Periodic check
    }

    for (var i = _clients.length - 1; i >= 0; i--) {
      try {
        _clients[i].sink.add(jpegBytes);
      } catch (e) {
        _clients.removeAt(i);
      }
    }
  }

  /// Notify clients about an event (e.g. photo saved, recording status)
  void notifyEvent(String eventName, [Map<String, dynamic>? data]) {
    if (eventName == 'mirroring_stopped') {
      isMirroringActive = false;
    } else if (eventName == 'mirroring_started') {
      isMirroringActive = true;
    }

    print('[StreamingServer] notifyEvent: $eventName to ${_clients.length} clients');

    if (_clients.isEmpty) return;

    final payload = jsonEncode({
      'event': eventName,
      ...?data,
    });

    for (var i = _clients.length - 1; i >= 0; i--) {
      try {
        _clients[i].sink.add(payload);
      } catch (e) {
        print('[StreamingServer] Error sending to client $i: $e');
        _clients.removeAt(i);
      }
    }
  }

  /// Stop server
  Future<void> stop() async {
    for (final client in _clients) {
      await client.sink.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
  }
}
