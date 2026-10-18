import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/camera_host_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep screen on and portrait mode for camera host
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(const SelfieMirrorApp());
}

class SelfieMirrorApp extends StatelessWidget {
  const SelfieMirrorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '무선 셀카 모니터',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          secondary: Colors.cyanAccent,
        ),
        useMaterial3: true,
      ),
      home: const CameraHostScreen(),
    );
  }
}
