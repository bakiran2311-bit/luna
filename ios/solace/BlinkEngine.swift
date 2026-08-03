import Foundation

struct FunctionalStrainInputs: Equatable {
    let symptomCount: Int
    let severity: Int
    let relevantContextCount: Int
    let contrastCorrect: Int
    let contrastTotal: Int
    let searchCorrect: Int
    let searchTotal: Int
    let medianSearchMilliseconds: Int
    var cameraSignalLoad: Int = 0
    var clarityCorrect: Int = 10
    var clarityTotal: Int = 10
}

struct FunctionalStrainBreakdown: Equatable {
    let symptom: Int
    let context: Int
    let clarity: Int
    let contrast: Int
    let search: Int
    let latency: Int
    let camera: Int

    var taskLoad: Int { clarity + contrast + search + latency }
    var comfortLoad: Int { symptom + context }
    var total: Int {
        min(100, symptom + context + clarity + contrast + search + latency + camera)
    }
}

enum FunctionalStrainEstimator {
    /// Transparent weighting for a repeatable comfort/load estimate. Missed
    /// visual tasks carry most of the task load, so an all-wrong run cannot
    /// remain in the middle of the scale.
    static func estimate(_ input: FunctionalStrainInputs) -> Int {
        breakdown(input).total
    }

    static func breakdown(_ input: FunctionalStrainInputs) -> FunctionalStrainBreakdown {
        let symptomComponent = min(30, max(0, input.symptomCount) * 4 + min(5, max(0, input.severity)) * 3)
        let contextComponent = min(10, Int((Double(max(0, input.relevantContextCount)) / 4.0 * 10.0).rounded()))
        let safeContrastTotal = max(1, input.contrastTotal)
        let contrastMisses = max(0, safeContrastTotal - min(safeContrastTotal, max(0, input.contrastCorrect)))
        let contrastComponent = Int((Double(contrastMisses) / Double(safeContrastTotal) * 25.0).rounded())
        let safeSearchTotal = max(1, input.searchTotal)
        let searchMisses = max(0, safeSearchTotal - min(safeSearchTotal, max(0, input.searchCorrect)))
        let searchMissComponent = Int((Double(searchMisses) / Double(safeSearchTotal) * 25.0).rounded())
        let latencyComponent = min(10, max(0, input.medianSearchMilliseconds - 900) / 250)
        let cameraComponent = min(20, max(0, input.cameraSignalLoad))
        let safeClarityTotal = max(1, input.clarityTotal)
        let clarityMisses = max(0, safeClarityTotal - min(safeClarityTotal, max(0, input.clarityCorrect)))
        let clarityComponent = Int((Double(clarityMisses) / Double(safeClarityTotal) * 25.0).rounded())
        return FunctionalStrainBreakdown(
            symptom: symptomComponent,
            context: contextComponent,
            clarity: clarityComponent,
            contrast: contrastComponent,
            search: searchMissComponent,
            latency: latencyComponent,
            camera: cameraComponent
        )
    }
}

/// A small, dependency-free blink signal layer.
///
/// MediaPipe Face Landmarker and other providers expose normalized eye
/// landmarks.  This type deliberately accepts only those landmarks, so the
/// app can swap providers without changing blink calibration or persistence.
struct EyePoint: Equatable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }
}

struct BlinkEngineConfiguration: Equatable {
    var closedEARThreshold: Double = 0.20
    var openEARThreshold: Double = 0.245
    var minimumClosedFrames: Int = 2
    var minimumBlinkDuration: TimeInterval = 0.045
    var maximumBlinkDuration: TimeInterval = 0.80
}

struct BlinkUpdate: Equatable {
    let leftEAR: Double?
    let rightEAR: Double?
    let meanEAR: Double?
    let isFaceTracked: Bool
    let isClosed: Bool
    let isPartialClosure: Bool
    let blinkStarted: Bool
    let blinkCompleted: Bool
    let closedDuration: TimeInterval
    let closedFrames: Int
    let blinkCount: Int
}

struct EyeStrainAssessment: Codable, Equatable {
    var score: Int?
    var label: String
    let dataStatus: String
    let observedSeconds: Double
    let trackingPercent: Int
    let blinkRatePerMinute: Double?
    var blinkRhythmVariabilityPercent: Int? = nil
    let prolongedClosureSeconds: Double
    let partialClosurePercent: Int
    var symptomCount: Int
    var signals: [String]

