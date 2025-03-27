import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:live_photo_detector/index.dart';

class M7LivelynessDetectionScreen extends StatefulWidget {
  final M7DetectionConfig config;
  const M7LivelynessDetectionScreen({
    required this.config,
    super.key,
  });

  @override
  State<M7LivelynessDetectionScreen> createState() => _M7LivelynessDetectionScreenState();
}

class _M7LivelynessDetectionScreenState extends State<M7LivelynessDetectionScreen> {
  // Camera controller
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  
  // Face detection
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableContours: true,
      enableClassification: true,
      enableTracking: true,
    ),
  );
  
  // State variables
  late bool _isInfoStepCompleted;
  late final List<M7LivelynessStepItem> _steps;
  CustomPaint? _customPaint;
  bool _isBusy = false;
  final GlobalKey<M7LivelynessDetectionStepOverlayState> _stepsKey =
      GlobalKey<M7LivelynessDetectionStepOverlayState>();
  bool _isProcessingStep = false;
  bool _didCloseEyes = false;
  bool _isTakingPicture = false;
  Timer? _timerToDetectFace;
  bool _isCaptureButtonVisible = false;
  List<Face> _previousFaces = [];
  int _stableFrameCount = 0;
  static const int _requiredStableFrames = 10;
  
  @override
  void initState() {
    super.initState();
    _preInitCallBack();
    
    // Initialize camera after frame is built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeCamera();
    });
  }
  
  @override
  void dispose() {
    _cameraController?.dispose();
    _faceDetector.close();
    _timerToDetectFace?.cancel();
    _timerToDetectFace = null;
    super.dispose();
  }
  
  void _preInitCallBack() {
    _steps = widget.config.steps;
    _isInfoStepCompleted = !widget.config.startWithInfoScreen;
  }
  
  Future<void> _initializeCamera() async {
    // Get available cameras
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;
    
    // Find front camera
    final frontCamera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    
    // Initialize controller
    _cameraController = CameraController(
      frontCamera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    
    try {
      await _cameraController!.initialize();
      if (!mounted) return;
      
      if (!widget.config.startWithInfoScreen) {
        _startLiveFeed();
      }
      
      setState(() {
        _isCameraInitialized = true;
      });
    } catch (e) {
      print('Error initializing camera: $e');
    }
  }
  
  void _startLiveFeed() {
    if (!_isCameraInitialized) return;
    
    _startTimer();
    _cameraController?.startImageStream(_processCameraImage);
  }
  
  void _startTimer() {
    _timerToDetectFace = Timer(
      Duration(seconds: widget.config.maxSecToDetect),
      () {
        _timerToDetectFace?.cancel();
        _timerToDetectFace = null;
        if (widget.config.allowAfterMaxSec) {
          _isCaptureButtonVisible = true;
          setState(() {});
          return;
        }
        _onDetectionCompleted(imgToReturn: null);
      },
    );
  }
  
  Future<void> _processCameraImage(CameraImage image) async {
    if (_isBusy) return;
    _isBusy = true;
    
    // Convert CameraImage to InputImage
    final inputImage = _convertCameraImageToInputImage(image);
    if (inputImage == null) {
      _isBusy = false;
      return;
    }
    
    // Process the image
    await _processImage(inputImage);
    _isBusy = false;
  }
  
  InputImage? _convertCameraImageToInputImage(CameraImage image) {
    final camera = _cameraController!.description;
    final rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    if (rotation == null) return null;
    
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;
    
    // Convert YUV to bytes
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();
    
    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: image.planes[0].bytesPerRow,
    );
    
    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }
  
  Future<void> _processImage(InputImage inputImage) async {
    // Detect faces
    final faces = await _faceDetector.processImage(inputImage);
    
    if (inputImage.metadata?.size != null && inputImage.metadata?.rotation != null) {
      if (faces.isNotEmpty) {
        // Check for motion detection (anti-spoofing)
        if (_detectMotion(faces.first)) {
          _stableFrameCount = 0;
        } else {
          _stableFrameCount++;
        }
        
        if (_stableFrameCount >= _requiredStableFrames) {
          // If the face is too stable for too long, it might be a static image
          _resetSteps();
        } else {
          // Continue with existing detection logic
          _detect(
            face: faces.first,
            step: _steps[_stepsKey.currentState?.currentIndex ?? 0].step,
          );
        }
        
        _previousFaces = faces;
        
        // Draw face contours
        final firstFace = faces.first;
        final painter = M7FaceDetectorPainter(
          firstFace,
          inputImage.metadata!.size,
          inputImage.metadata!.rotation,
        );
        
        _customPaint = CustomPaint(
          painter: painter,
          child: Container(
            color: Colors.transparent,
            height: double.infinity,
            width: double.infinity,
          ),
        );
        
        // Check for blink detection
        if (_isProcessingStep &&
            _steps[_stepsKey.currentState?.currentIndex ?? 0].step == 
                M7LivelynessStep.blink) {
          if (_didCloseEyes) {
            if ((faces.first.leftEyeOpenProbability ?? 1.0) < 0.75 &&
                (faces.first.rightEyeOpenProbability ?? 1.0) < 0.75) {
              await _completeStep(
                step: _steps[_stepsKey.currentState?.currentIndex ?? 0].step,
              );
            }
          }
        }
        
        _detect(
          face: faces.first,
          step: _steps[_stepsKey.currentState?.currentIndex ?? 0].step,
        );
      } else {
        _resetSteps();
      }
    } else {
      _resetSteps();
    }
    
    if (mounted) {
      setState(() {});
    }
  }
  
  // Detect movement between frames (anti-spoofing)
  bool _detectMotion(Face currentFace) {
    if (_previousFaces.isEmpty) return true;

    final previousFace = _previousFaces.first;
    const double threshold = 2.0;

    return (currentFace.boundingBox.left - previousFace.boundingBox.left).abs() > threshold ||
           (currentFace.boundingBox.top - previousFace.boundingBox.top).abs() > threshold ||
           (currentFace.headEulerAngleY! - previousFace.headEulerAngleY!).abs() > threshold ||
           (currentFace.headEulerAngleZ! - previousFace.headEulerAngleZ!).abs() > threshold;
  }
  
  Future<void> _takePicture() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    
    if (_isTakingPicture) {
      return;
    }
    
    setState(() => _isTakingPicture = true);
    
    try {
      await _cameraController!.stopImageStream();
      final XFile photo = await _cameraController!.takePicture();
      _onDetectionCompleted(imgToReturn: photo);
    } catch (e) {
      print('Error taking picture: $e');
      _startLiveFeed();
      setState(() => _isTakingPicture = false);
    }
  }
  
  void _onDetectionCompleted({XFile? imgToReturn}) {
    if (!mounted) return;
    
    final String? imgPath = imgToReturn?.path;
    Navigator.of(context).pop(imgPath);
  }
  
  void _switchCamera() async {
    final cameras = await availableCameras();
    if (cameras.length < 2) return;
    
    final lensDirection = _cameraController!.description.lensDirection;
    CameraDescription newCamera;
    
    if (lensDirection == CameraLensDirection.front) {
      newCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
    } else {
      newCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
    }
    
    await _cameraController?.dispose();
    
    _cameraController = CameraController(
      newCamera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    
    try {
      await _cameraController!.initialize();
      if (mounted) {
        _startLiveFeed();
        setState(() {});
      }
    } catch (e) {
      print('Error switching camera: $e');
    }
  }
  
  void _resetSteps() {
    for (var i = 0; i < _steps.length; i++) {
      _steps[i] = _steps[i].copyWith(isCompleted: false);
    }
    _customPaint = null;
    _didCloseEyes = false;
    if (_stepsKey.currentState?.currentIndex != 0) {
      _stepsKey.currentState?.reset();
    }
    if (mounted) {
      setState(() {});
    }
  }
  
  Future<void> _completeStep({required M7LivelynessStep step}) async {
    final int indexToUpdate = _steps.indexWhere((p0) => p0.step == step);
    
    _steps[indexToUpdate] = _steps[indexToUpdate].copyWith(isCompleted: true);
    if (mounted) {
      setState(() {});
    }
    await _stepsKey.currentState?.nextPage();
    _stopProcessing();
  }
  
  void _startProcessing() {
    if (!mounted) return;
    setState(() => _isProcessingStep = true);
  }
  
  void _stopProcessing() {
    if (!mounted) return;
    setState(() => _isProcessingStep = false);
  }
  
  void _detect({required Face face, required M7LivelynessStep step}) async {
    if (_isProcessingStep) return;
    
    switch (step) {
      case M7LivelynessStep.motion:
        if (_detectMotion(face)) {
          _stableFrameCount = 0;
          _startProcessing();
          await _completeStep(step: step);
        } else {
          _stableFrameCount++;
          if (_stableFrameCount >= _requiredStableFrames) {
            _resetSteps();
          }
        }
        break;
        
      case M7LivelynessStep.blink:
        final M7BlinkDetectionThreshold? blinkThreshold =
            M7LivelynessDetection.instance.thresholdConfig
                .firstWhereOrNull((p0) => p0 is M7BlinkDetectionThreshold) 
                as M7BlinkDetectionThreshold?;
                
        if ((face.leftEyeOpenProbability ?? 1.0) < 
                (blinkThreshold?.leftEyeProbability ?? 0.25) &&
            (face.rightEyeOpenProbability ?? 1.0) < 
                (blinkThreshold?.rightEyeProbability ?? 0.25)) {
          _startProcessing();
          if (mounted) {
            setState(() => _didCloseEyes = true);
          }
        }
        break;
        
      case M7LivelynessStep.turnLeft:
        final M7HeadTurnDetectionThreshold? headTurnThreshold =
            M7LivelynessDetection.instance.thresholdConfig
                .firstWhereOrNull((p0) => p0 is M7HeadTurnDetectionThreshold) 
                as M7HeadTurnDetectionThreshold?;
                
        if ((face.headEulerAngleY ?? 0) > (headTurnThreshold?.rotationAngle ?? 45)) {
          _startProcessing();
          await _completeStep(step: step);
        }
        break;
        
      case M7LivelynessStep.turnRight:
        final M7HeadTurnDetectionThreshold? headTurnThreshold =
            M7LivelynessDetection.instance.thresholdConfig
                .firstWhereOrNull((p0) => p0 is M7HeadTurnDetectionThreshold) 
                as M7HeadTurnDetectionThreshold?;
                
        if ((face.headEulerAngleY ?? 0) < (headTurnThreshold?.rotationAngle ?? -45)) {
          _startProcessing();
          await _completeStep(step: step);
        }
        break;
        
      case M7LivelynessStep.smile:
        final M7SmileDetectionThreshold? smileThreshold =
            M7LivelynessDetection.instance.thresholdConfig
                .firstWhereOrNull((p0) => p0 is M7SmileDetectionThreshold) 
                as M7SmileDetectionThreshold?;
                
        if ((face.smilingProbability ?? 0) > (smileThreshold?.probability ?? 0.75)) {
          _startProcessing();
          await _completeStep(step: step);
        }
        break;
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: _buildBody(),
      ),
    );
  }
  
  Widget _buildBody() {
    return Stack(
      children: [
        _isInfoStepCompleted ? _buildDetectionBody() : M7LivelynessInfoWidget(
          onStartTap: () {
            if (mounted) {
              setState(() => _isInfoStepCompleted = true);
            }
            _startLiveFeed();
          },
        ),
        Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 10, top: 10),
            child: CircleAvatar(
              radius: 20,
              backgroundColor: Colors.black,
              child: IconButton(
                onPressed: () => _onDetectionCompleted(imgToReturn: null),
                icon: const Icon(
                  Icons.close_rounded,
                  size: 20,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
  
  Widget _buildDetectionBody() {
    if (!_isCameraInitialized) {
      return const Center(
        child: CircularProgressIndicator.adaptive(),
      );
    }
    
    // Camera preview
    final cameraPreview = CameraPreview(_cameraController!);
    
    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera preview in the center
        Center(child: cameraPreview),
        
        // Face detection overlay
        if (_customPaint != null) _customPaint!,
        
        // Step guidance overlay
        M7LivelynessDetectionStepOverlay(
          key: _stepsKey,
          steps: _steps,
          onCompleted: () => Future.delayed(
            const Duration(milliseconds: 500),
            () => _takePicture(),
          ),
        ),
        
        // Capture button (when needed)
        Visibility(
          visible: _isCaptureButtonVisible,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Spacer(flex: 20),
              MaterialButton(
                onPressed: () => _takePicture(),
                color: widget.config.captureButtonColor ??
                    Theme.of(context).primaryColor,
                textColor: Colors.white,
                padding: const EdgeInsets.all(16),
                shape: const CircleBorder(),
                child: const Icon(Icons.camera_alt, size: 24),
              ),
              const Spacer(),
            ],
          ),
        ),
        
        // Camera switch button
        Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 10, bottom: 10),
            child: GestureDetector(
              onTap: _switchCamera,
              child: const CircleAvatar(
                radius: 24,
                backgroundColor: Colors.black,
                child: Icon(
                  Icons.switch_camera,
                  size: 20,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// Extension method to support firstWhereOrNull if not available in your version
extension FirstWhereOrNullExtension<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final T element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}


