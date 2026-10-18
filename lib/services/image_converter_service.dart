import 'dart:developer' as developer;
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

class ImageConverterService {
  static const MethodChannel _channel = MethodChannel('com.selfie.mirroring/image_converter');

  /// Convert CameraImage (YUV_420_888 on Android) to compressed JPEG bytes
  static Future<Uint8List?> convertToJpeg(CameraImage image, {int quality = 60}) async {
    if (Platform.isAndroid) {
      try {
        if (image.planes.length < 3) return null;

        final yPlane = image.planes[0];
        final uPlane = image.planes[1];
        final vPlane = image.planes[2];

        final result = await _channel.invokeMethod<Uint8List>('yuvToJpeg', {
          'yPlane': yPlane.bytes,
          'uPlane': uPlane.bytes,
          'vPlane': vPlane.bytes,
          'width': image.width,
          'height': image.height,
          'yRowStride': yPlane.bytesPerRow,
          'uvRowStride': uPlane.bytesPerRow,
          'uvPixelStride': uPlane.bytesPerPixel ?? 1,
          'quality': quality,
        });

        return result;
      } catch (e, stackTrace) {
        developer.log('Conversion error: $e', name: 'ImageConverter', error: e, stackTrace: stackTrace);
        return null;
      }
    }

    // Fallback if running on desktop or other platforms (mock or null)
    return null;
  }
}