    var scoreMeaning: String {
        guard let score else { return "The test did not collect enough stable eye data to explain a score yet." }
        if score >= 75 {
            return "This is an eye-strain signal score, not visual acuity. \(score)/100 means this window showed relatively few elevated strain signals. Keep the habits that produced this result."
        }
        if score >= 50 {
            return "This is an eye-strain signal score, not visual acuity. \(score)/100 means the window showed some strain signals. Shorter uninterrupted screen blocks and deliberate full blinks are the first changes to try."
        }
        return "This is an eye-strain signal score, not visual acuity. \(score)/100 means several strain signals appeared in this window. Take a longer distance break, reduce glare, and repeat the check when your eyes feel comfortable."
    }

    var improvementTips: [String] {
        guard score != nil else { return ["Repeat the check with both eyes visible and steady lighting."] }
        var tips: [String] = []
        if blinkRatePerMinute.map({ $0 < 8 }) == true {
            tips.append("Add deliberate, complete blinks during near-screen work.")
        }
        if partialClosurePercent >= 15 {
            tips.append("Relax your eyelids and take a distance look; incomplete closures were common in this window.")
        }
        if prolongedClosureSeconds > 0.80 {
            tips.append("Pause after prolonged closure events and return to the screen only when your eyes feel comfortable.")
        }
        if trackingPercent < 85 {
            tips.append("Repeat in even light with the phone at eye level so the landmarks stay stable.")
        }
        if symptomCount > 0 {
            tips.append("Use the comfort symptoms you selected to guide your next break.")
        }
        if tips.isEmpty {
            tips.append("Keep the phone at a comfortable distance and use regular distance breaks during long near-work sessions.")
        }
        return tips
    }

    static let insufficient = EyeStrainAssessment(
        score: nil,
        label: "insufficient camera data",
        dataStatus: "insufficient",
        observedSeconds: 0,
        trackingPercent: 0,
        blinkRatePerMinute: nil,
        prolongedClosureSeconds: 0,
        partialClosurePercent: 0,
        symptomCount: 0,
        signals: ["Keep both eyes visible for a longer observation window."]
    )

    func includingSymptoms(_ count: Int) -> EyeStrainAssessment {
        var copy = self
        copy.symptomCount = count
        guard let currentScore = score else { return copy }
        let previousPenalty = min(25, symptomCount * 8)
        let scoreBeforeSymptoms = min(100, currentScore + previousPenalty)
        let newScore = max(0, scoreBeforeSymptoms - min(25, count * 8))
        copy.score = newScore
        var updatedSignals = signals.filter { $0 != "self-reported comfort symptoms" }
        if count > 0 { updatedSignals.append("self-reported comfort symptoms") }
        copy.signals = updatedSignals.isEmpty ? ["no elevated camera signals in this window"] : updatedSignals
        copy.label = newScore >= 75 ? "low visual-fatigue signal" : (newScore >= 50 ? "moderate visual-fatigue signal" : "elevated visual-fatigue signal")
        return copy
    }

    /// Applies the user's actual comfort selections to the estimate. The
    /// score uses the same capped symptom penalty as the count-only API, while
    /// retaining the selected labels so wellness guidance can explain why it
    /// changed (for example, dry or gritty eyes).
    func includingSymptoms(_ symptoms: [String]) -> EyeStrainAssessment {
        var copy = self
        let cleaned = symptoms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        copy.symptomCount = cleaned.count
        guard let currentScore = score else { return copy }

        // Remove the prior symptom penalty before applying the current set so
        // saving the comfort check again does not compound the deduction.
        let previousPenalty = min(25, symptomCount * 8)
        let scoreBeforeSymptoms = min(100, currentScore + previousPenalty)
        let newScore = max(0, scoreBeforeSymptoms - min(25, cleaned.count * 8))
        copy.score = newScore

        var updatedSignals = signals.filter {
            $0 != "self-reported comfort symptoms" && !$0.hasPrefix("self-reported: ")
        }
        if !cleaned.isEmpty {
            updatedSignals.append("self-reported comfort symptoms")
            updatedSignals.append(contentsOf: cleaned.map { "self-reported: \($0)" })
        }
        copy.signals = updatedSignals.isEmpty ? ["no elevated camera signals in this window"] : updatedSignals
        copy.label = newScore >= 75 ? "low visual-fatigue signal" : (newScore >= 50 ? "moderate visual-fatigue signal" : "elevated visual-fatigue signal")
        return copy
    }
}

