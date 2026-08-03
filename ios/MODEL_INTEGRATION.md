# Landmark model boundary

BlinkEngine.swift is intentionally independent of the landmark provider. It
accepts normalized eye contours, converts provider-specific contours to the
standard six-point EAR order, and applies bilateral closure, hysteresis, frame
count, and timestamp validation.

The boundary matches the output shape of MediaPipe Face Landmarker (normalized
face landmarks) and the eye-region data used by NativeSensors/EyeGestures. The
current signed target uses Apple Vision as a built-in fallback so the project
continues to build from the lightweight Xcode project without CocoaPods. Vision
feeds both eye contours into the same BlinkEngine; no clinical interpretation
is made from the frame.

The app now runs a two-second eye-detection gate, then a 30-second live-video
blink test before enabling capture. EyeStrainSignalMonitor combines blink
events, partial closures, prolonged closures, landmark coverage, and optional
self-reported comfort symptoms into a transparent visual-fatigue estimate. It
returns “insufficient camera data” when the window or tracking coverage is too
small; it does not turn a single image into a diagnosis.

To switch the provider to MediaPipe on a development machine, follow the
[official iOS setup](https://developers.google.cn/edge/mediapipe/solutions/setup_ios)
and [Face Landmarker guide](https://developers.google.cn/edge/mediapipe/solutions/vision/face_landmarker/ios),
then add MediaPipeTasksVision through CocoaPods and wire
MPImage(sampleBuffer:) and FaceLandmarker.detectAsync into the existing
CameraSession callback. The upstream iOS task library is distributed through
CocoaPods rather than Swift Package Manager. Keep the .task model local and
continue passing its normalized eye points into EyeLandmarkNormalizer. The
adapter boundary includes the 478-point eye index lists used by MediaPipe and
EyeGestures, plus a deterministic contour test.

EyeGestures is not an iOS Swift package in the referenced repository; its
FaceFinder is a Python/MediaPipe integration. Its normalization and
provider-agnostic eye contour approach are reflected here without copying its
runtime into the phone app.
