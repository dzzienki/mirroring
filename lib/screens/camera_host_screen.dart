import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../server/streaming_server.dart';

class CameraHostScreen extends StatefulWidget {
  const CameraHostScreen({super.key});

  @override
  State<CameraHostScreen> createState() => _CameraHostScreenState();
}

class _CameraHostScreenState extends State<CameraHostScreen> {
  static const MethodChannel _mirrorChannel = MethodChannel('com.selfie.mirroring/screen_mirror');
  static const BasicMessageChannel<dynamic> _frameChannel =
      BasicMessageChannel('com.selfie.mirroring/screen_frames', StandardMessageCodec());

  StreamingServer? _server;
  String _serverIp = '127.0.0.1';
  final int _serverPort = 8080;
  int _connectedClientCount = 0;
  bool _isMirroring = false;

  bool _isAccessibilityEnabled = false;

  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _initHost();
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _server?.stop();
    super.dispose();
  }

  Future<void> _initHost() async {
    // 1. Request notification permission (needed for ForegroundService on Android 13+)
    await Permission.notification.request();

    // 2. Resolve IP Address (Wi-Fi or Hotspot)
    await _resolveLocalIp();

    // 3. Start Streaming Server
    _server = StreamingServer(
      port: _serverPort,
      onClientAction: _handleClientAction,
    );
    await _server!.start();

    // 4. Listen for native capture lifecycle events from MainActivity
    _mirrorChannel.setMethodCallHandler((call) async {
      if (call.method == 'onCaptureStopped') {
        _handleCaptureStopped();
      } else if (call.method == 'onCaptureStarted') {
        _handleCaptureStarted();
      }
      return null;
    });

    // 5. Listen for raw JPEG screen frames from native ScreenCaptureService
    _frameChannel.setMessageHandler((dynamic message) async {
      if (_isMirroring && _server != null && _server!.isMirroringActive && message is Uint8List && message.isNotEmpty) {
        _server!.broadcastFrame(message);
      }
      return null;
    });

    // Check mirroring and accessibility status periodically
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (mounted && _server != null) {
        final clientCount = _server!.clientCount;
        bool isA11y = _isAccessibilityEnabled;
        try {
          isA11y = await _mirrorChannel.invokeMethod<bool>('isAccessibilityEnabled') ?? false;
        } catch (_) {}

        if (_connectedClientCount != clientCount || _isAccessibilityEnabled != isA11y) {
          setState(() {
            _connectedClientCount = clientCount;
            _isAccessibilityEnabled = isA11y;
          });
        }
      }
    });

    if (mounted) setState(() {});
  }

  void _notifyMirroringStopped() {
    developer.log('Notifying mirroring_stopped to server', name: 'Host');
    _server?.isMirroringActive = false;
    _server?.notifyEvent('mirroring_stopped');

    // Multi-pulse delivery (200ms, 600ms, 1200ms) guarantees that any client—even one
    // running an unrefreshed tab with the old guard—transitions cleanly to the standby screen!
    for (final delayMs in [200, 600, 1200]) {
      Future.delayed(Duration(milliseconds: delayMs), () {
        if (!_isMirroring && _server != null) {
          _server!.notifyEvent('mirroring_stopped');
        }
      });
    }
  }

  void _handleCaptureStopped() {
    _notifyMirroringStopped();
    if (mounted) {
      setState(() => _isMirroring = false);
    }
  }

  void _handleCaptureStarted() {
    _server?.isMirroringActive = true;
    _server?.notifyEvent('mirroring_started');
    if (mounted) {
      setState(() => _isMirroring = true);
    }
  }

  Future<void> _openAccessibilitySettings() async {
    try {
      await _mirrorChannel.invokeMethod('openAccessibilitySettings');
    } catch (_) {}
  }

  Future<void> _resolveLocalIp() async {
    try {
      final info = NetworkInfo();
      final wifiIp = await info.getWifiIP();
      if (wifiIp != null && wifiIp.isNotEmpty && wifiIp != '0.0.0.0') {
        _serverIp = wifiIp;
        return;
      }

      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.address.startsWith('192.168.43.')) {
            _serverIp = addr.address;
            return;
          }
        }
      }

      if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
        _serverIp = interfaces.first.addresses.first.address;
      }
    } catch (e, st) {
      developer.log('IP resolve error', name: 'Host', error: e, stackTrace: st);
      _serverIp = '192.168.43.1';
    }
  }

  Future<void> _toggleScreenMirror() async {
    try {
      if (_isMirroring) {
        _notifyMirroringStopped();
        setState(() => _isMirroring = false);
        await _mirrorChannel.invokeMethod('stopScreenMirror');
      } else {
        // Launches system permission dialog and auto-minimizes to home!
        await _mirrorChannel.invokeMethod('startScreenMirror');
        _server?.isMirroringActive = true;
        _server?.notifyEvent('mirroring_started');
        setState(() => _isMirroring = true);
      }
    } catch (e) {
      developer.log('Screen mirror toggle error: $e');
    }
  }

  Future<void> _handleClientAction(String action, Map<String, dynamic> data) async {
    developer.log('Client action: $action', name: 'Host');
    if (action == 'take_photo') {
      // Trigger Samsung camera shutter via Volume key!
      try {
        await _mirrorChannel.invokeMethod('triggerCameraShutter');
      } catch (e) {
        developer.log('Shutter trigger error: $e');
      }
    }
  }

  Future<void> _openCameraApp() async {
    try {
      await _mirrorChannel.invokeMethod('openCameraApp');
    } catch (e) {
      developer.log('Open camera error: $e');
    }
  }

  String get _connectionUrl => 'http://$_serverIp:$_serverPort';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('무선 셀카 모니터', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Connection Status Banner
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: _connectedClientCount > 0 ? Colors.greenAccent : Colors.amberAccent,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: (_connectedClientCount > 0 ? Colors.greenAccent : Colors.amberAccent).withValues(alpha: 0.5),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _connectedClientCount > 0
                                ? '서브 폰 연결됨 ($_connectedClientCount대)'
                                : '서브 폰 연결 대기 중...',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _isMirroring ? '🟢 화면 미러링 송출 중' : '⚪ 미러링 대기 상태',
                            style: TextStyle(
                              color: _isMirroring ? Colors.greenAccent : Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // Remote Shutter Accessibility Status Banner
              GestureDetector(
                onTap: _openAccessibilitySettings,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: _isAccessibilityEnabled
                        ? Colors.blue.withValues(alpha: 0.12)
                        : Colors.amber.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _isAccessibilityEnabled
                          ? Colors.cyanAccent.withValues(alpha: 0.3)
                          : Colors.amberAccent.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _isAccessibilityEnabled ? Icons.camera_alt_outlined : Icons.touch_app,
                        color: _isAccessibilityEnabled ? Colors.cyanAccent : Colors.amberAccent,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _isAccessibilityEnabled
                              ? '📸 원격 셔터 준비 완료 (서브폰 터치 시 촬영)'
                              : '⚠️ 원격 셔터 활성화: [접근성 권한 켜기]를 탭하세요',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _isAccessibilityEnabled ? Colors.white70 : Colors.amberAccent,
                          ),
                        ),
                      ),
                      if (!_isAccessibilityEnabled)
                        const Icon(Icons.chevron_right, color: Colors.amberAccent, size: 18),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // 2. Mirroring Action Buttons
              if (_isMirroring) ...[
                // Open Samsung Camera Button
                GestureDetector(
                  onTap: _openCameraApp,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.greenAccent.shade700, Colors.tealAccent.shade700],
                      ),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.greenAccent.withValues(alpha: 0.4),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.camera_alt, color: Colors.white, size: 26),
                        SizedBox(width: 10),
                        Text(
                          '📷 삼성 기본 카메라 열기',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _toggleScreenMirror,
                  icon: const Icon(Icons.stop_circle_outlined, color: Colors.redAccent),
                  label: const Text('화면 미러링 중지', style: TextStyle(color: Colors.redAccent)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: const BorderSide(color: Colors.redAccent),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ] else ...[
                GestureDetector(
                  onTap: _toggleScreenMirror,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.blueAccent.shade700, Colors.cyanAccent.shade700],
                      ),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.blueAccent.withValues(alpha: 0.4),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.screen_share, color: Colors.white, size: 26),
                        SizedBox(width: 10),
                        Text(
                          '🚀 화면 미러링 시작',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),

              // 3. QR Code & Connection Card
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  children: [
                    const Text(
                      '서브 폰 (아이폰/갤럭시) 연결용 QR 코드',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    const SizedBox(height: 14),

                    // QR Image
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: QrImageView(
                        data: _connectionUrl,
                        version: QrVersions.auto,
                        size: 180.0,
                      ),
                    ),

                    const SizedBox(height: 14),
                    SelectableText(
                      _connectionUrl,
                      style: const TextStyle(
                        color: Colors.cyanAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // 4. Simple Usage Guide
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white10),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('📌 초간단 사용 가이드', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white)),
                    SizedBox(height: 8),
                    Text('1. [모바일 핫스팟] 켜기 (LTE/5G 데이터 꺼도 0MB 무료)', style: TextStyle(fontSize: 12, color: Colors.white70)),
                    SizedBox(height: 4),
                    Text('2. 서브 폰(아이폰)에서 해당 와이파이에 연결', style: TextStyle(fontSize: 12, color: Colors.white70)),
                    SizedBox(height: 4),
                    Text('3. 서브 폰 카메라로 위 QR코드 스캔하여 사파리로 접속', style: TextStyle(fontSize: 12, color: Colors.white70)),
                    SizedBox(height: 4),
                    Text('4. [🚀 화면 미러링 시작] 누르고 삼성 기본 카메라 앱 실행!', style: TextStyle(fontSize: 12, color: Colors.greenAccent, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