struct EyeDetectionTestResult: Equatable {
    let passed: Bool
    let observedSeconds: Double
    let analyzedFrames: Int
    let trackedFrames: Int
    let trackingPercent: Int
    let reason: String

    static func evaluate(
        observedSeconds: Double,
        analyzedFrames: Int,
        trackedFrames: Int,
        bothEyesVisible: Bool,
        minimumSeconds: Double = 2,
        minimumTrackingPercent: Int = 85
    ) -> EyeDetectionTestResult {
        let trackingPercent = analyzedFrames == 0 ? 0 : Int((Double(trackedFrames) / Double(analyzedFrames) * 100).rounded())
        let passed = observedSeconds >= minimumSeconds
            && analyzedFrames >= 20
            && trackingPercent >= minimumTrackingPercent
            && bothEyesVisible
        let reason: String
        if passed {
            reason = "both eyes tracked"
        } else if observedSeconds < minimumSeconds {
            reason = "keep still while the eye check runs"
        } else if !bothEyesVisible {
            reason = "both eyes were not visible in the final frames"
        } else {
            reason = "tracking coverage was \(trackingPercent)%"
        }
        return EyeDetectionTestResult(
            passed: passed,
            observedSeconds: observedSeconds,
            analyzedFrames: analyzedFrames,
            trackedFrames: trackedFrames,
            trackingPercent: trackingPercent,
            reason: reason
        )
    }
}

enum BlinkVideoQuality {
    static func isUsable(fps: Double, assessment: EyeStrainAssessment) -> Bool {
        fps >= 12 && assessment.score != nil
    }
}

/// Converts the observable camera stream into a wellness signal. This is not a
/// clinical eye-strain test: it requires enough time and tracking coverage,
/// then reports the inputs used so the result is auditable.
struct EyeStrainSignalMonitor {
    let minimumObservationSeconds: TimeInterval = 8
    private(set) var firstTimestamp: TimeInterval?
    private(set) var lastTimestamp: TimeInterval?
    private(set) var frameCount = 0
    private(set) var trackedFrameCount = 0
    private(set) var partialFrameCount = 0
    private(set) var blinkTimestamps: [TimeInterval] = []
    private(set) var maximumClosedDuration: TimeInterval = 0

    var observedSeconds: TimeInterval {
        guard let firstTimestamp, let lastTimestamp else { return 0 }
        return max(0, lastTimestamp - firstTimestamp)
    }

    var trackingPercent: Int {
        guard frameCount > 0 else { return 0 }
        return Int((Double(trackedFrameCount) / Double(frameCount) * 100).rounded())
    }

    var progress: Double {
        min(1, observedSeconds / minimumObservationSeconds)
    }

    mutating func reset() {
        firstTimestamp = nil
        lastTimestamp = nil
        frameCount = 0
        trackedFrameCount = 0
        partialFrameCount = 0
        blinkTimestamps = []
        maximumClosedDuration = 0
    }

    mutating func ingest(_ update: BlinkUpdate, timestamp: TimeInterval) {
        if firstTimestamp == nil { firstTimestamp = timestamp }
        lastTimestamp = timestamp
        frameCount += 1
        if update.isFaceTracked { trackedFrameCount += 1 }
        if update.isPartialClosure { partialFrameCount += 1 }
        if update.blinkCompleted { blinkTimestamps.append(timestamp) }
        maximumClosedDuration = max(maximumClosedDuration, update.closedDuration)
    }

