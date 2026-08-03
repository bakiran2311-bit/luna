# solace eye-signal test matrix

The deterministic tests are run from the repository root with:

    swiftc ios/solace/BlinkEngine.swift ios/Tests/BlinkEngineTestRunner.swift \
      -o /tmp/solace-blink-tests && /tmp/solace-blink-tests

## Completed locally

| Area | Test | Result |
| --- | --- | --- |
| Algorithmic accuracy | EAR calibration separates open and closed samples | PASS |
| Algorithmic accuracy | Bilateral blink versus one-eye half-blink | PASS |
| Algorithmic accuracy | Timestamp-based closed duration | PASS |
| Algorithmic accuracy | Prolonged closure is not mislabeled as a short blink | PASS |
| Algorithmic accuracy | Open-eye talking/smiling/nodding motion does not alert | PASS |
| Algorithmic accuracy | Missing/obstructed frame pauses tracking | PASS |
| Algorithmic accuracy | Scale-invariant EAR at near/far distances | PASS |
| Eye detection | Two-second gate passes with strong two-eye coverage | PASS |
| Eye detection | Weak landmark coverage is rejected | PASS |
| Assessment | Adequate observation window produces a transparent estimate | PASS |
| Assessment | Estimate explains its score and provides improvement guidance | PASS |
| Assessment | Short window remains insufficient instead of guessing | PASS |
| Assessment | Partial closures and self-reported symptoms lower the estimate | PASS |
| Assessment | Dry/gritty-eye selection lowers and explains the saved estimate | PASS |
| Functional check | Rested symptom/contrast/search profile produces zero elevated-load points | PASS |
| Functional check | Mixed symptoms and task changes produce an intermediate load | PASS |
| Functional check | High combined burden clamps safely at 100 | PASS |
| Functional check | Digit misses contribute only a bounded task-difficulty signal | PASS |
| Functional check | Wrong digit/search choices advance and record a miss | PASS |
| Functional check | Left and right eyes receive separate five-trial sections | PASS |
| Functional check | Unverifiable self-timed look-away interval is omitted | PASS |
| Functional check | Hidden-camera landmark signal contributes a bounded transparent load | PASS |
| Provider boundary | Contours with more than six points normalize into EAR points | PASS |
| Provider boundary | MediaPipe 478-point mesh selects EyeGestures eye contours | PASS |
| MediaPipe runtime | Live Face Landmarker inference on a recorded clip | NOT RUN — CocoaPods/model asset is not bundled in this lightweight target |
| Build | iOS Simulator Debug build | PASS |

These are synthetic signal tests, not a clinical validation study. The thresholds
are intentionally conservative and use bilateral closure plus hysteresis.

## Physical-device protocol

The quick check uses a 15-second hidden front-camera observation before the
left/right digit, faint-digit, and timed-search tasks. The image is never
displayed or saved. Camera signal confidence depends on landmark coverage; the remaining cases
need recorded front-camera clips or a controlled device lab;
they cannot be honestly “passed” from a simulator with no camera. Record each
case at 30 fps with the same phone, app build, and lighting note. Export the
timestamped landmark stream and compute:

* recall = true blink events detected / annotated blinks
* false positives per minute for talking, smiling, and nodding
* median landmark availability and median EAR jitter
* median event-duration error against the annotation

Run at least five clips per condition and report the median and 95th percentile:

* low light with only screen glow; bright window backlight; front-camera
  resolutions; phone below the chin and 30° off-axis
* clear lenses, thick frames, anti-reflective coating, tinted lenses
* different ages, skin tones, eye shapes, facial hair, bangs, and hand
  occlusion

Acceptance gates for this prototype are a documented measurement, not a claim
of universal accuracy: at least 90% landmark availability in the baseline
condition, no more than 2 false blink alerts per minute in the motion clips,
and duration error under 100 ms for clips with a stable frame rate. Any case
below the gate should show “signal unavailable” rather than inventing a result.

## Performance and interruption checks

On a physical iPhone, run a 60-minute capture session while recording an
Instruments Energy Log and thermal state. Capture battery percentage before and
after, CPU time, dropped frames, and ProcessInfo.processInfo.thermalState.
Repeat with the screen dimmed and undimmed. Mark a run as throttled if the
thermal state reaches .serious or .critical, or if landmark availability drops
by more than 20% from the first five minutes.

Place a phone call, lock and unlock the device, and background the app for two
minutes. The capture session listens for
AVCaptureSession.wasInterruptedNotification and
AVCaptureSession.interruptionEndedNotification; verify the live label and blink
counter resume without resetting the account data.
