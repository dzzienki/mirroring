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
  String sessionToken;
  final int maxClients;

  HttpServer? _server;
  final List<WebSocketChannel> _clients = [];

  StreamingServer({
    this.port = 8080,
    required this.onClientAction,
    this.sessionToken = '',
    this.maxClients = 1,
  });

  int get clientCount => _clients.length;
  bool get isRunning => _server != null;
  bool isMirroringActive = false;

  /// Update session token and disconnect existing clients immediately
  void updateSessionToken(String newToken) {
    sessionToken = newToken;
    disconnectAllClients('Session token updated');
  }

  /// Disconnect all currently connected clients
  void disconnectAllClients([String reason = 'Host disconnected all clients']) {
    for (final client in _clients) {
      try {
        client.sink.close(4001, reason);
      } catch (_) {}
    }
    _clients.clear();
  }

  /// Start local HTTP and WebSocket server
  Future<void> start() async {
    if (_server != null) return;

    final wsHandler = webSocketHandler((WebSocketChannel webSocket, [String? subprotocol]) {
      // 1-Device Exclusive Lock:
      // If a previous client was connected, disconnect it cleanly so the current legitimate user connects smoothly
      if (_clients.length >= maxClients) {
        print('[StreamingServer] Replacing previous client with new authenticated client');
        for (final oldClient in _clients) {
          try {
            oldClient.sink.close(4001, 'Another device connected with valid token');
          } catch (_) {}
        }
        _clients.clear();
      }

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
      final token = request.url.queryParameters['token'] ?? '';

      // 1. WebSocket Endpoint Security Check
      if (path == 'ws' || path == '/ws') {
        if (sessionToken.isNotEmpty && token != sessionToken) {
          print('[StreamingServer] WebSocket rejected: invalid token ($token vs $sessionToken)');
          return Response.forbidden('Unauthorized: Invalid or missing security token');
        }
        return wsHandler(request);
      }

      // 2. Main Web Viewfinder HTML Security Check
      if (path == '' || path == '/' || path == 'index.html') {
        if (sessionToken.isNotEmpty && token != sessionToken) {
          print('[StreamingServer] HTTP GET rejected: invalid token ($token vs $sessionToken)');
          return Response.forbidden(
            '''<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>접속 차단됨 - 무선 셀카 모니터</title>
  <style>
    body { background-color: #0c0c0e; color: #fff; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; padding: 20px; box-sizing: border-box; text-align: center; }
    .card { background: rgba(30, 30, 35, 0.9); border: 1px solid rgba(255, 255, 255, 0.15); border-radius: 24px; padding: 36px 24px; max-width: 360px; box-shadow: 0 12px 36px rgba(0,0,0,0.6); }
    .icon { font-size: 56px; margin-bottom: 16px; }
    h2 { font-size: 20px; font-weight: 700; margin: 0 0 10px 0; color: #ff453a; }
    p { font-size: 14px; color: #aaa; line-height: 1.6; margin: 0; }
    .badge { margin-top: 18px; display: inline-block; background: rgba(255, 69, 58, 0.15); color: #ff6961; border: 1px solid rgba(255, 69, 58, 0.3); border-radius: 14px; padding: 6px 14px; font-size: 12px; font-weight: 600; }
  </style>
</head>
<body>
  <div class="card">
    <div class="icon">🔒</div>
    <h2>접속이 차단되었습니다</h2>
    <p>유효하지 않거나 만료된 보안 세션 토큰입니다.<br>메인 폰(갤럭시) 화면에 표시된 <b>최신 QR 코드</b>를 다시 스캔해 주세요.</p>
    <div class="badge">보안 세션 불일치 (403)</div>
  </div>
</body>
</html>''',
            headers: {
              'content-type': 'text/html; charset=utf-8',
              'cache-control': 'no-store, no-cache, must-revalidate',
            },
          );
        }

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