    func assessment(symptomCount: Int = 0) -> EyeStrainAssessment {
        let duration = observedSeconds
        let tracking = trackingPercent
        let partialPercent = frameCount == 0 ? 0 : Int((Double(partialFrameCount) / Double(frameCount) * 100).rounded())
        guard duration >= minimumObservationSeconds, tracking >= 65, frameCount >= 20 else {
            return EyeStrainAssessment(
                score: nil,
                label: "insufficient camera data",
                dataStatus: "insufficient",
                observedSeconds: duration,
                trackingPercent: tracking,
                blinkRatePerMinute: nil,
                prolongedClosureSeconds: maximumClosedDuration,
                partialClosurePercent: partialPercent,
                symptomCount: symptomCount,
                signals: ["Keep both eyes visible for at least \(Int(minimumObservationSeconds)) seconds."]
            )
        }

        let blinkRate = Double(blinkTimestamps.count) / duration * 60
        let intervals = zip(blinkTimestamps.dropFirst(), blinkTimestamps).map { $0 - $1 }
        let rhythmVariability: Int?
        if intervals.count >= 2 {
            let mean = intervals.reduce(0, +) / Double(intervals.count)
            let variance = intervals.map { pow($0 - mean, 2) }.reduce(0, +) / Double(intervals.count)
            rhythmVariability = mean > 0 ? Int((sqrt(variance) / mean * 100).rounded()) : nil
        } else {
            rhythmVariability = nil
        }
        var score = 100
        var signals: [String] = []
        if blinkRate < 8 {
            score -= 20
            signals.append("fewer blink events in this observation window")
        }
        if blinkRate < 5 {
            score -= 10
        }
        if partialPercent >= 15 {
            score -= 15
            signals.append("frequent one-eye or partial closures")
        }
        if rhythmVariability.map({ $0 >= 55 }) == true {
            score -= 10
            signals.append("blink timing varied widely in this window")
        }
        if maximumClosedDuration > 0.80 {
            score -= 15
            signals.append("a prolonged eye-closure episode")
        }
        if tracking < 85 {
            score -= 15
            signals.append("landmark coverage was intermittent")
        }
        if symptomCount > 0 {
            score -= min(25, symptomCount * 8)
            signals.append("self-reported comfort symptoms")
        }

        let clamped = max(0, min(100, score))
        let label: String
        if clamped >= 75 {
            label = "low visual-fatigue signal"
        } else if clamped >= 50 {
            label = "moderate visual-fatigue signal"
        } else {
            label = "elevated visual-fatigue signal"
        }
        if signals.isEmpty {
            signals.append("no elevated camera signals in this window")
        }

        return EyeStrainAssessment(
            score: clamped,
            label: label,
            dataStatus: "estimated",
            observedSeconds: duration,
            trackingPercent: tracking,
            blinkRatePerMinute: blinkRate,
            blinkRhythmVariabilityPercent: rhythmVariability,
            prolongedClosureSeconds: maximumClosedDuration,
            partialClosurePercent: partialPercent,
            symptomCount: symptomCount,
            signals: signals
        )
    }
}

enum EARCalibration {
    /// Computes a conservative threshold between open- and closed-eye samples.
    /// Clamping keeps a noisy calibration from making every frame look closed.
    static func closedThreshold(openSamples: [Double], closedSamples: [Double]) -> Double? {
        guard !openSamples.isEmpty, !closedSamples.isEmpty else { return nil }
        let open = median(openSamples)
        let closed = median(closedSamples)
        guard open > closed else { return nil }
        return min(0.25, max(0.14, (open + closed) / 2.0))
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2.0
        }
        return sorted[middle]
    }
}

final class BlinkEngine {
    let configuration: BlinkEngineConfiguration
    private(set) var blinkCount = 0
    private var closedSince: TimeInterval?
    private var closedFrames = 0
    private var isInClosedState = false

    init(configuration: BlinkEngineConfiguration = BlinkEngineConfiguration()) {
        self.configuration = configuration
    }

    func reset() {
        blinkCount = 0
        closedSince = nil
        closedFrames = 0
        isInClosedState = false
    }

    func process(left: [EyePoint]?, right: [EyePoint]?, timestamp: TimeInterval) -> BlinkUpdate {
        let leftEAR = left.flatMap(Self.eyeAspectRatio)
        let rightEAR = right.flatMap(Self.eyeAspectRatio)
        return process(leftEAR: leftEAR, rightEAR: rightEAR, timestamp: timestamp)
    }

