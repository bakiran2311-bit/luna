import Foundation

private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func eye(ear: Double, scale: Double = 1.0) -> [EyePoint] {
    let vertical = ear / 2.0
    return [
        EyePoint(x: 0, y: 0.5 * scale),
        EyePoint(x: 0.25 * scale, y: (0.5 + vertical) * scale),
        EyePoint(x: 0.75 * scale, y: (0.5 + vertical) * scale),
        EyePoint(x: 1.0 * scale, y: 0.5 * scale),
        EyePoint(x: 0.75 * scale, y: (0.5 - vertical) * scale),
        EyePoint(x: 0.25 * scale, y: (0.5 - vertical) * scale)
    ]
}

private func send(_ engine: BlinkEngine, left: Double, right: Double, times: [TimeInterval]) -> BlinkUpdate {
    var update = engine.process(left: left == 0 ? nil : eye(ear: left), right: right == 0 ? nil : eye(ear: right), timestamp: times.first ?? 0)
    for time in times.dropFirst() {
        update = engine.process(left: left == 0 ? nil : eye(ear: left), right: right == 0 ? nil : eye(ear: right), timestamp: time)
    }
    return update
}

@main
struct BlinkEngineTestRunner {
static func main() {
print("solace blink engine tests")

// Calibration: a short bilateral closure is a blink; one closed eye is only a partial closure.
let calibration = EARCalibration.closedThreshold(openSamples: [0.34, 0.36, 0.35], closedSamples: [0.08, 0.10, 0.09])
check(calibration != nil && (calibration ?? 0) > 0.14 && (calibration ?? 1) < 0.25, "EAR calibration separates open and closed samples")

let blink = BlinkEngine()
_ = blink.process(left: eye(ear: 0.45), right: eye(ear: 0.45), timestamp: 0)
_ = blink.process(left: eye(ear: 0.10), right: eye(ear: 0.10), timestamp: 0.10)
let started = blink.process(left: eye(ear: 0.10), right: eye(ear: 0.10), timestamp: 0.14)
let completed = blink.process(left: eye(ear: 0.45), right: eye(ear: 0.45), timestamp: 0.22)
check(started.blinkStarted, "bilateral closure reaches minimum frame count")
check(completed.blinkCompleted && completed.blinkCount == 1, "blink completes after eyes reopen")

let halfBlink = BlinkEngine()
_ = halfBlink.process(left: eye(ear: 0.45), right: eye(ear: 0.45), timestamp: 0)
_ = send(halfBlink, left: 0.10, right: 0.45, times: [0.10, 0.14, 0.18, 0.22])
let halfOpen = halfBlink.process(left: eye(ear: 0.45), right: eye(ear: 0.45), timestamp: 0.30)
check(halfOpen.isPartialClosure == false && halfOpen.blinkCount == 0, "half-blink does not trigger a bilateral blink")

let durationEngine = BlinkEngine()
_ = durationEngine.process(left: eye(ear: 0.45), right: eye(ear: 0.45), timestamp: 0)
_ = durationEngine.process(left: eye(ear: 0.10), right: eye(ear: 0.10), timestamp: 1.00)
_ = durationEngine.process(left: eye(ear: 0.10), right: eye(ear: 0.10), timestamp: 1.10)
let duration = durationEngine.process(left: eye(ear: 0.45), right: eye(ear: 0.45), timestamp: 1.30)
check(abs(duration.closedDuration - 0.30) < 0.001, "timestamp duration validation measures closed-eye time")

let prolonged = BlinkEngine()
_ = prolonged.process(left: eye(ear: 0.45), right: eye(ear: 0.45), timestamp: 0)
_ = prolonged.process(left: eye(ear: 0.10), right: eye(ear: 0.10), timestamp: 0.10)
_ = prolonged.process(left: eye(ear: 0.10), right: eye(ear: 0.10), timestamp: 0.60)
let prolongedOpen = prolonged.process(left: eye(ear: 0.45), right: eye(ear: 0.45), timestamp: 1.00)
check(!prolongedOpen.blinkCompleted && prolongedOpen.blinkCount == 0, "long closure is not mislabeled as a short blink")

let falsePositiveEngine = BlinkEngine()
for frame in 0..<30 {
    let time = Double(frame) / 30.0
    // Talking, smiling, and nodding can change the face box; open-eye EAR remains open.
    let scale = 0.65 + (Double(frame % 8) * 0.08)
    _ = falsePositiveEngine.process(left: eye(ear: 0.42, scale: scale), right: eye(ear: 0.41, scale: scale), timestamp: time)
}
check(falsePositiveEngine.blinkCount == 0, "open-eye motion does not create false blink alerts")

let occluded = BlinkEngine()
_ = occluded.process(left: eye(ear: 0.45), right: eye(ear: 0.45), timestamp: 0)
_ = occluded.process(left: eye(ear: 0.10), right: eye(ear: 0.10), timestamp: 0.10)
_ = occluded.process(left: eye(ear: 0.10), right: eye(ear: 0.10), timestamp: 0.12)
let missingFrame = occluded.process(left: nil, right: nil, timestamp: 0.14)
let occludedOpen = occluded.process(left: eye(ear: 0.45), right: eye(ear: 0.45), timestamp: 0.22)
check(!missingFrame.isFaceTracked && occludedOpen.blinkCompleted, "an obstructed frame pauses tracking without inventing a result")

let baseEAR = BlinkEngine.eyeAspectRatio(eye(ear: 0.18)) ?? -1
let nearEAR = BlinkEngine.eyeAspectRatio(eye(ear: 0.18, scale: 0.4)) ?? -1
let farEAR = BlinkEngine.eyeAspectRatio(eye(ear: 0.18, scale: 2.0)) ?? -1
check(abs(baseEAR - nearEAR) < 0.0001 && abs(baseEAR - farEAR) < 0.0001, "EAR is stable when face distance changes")

let normalized = EyeLandmarkNormalizer.sixPointContour([
    EyePoint(x: 0.0, y: 0.5), EyePoint(x: 0.2, y: 0.8), EyePoint(x: 0.5, y: 0.82),
    EyePoint(x: 0.8, y: 0.5), EyePoint(x: 0.5, y: 0.18), EyePoint(x: 0.2, y: 0.2),
    EyePoint(x: 0.4, y: 0.5), EyePoint(x: 0.6, y: 0.5)
])
check(normalized != nil && (BlinkEngine.eyeAspectRatio(normalized ?? []) ?? 0) > 0, "provider contour normalizer produces EAR points")

let mesh = (0..<478).map { index in EyePoint(x: Double(index) / 478.0, y: Double(index % 31) / 31.0) }
let meshEyes = EyeLandmarkNormalizer.mediaPipeEyeContours(from: mesh)
check(meshEyes?.left.count == 16 && meshEyes?.right.count == 16, "MediaPipe 478-point mesh selects EyeGestures eye contours")

let eyeGatePass = EyeDetectionTestResult.evaluate(observedSeconds: 2.1, analyzedFrames: 60, trackedFrames: 54, bothEyesVisible: true)
let eyeGateFail = EyeDetectionTestResult.evaluate(observedSeconds: 2.1, analyzedFrames: 60, trackedFrames: 42, bothEyesVisible: true)
check(eyeGatePass.passed && eyeGatePass.trackingPercent == 90, "eye detection gate passes with strong two-eye coverage")
check(!eyeGateFail.passed && eyeGateFail.trackingPercent == 70, "eye detection gate rejects weak landmark coverage")

let baselineEngine = BlinkEngine()
var baselineMonitor = EyeStrainSignalMonitor()
for frame in 0..<300 {
    let time = Double(frame) / 30.0
    let isBlink = (frame % 60 == 20) || (frame % 60 == 21)
    let ear = isBlink ? 0.10 : 0.45
    let update = baselineEngine.process(left: eye(ear: ear), right: eye(ear: ear), timestamp: time)
    baselineMonitor.ingest(update, timestamp: time)
}
let baseline = baselineMonitor.assessment()
check(baseline.score != nil && baseline.trackingPercent == 100 && baseline.observedSeconds >= 8, "adequate landmark window produces a visual-fatigue estimate")
check(baseline.scoreMeaning.contains("/100") && !baseline.improvementTips.isEmpty, "estimate explains the score and provides improvement guidance")
check(BlinkVideoQuality.isUsable(fps: 15, assessment: baseline), "blink video quality gate accepts sufficient frame rate")
check(!BlinkVideoQuality.isUsable(fps: 8, assessment: baseline), "blink video quality gate rejects low frame rate")

let irregularEngine = BlinkEngine()
var irregularMonitor = EyeStrainSignalMonitor()
let irregularFrames: Set<Int> = [30, 31, 60, 61, 180, 181, 210, 211]
for frame in 0..<300 {
    let time = Double(frame) / 30.0
    let ear = irregularFrames.contains(frame) ? 0.10 : 0.45
    let update = irregularEngine.process(left: eye(ear: ear), right: eye(ear: ear), timestamp: time)
    irregularMonitor.ingest(update, timestamp: time)
}
let irregular = irregularMonitor.assessment()
check((irregular.blinkRhythmVariabilityPercent ?? 0) >= 55 && irregular.signals.contains("blink timing varied widely in this window"), "irregular blink intervals create a rhythm-variability signal")

var shortMonitor = EyeStrainSignalMonitor()
for frame in 0..<100 {
    let time = Double(frame) / 30.0
    let update = BlinkEngine().process(left: eye(ear: 0.45), right: eye(ear: 0.45), timestamp: time)
    shortMonitor.ingest(update, timestamp: time)
}
check(shortMonitor.assessment().score == nil, "short observation window stays insufficient instead of guessing")

let fatigueEngine = BlinkEngine()
var fatigueMonitor = EyeStrainSignalMonitor()
for frame in 0..<300 {
    let time = Double(frame) / 30.0
    let partial = frame % 6 == 0
    let update = fatigueEngine.process(left: eye(ear: partial ? 0.10 : 0.45), right: eye(ear: 0.45), timestamp: time)
    fatigueMonitor.ingest(update, timestamp: time)
}
let fatigue = fatigueMonitor.assessment(symptomCount: 2)
check(fatigue.score != nil && (fatigue.score ?? 100) < (baseline.score ?? 100) && fatigue.signals.contains("self-reported comfort symptoms"), "partial closures and symptoms lower the transparent estimate")
let dryEyeAssessment = baseline.includingSymptoms(["dry or gritty eyes"])
check(dryEyeAssessment.score == max(0, (baseline.score ?? 0) - 8), "dry or gritty eyes lowers the saved estimate")
check(dryEyeAssessment.signals.contains("self-reported: dry or gritty eyes"), "dry-eye selection remains visible in the estimate signals")
let clearedComfort = dryEyeAssessment.includingSymptoms([])
check(clearedComfort.score == baseline.score, "clearing comfort selections removes the prior symptom penalty")

let restedFunctional = FunctionalStrainEstimator.estimate(FunctionalStrainInputs(
    symptomCount: 0, severity: 0, relevantContextCount: 0,
    contrastCorrect: 6, contrastTotal: 6,
    searchCorrect: 5, searchTotal: 5,
    medianSearchMilliseconds: 700
))
check(restedFunctional == 0, "rested functional profile produces zero elevated-load points")

let mixedFunctional = FunctionalStrainEstimator.estimate(FunctionalStrainInputs(
    symptomCount: 2, severity: 3, relevantContextCount: 2,
    contrastCorrect: 4, contrastTotal: 6,
    searchCorrect: 4, searchTotal: 5,
    medianSearchMilliseconds: 1_400
))
check(mixedFunctional > restedFunctional && mixedFunctional < 75, "mixed symptoms and task changes produce an intermediate load")

let elevatedFunctional = FunctionalStrainEstimator.estimate(FunctionalStrainInputs(
    symptomCount: 5, severity: 5, relevantContextCount: 4,
    contrastCorrect: 0, contrastTotal: 6,
    searchCorrect: 0, searchTotal: 5,
    medianSearchMilliseconds: 4_000,
    cameraSignalLoad: 20,
    clarityCorrect: 0, clarityTotal: 10
))
check(elevatedFunctional == 100, "high symptom and task burden clamps the estimate to 100")

let allWrongTasks = FunctionalStrainEstimator.estimate(FunctionalStrainInputs(
    symptomCount: 0, severity: 0, relevantContextCount: 0,
    contrastCorrect: 0, contrastTotal: 4,
    searchCorrect: 0, searchTotal: 3,
    medianSearchMilliseconds: 700,
    clarityCorrect: 0, clarityTotal: 10
))
check(allWrongTasks >= 75, "all-wrong visual tasks reach the high-load band")

let fullClarityInput = FunctionalStrainEstimator.estimate(FunctionalStrainInputs(
    symptomCount: 0, severity: 0, relevantContextCount: 0,
    contrastCorrect: 6, contrastTotal: 6,
    searchCorrect: 5, searchTotal: 5,
    medianSearchMilliseconds: 700
))
check(fullClarityInput == restedFunctional, "full digit recognition adds no task-difficulty load")

let reducedClarityInput = FunctionalStrainEstimator.estimate(FunctionalStrainInputs(
    symptomCount: 0, severity: 0, relevantContextCount: 0,
    contrastCorrect: 6, contrastTotal: 6,
    searchCorrect: 5, searchTotal: 5,
    medianSearchMilliseconds: 700,
    clarityCorrect: 4, clarityTotal: 10
))
check(reducedClarityInput == 15, "digit misses contribute a bounded task-difficulty load")

let hiddenCameraFunctional = FunctionalStrainEstimator.estimate(FunctionalStrainInputs(
    symptomCount: 0, severity: 0, relevantContextCount: 0,
    contrastCorrect: 6, contrastTotal: 6,
    searchCorrect: 5, searchTotal: 5,
    medianSearchMilliseconds: 700,
    cameraSignalLoad: 12
))
check(hiddenCameraFunctional == 12, "hidden-camera signal contributes its bounded transparent load")

print("\nDeterministic algorithm tests: \(failures == 0 ? "PASS" : "FAIL")")
exit(failures == 0 ? 0 : 1)
}
}
