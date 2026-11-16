# Luna iOS

Open [`luna.xcodeproj`](./luna.xcodeproj) directly in Xcode. Select the `luna` scheme, choose your connected iPhone, then press Run. The target uses the unique bundle identifier `com.kiranbathala.luna` with automatic signing. The project file is the canonical entry point; the workspace is only a lightweight wrapper around it.

If Xcode is already open on an old window, use **File → Open…** and select `ios/luna.xcodeproj` again. Confirm your Apple ID/team under **Signing & Capabilities** if Xcode prompts once. The simulator can also be verified from Terminal:

```sh
xcodebuild -workspace ios/luna.xcworkspace \
  -scheme luna \
  -destination 'platform=iOS Simulator,id=77507B50-6773-491E-87FD-A21E92733ABF' \
  -configuration Debug \
  -derivedDataPath /tmp/luna-derived \
  CODE_SIGNING_ALLOWED=NO build
```

The app uses a local SwiftUI flow. The guided capture screen requests the
front-camera permission only when it begins, checks that both eyes are visible,
and runs a small normalized-landmark blink signal engine with bilateral
closure, hysteresis, and timestamp validation. It first gates on two seconds of
two-eye coverage, then runs a 30-second live-video blink test and reports a
transparent visual-fatigue estimate from the live signal and optional
self-reported symptoms. Saving “dry or gritty eyes” (or another comfort
selection) lowers that estimate, carries into the Wellness screen, and adds a
matching guidance cue. A visible frame is not a retinal image and is not a
clinical diagnosis.

Sign-in is intentionally email-only in this build. Account records, password digests, scan reports, and routines are stored locally on the device, while the active email is also kept in Keychain so the signed-in account can be restored after the app is exited. Each normalized email has its own report history and routine.

Trends keeps a local history of each saved check-in and renders a calendar plus
score trend. Manual focus tracking pauses when the app becomes inactive (for
example, when the phone locks). Wellness owns the latest test results and
comfort-adjusted score; Home stays focused on starting a scan and quick reset
exercises. Settings can match the iPhone display brightness to the latest
saved score.

Wellness percentages are transparent habits scores derived from the user-entered
routine; the camera flow does not claim to diagnose or measure eye strain. Food
cards provide general vitamin A/C nutrition education and detailed recipes, not
treatment advice. See MODEL_INTEGRATION.md and Tests/TEST_MATRIX.md for the
provider boundary and the tests that have actually been run.