    func process(leftEAR: Double?, rightEAR: Double?, timestamp: TimeInterval) -> BlinkUpdate {
        let values = [leftEAR, rightEAR].compactMap { $0 }
        let meanEAR = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        let tracked = leftEAR != nil && rightEAR != nil
        let leftClosed = (leftEAR ?? 1.0) < configuration.closedEARThreshold
        let rightClosed = (rightEAR ?? 1.0) < configuration.closedEARThreshold
        let bilateralClosed: Bool
        if isInClosedState {
            // Hysteresis: once closed, require the higher open threshold to
            // be crossed before ending the closure.
            bilateralClosed = tracked
                && (leftEAR ?? 1.0) < configuration.openEARThreshold
                && (rightEAR ?? 1.0) < configuration.openEARThreshold
        } else {
            bilateralClosed = tracked && leftClosed && rightClosed
        }
        let partial = tracked && leftClosed != rightClosed
        var started = false
        var completed = false
        var duration: TimeInterval = 0

        if !tracked {
            duration = max(0, timestamp - (closedSince ?? timestamp))
            return BlinkUpdate(
                leftEAR: leftEAR,
                rightEAR: rightEAR,
                meanEAR: meanEAR,
                isFaceTracked: false,
                isClosed: isInClosedState,
                isPartialClosure: false,
                blinkStarted: false,
                blinkCompleted: false,
                closedDuration: duration,
                closedFrames: closedFrames,
                blinkCount: blinkCount
            )
        } else if bilateralClosed {
            isInClosedState = true
            if closedSince == nil { closedSince = timestamp; closedFrames = 0 }
            closedFrames += 1
            duration = max(0, timestamp - (closedSince ?? timestamp))
            started = closedFrames == configuration.minimumClosedFrames
        } else {
            if let start = closedSince {
                duration = max(0, timestamp - start)
                completed = closedFrames >= configuration.minimumClosedFrames
                    && duration >= configuration.minimumBlinkDuration
                    && duration <= configuration.maximumBlinkDuration
                if completed { blinkCount += 1 }
            }
            closedSince = nil
            closedFrames = 0
            isInClosedState = false
        }

        return BlinkUpdate(
            leftEAR: leftEAR,
            rightEAR: rightEAR,
            meanEAR: meanEAR,
            isFaceTracked: tracked,
            isClosed: bilateralClosed,
            isPartialClosure: partial,
            blinkStarted: started,
            blinkCompleted: completed,
            closedDuration: duration,
            closedFrames: closedFrames,
            blinkCount: blinkCount
        )
    }

    /// Standard six-point EAR: [left corner, upper-left, upper-right,
    /// right corner, lower-right, lower-left].
    static func eyeAspectRatio(_ points: [EyePoint]) -> Double? {
        guard points.count >= 6 else { return nil }
        let horizontal = distance(points[0], points[3])
        guard horizontal > 0 else { return nil }
        return (distance(points[1], points[5]) + distance(points[2], points[4])) / (2 * horizontal)
    }

    private static func distance(_ a: EyePoint, _ b: EyePoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// Vision and MediaPipe return a contour with a provider-specific number and
/// order of points. This converts either contour into the six-point EAR order.
enum EyeLandmarkNormalizer {
    // FaceLandmarksConnections indices used by MediaPipe Face Landmarker and
    // the referenced EyeGestures project. They are kept here so a MediaPipe
    // adapter can pass the 478-point face mesh straight into this engine.
    static let mediaPipeLeftEyeIndices = [263, 249, 390, 373, 374, 380, 381, 382, 362, 466, 388, 387, 386, 385, 384, 398]
    static let mediaPipeRightEyeIndices = [33, 7, 163, 144, 145, 153, 154, 155, 133, 246, 161, 160, 159, 158, 157, 173]

    static func mediaPipeEyeContours(from landmarks: [EyePoint]) -> (left: [EyePoint], right: [EyePoint])? {
        guard mediaPipeLeftEyeIndices.allSatisfy({ $0 < landmarks.count }),
              mediaPipeRightEyeIndices.allSatisfy({ $0 < landmarks.count }) else { return nil }
        return (
            mediaPipeLeftEyeIndices.map { landmarks[$0] },
            mediaPipeRightEyeIndices.map { landmarks[$0] }
        )
    }

    static func sixPointContour(_ points: [EyePoint]) -> [EyePoint]? {
        guard points.count >= 6 else { return nil }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else { return nil }
        let midpointY = (minY + maxY) / 2
        let left = nearest(points, x: minX, y: midpointY)
        let right = nearest(points, x: maxX, y: midpointY)
        let upperLeft = nearest(points, x: minX + width * 0.30, y: minY)
        let upperRight = nearest(points, x: maxX - width * 0.30, y: minY)
        let lowerRight = nearest(points, x: maxX - width * 0.30, y: maxY)
        let lowerLeft = nearest(points, x: minX + width * 0.30, y: maxY)
        return [left, upperLeft, upperRight, right, lowerRight, lowerLeft]
    }

    private static func nearest(_ points: [EyePoint], x: Double, y: Double) -> EyePoint {
        points.min { lhs, rhs in
            let leftDistance = hypot(lhs.x - x, lhs.y - y)
            let rightDistance = hypot(rhs.x - x, rhs.y - y)
            return leftDistance < rightDistance
        } ?? EyePoint(x: x, y: y)
    }
}
