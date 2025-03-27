import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Utility class for converting camera images to the format required by ML Kit
class CameraImageUtils {
  /// Converts a [CameraImage] from the camera plugin to an [InputImage] for ML Kit
  static InputImage? convertCameraImageToInputImage(
    CameraImage image,
    CameraDescription camera,
  ) {
    final rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    if (rotation == null) return null;

    // Determine input image format based on image format
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    // For YUV420 format (most common)
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    // Create input image metadata
    final inputImageData = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: image.planes[0].bytesPerRow,
    );

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: inputImageData,
    );
  }
  
  /// Converts an image file to InputImage for ML Kit
  static InputImage fileToInputImage(File file) {
    return InputImage.fromFile(file);
  }
  
  /// Gets the correct device orientation for the camera preview
  static DeviceOrientation getDeviceOrientationForCamera(CameraDescription camera) {
    // Determine the best orientation based on sensor orientation and device type
    switch (camera.sensorOrientation) {
      case 0:
        return DeviceOrientation.portraitUp;
      case 90:
        return Platform.isAndroid 
            ? DeviceOrientation.landscapeLeft 
            : DeviceOrientation.landscapeRight;
      case 180:
        return DeviceOrientation.portraitDown;
      case 270:
        return Platform.isAndroid 
            ? DeviceOrientation.landscapeRight 
            : DeviceOrientation.landscapeLeft;
      default:
        return DeviceOrientation.portraitUp;
    }
  }
  
  /// Calculates face detection overlay position adjustments based on camera preview size
  static Map<String, double> calculateFaceOverlayAdjustments(
    Size imageSize, 
    Size previewSize,
    CameraLensDirection cameraLensDirection
  ) {
    final double imageRatio = imageSize.width / imageSize.height;
    final double previewRatio = previewSize.width / previewSize.height;
    
    double widthScale = 1.0;
    double heightScale = 1.0;
    double horizontalOffset = 0.0;
    double verticalOffset = 0.0;
    
    // Adjust for aspect ratio differences
    if (imageRatio > previewRatio) {
      // Image is wider than preview
      widthScale = previewSize.height / imageSize.height;
      horizontalOffset = (imageSize.width * widthScale - previewSize.width) / 2;
    } else {
      // Image is taller than preview
      heightScale = previewSize.width / imageSize.width;
      verticalOffset = (imageSize.height * heightScale - previewSize.height) / 2;
    }
    
    // Additional adjustment for front camera (mirrored)
    final bool isFrontCamera = cameraLensDirection == CameraLensDirection.front;
    final double mirrorFactor = isFrontCamera ? -1.0 : 1.0;
    
    return {
      'widthScale': widthScale,
      'heightScale': heightScale,
      'horizontalOffset': horizontalOffset,
      'verticalOffset': verticalOffset,
      'mirrorFactor': mirrorFactor,
    };
  }
}
