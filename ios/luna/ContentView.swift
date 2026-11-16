import AVFoundation
import Combine
import SwiftUI
import UIKit
import UserNotifications
import Vision

private let reportNotice = "This pattern combines your check-in responses with the on-device function checks you completed."

enum EyeSide: String {
    case left, right
}

enum LunaRoute {
    case splash, auth, home, checkin, report, rhythm, wellness, breathing, settings
}

@MainActor
final class FocusSessionManager: ObservableObject {
    @Published private(set) var isArmed = false
    @Published private(set) var countdown = 0
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var status = "ready for a screen-off session"
    @Published private(set) var lastCompletedMinutes = 0
    @Published private(set) var completionToken = UUID()

    private let defaults = UserDefaults.standard
    private let armedKey = "luna.focus.armed"
    private let lockedKey = "luna.focus.locked"
    private let plannedStartKey = "luna.focus.plannedStart"
    private let originalBrightnessKey = "luna.focus.originalBrightness"
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        isArmed = defaults.bool(forKey: armedKey)
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.phoneDidLock() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.phoneDidUnlock() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.phoneDidUnlock() }
        })
        if isArmed { resumeTicker() }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isArmed, self.defaults.bool(forKey: self.lockedKey), UIApplication.shared.isProtectedDataAvailable else { return }
            self.finish(reason: "phone unlocked")
        }
    }

    deinit {
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func begin() {
        guard !isArmed else { return }
        let screen = activeScreen()
        defaults.set(Double(screen.brightness), forKey: originalBrightnessKey)
        screen.brightness = 0.34
        defaults.set(true, forKey: "luna.warmFocusActive")
        defaults.set(true, forKey: armedKey)
        defaults.set(false, forKey: lockedKey)
        defaults.set(Date().addingTimeInterval(5).timeIntervalSince1970, forKey: plannedStartKey)
        isArmed = true
        status = "turn off the phone · timer starts in 5"
        requestNotificationPermission()
        resumeTicker()
    }

    func endManually() {
        guard isArmed else { return }
        finish(reason: "ended manually")
    }

    private func phoneDidLock() {
        guard isArmed else { return }
        defaults.set(true, forKey: lockedKey)
        status = "screen off · focus timer running"
    }

    private func phoneDidUnlock() {
        guard isArmed, defaults.bool(forKey: lockedKey) else { return }
        finish(reason: "phone unlocked")
    }

    private func finish(reason: String) {
        let planned = Date(timeIntervalSince1970: defaults.double(forKey: plannedStartKey))
        let seconds = max(0, Int(Date().timeIntervalSince(planned)))
        lastCompletedMinutes = seconds / 60
        elapsedSeconds = seconds
        isArmed = false
        countdown = 0
        status = "paused · \(time(seconds)) screen-free"
        timer?.invalidate()
        timer = nil
        defaults.set(false, forKey: armedKey)
        defaults.set(false, forKey: lockedKey)
        defaults.set(false, forKey: "luna.warmFocusActive")
        activeScreen().brightness = CGFloat(defaults.double(forKey: originalBrightnessKey))
        completionToken = UUID()
        sendPausedNotification(reason: reason, seconds: seconds)
    }

    private func resumeTicker() {
        timer?.invalidate()
        updateTime()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTime() }
        }
    }

    private func updateTime() {
        guard isArmed else { return }
        let planned = Date(timeIntervalSince1970: defaults.double(forKey: plannedStartKey))
        let remaining = Int(ceil(planned.timeIntervalSinceNow))
        countdown = max(0, remaining)
        elapsedSeconds = max(0, Int(Date().timeIntervalSince(planned)))
        if remaining > 0 {
            status = "turn off the phone · timer starts in \(remaining)"
        } else if !defaults.bool(forKey: lockedKey) {
            status = "timer ready · lock the phone now"
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendPausedNotification(reason: String, seconds: Int) {
        let content = UNMutableNotificationContent()
        content.title = "focus timer paused"
        content.body = "\(reason.capitalized) · \(time(seconds)) screen-free recorded."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "luna.focus.paused.\(UUID().uuidString)", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    private func activeScreen() -> UIScreen {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first ?? UIScreen.main
    }

    private func time(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct ContentView: View {
    @StateObject private var store = AccountStore()
    @StateObject private var focusSession = FocusSessionManager()
    @State private var route: LunaRoute = .splash
    @State private var contrast = false
    @AppStorage("luna.fontStyle") private var fontStyle = LunaFontStyle.mono.rawValue
    @AppStorage("luna.warmFocusActive") private var warmFocusActive = false

    var body: some View {
        ZStack {
            RetroGridBackground().ignoresSafeArea()
            Group {
                switch route {
                case .splash:
                    SplashView { route = store.activeAccount == nil || store.requiresDailySignIn ? .auth : .home }
                case .auth:
                    AuthView(store: store) { route = .home }
                case .home:
                    HomeView(store: store) { route = .checkin }
                case .checkin:
                    SafetyCheckInView { report in
                        store.updateReport(report)
                        route = .report
                    } back: {
                        route = .home
                    }
                case .report:
                    SafetySummaryView(report: store.activeAccount?.report, wellness: { route = .wellness })
                case .rhythm:
                    BlinkRhythmView(store: store)
                case .wellness:
                    WellnessView(store: store, focusSession: focusSession) { route = .breathing }
                case .breathing:
                    BreathingLabView(back: { route = .wellness }) { minutes in
                        store.logBreathingMinutes(minutes)
                    }
                case .settings:
                    SettingsView(store: store, contrast: $contrast) {
                        store.signOut()
                        route = .auth
                    }
                }
            }
        }
        .overlay {
            if warmFocusActive {
                Color.orange.opacity(0.075).blendMode(.multiply).ignoresSafeArea().allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.light)
        .environment(\.sizeCategory, .large)
        .environment(\.font, LunaFontStyle(rawValue: fontStyle)?.baseFont ?? LunaFontStyle.mono.baseFont)
        .animation(.snappy(duration: 0.24), value: routeKey)
        .onChange(of: focusSession.completionToken) { _, _ in
            store.addScreenFreeMinutes(focusSession.lastCompletedMinutes)
        }
        .safeAreaInset(edge: .bottom) {
            if [.home, .report, .rhythm, .wellness, .settings].contains(route) {
                LunaNav(route: $route)
            }
        }
    }

    private var routeKey: String { String(describing: route) }
}

// MARK: - Safety console entry

struct SplashView: View {
    let enter: () -> Void

    var body: some View {
        ZStack {
            RetroGridBackground().ignoresSafeArea()
            VStack(spacing: 18) {
                HStack {
                    Text("LUNA SAFETY SYSTEM")
                    Spacer()
                    Text("v2.0")
                }
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .foregroundStyle(Color.lunaPaper)
                .background(Color.lunaInk)

                VStack(spacing: 14) {
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 58, weight: .black))
                        .foregroundStyle(Color.lunaInk)
                        .frame(width: 126, height: 112)
                        .background(Color.lunaSignal)
                        .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 3))
                        .offset(x: -3, y: -3)
                        .background(Rectangle().fill(Color.lunaInk).offset(x: 6, y: 6))
                    Text("LUNA")
                        .font(.system(size: 40, weight: .black, design: .monospaced))
                        .tracking(-2)
                    EncryptedTextReveal(text: "EYE SAFETY DESK // READY")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.lunaBlue)
                    HStack(spacing: 7) {
                        Rectangle().fill(Color.lunaSafe).frame(width: 10, height: 10)
                        Text("LOCAL DATA ONLINE")
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(Color.lunaPaper)
                .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 3))
                .background(Rectangle().fill(Color.lunaInk).offset(x: 7, y: 7))

                BlackButton(title: "ENTER SYSTEM", icon: "arrow.right") { enter() }
            }
            .padding(22)
        }
    }
}

/// SwiftUI adaptation of the attached EncryptedText interaction. Characters
/// begin as a muted stream of symbols and resolve left-to-right into the real
/// copy, keeping the native app dependency-free.
struct EncryptedTextReveal: View {
    let text: String
    var encryptedClassColor: Color = .secondary
    var revealedClassColor: Color = .primary
    var revealDelayMs: Int = 50
    @State private var revealedCount = 0

    private let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789#$%&")

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08)) { timeline in
            let seed = Int(timeline.date.timeIntervalSinceReferenceDate * 12)
            Text(rendered(seed: seed))
                .foregroundStyle(revealedCount >= text.count ? revealedClassColor : encryptedClassColor)
                .animation(.easeOut(duration: 0.16), value: revealedCount)
        }
        .onAppear { revealNext() }
    }

    private func rendered(seed: Int) -> String {
        let characters = Array(text)
        return characters.enumerated().map { index, character in
            guard index >= revealedCount, character != " " else { return String(character) }
            let slot = abs(seed + (index * 17)) % alphabet.count
            return String(alphabet[slot])
        }.joined()
    }

    private func revealNext() {
        guard revealedCount < text.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(revealDelayMs)) {
            revealedCount += 1
            revealNext()
        }
    }
}

struct LiquidEtherRing: View {
    let isActive: Bool
    private let colors: [Color] = [.lunaInk, .lunaBrown, .lunaClay, .lunaInk]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let intensity = isActive ? 1.35 : 0.85
                for index in 0..<colors.count {
                    let phase = t * (0.8 + Double(index) * 0.12) + Double(index) * 1.6
                    let radius = size.width * (0.31 + CGFloat(index) * 0.018)
                    var path = Path()
                    for pointIndex in 0..<14 {
                        let angle = (Double(pointIndex) / 14.0) * Double.pi * 2
                        let wobble = 1 + 0.13 * sin(phase + angle * 3.0) + 0.07 * cos(phase * 0.7 + angle * 5.0)
                        let point = CGPoint(x: center.x + cos(angle) * radius * wobble, y: center.y + sin(angle) * radius * wobble)
                        if pointIndex == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    path.closeSubpath()
                    context.fill(path, with: .color(colors[index].opacity(0.15 * intensity)))
                }
            }
            .blur(radius: isActive ? 1.2 : 2.8)
            .scaleEffect(isActive ? 1.06 : 1.0)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Auth

enum AuthMode { case signIn, signUp }

struct AuthView: View {
    @ObservedObject var store: AccountStore
    let signedIn: () -> Void

    @State private var mode: AuthMode = .signIn
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var showingPassword = false
    @State private var alertMessage: String?

    init(store: AccountStore, signedIn: @escaping () -> Void) {
        self.store = store
        self.signedIn = signedIn
        _email = State(initialValue: store.activeAccount?.email ?? "")
    }
    private var valid: Bool {
        let emailValid = email.contains("@") && email.contains(".")
        if mode == .signUp {
            return !name.trimmingCharacters(in: .whitespaces).isEmpty && emailValid && password.count >= 8 && password == confirm
        }
        return emailValid && !password.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Brand(foreground: .primary, showIcon: false)
                HStack(spacing: 6) {
                    AuthModeButton(title: "sign in", active: mode == .signIn) { mode = .signIn }
                    AuthModeButton(title: "sign up", active: mode == .signUp) { mode = .signUp }
                }
                .padding(5)
                .liquidGlass(0)
                .padding(.top, 20)

                Text(mode == .signIn ? "welcome back" : "create your account")
                    .font(.system(size: 30, weight: .black, design: .monospaced))
                    .padding(.top, 12)
                Text("Sign in once each day. Your saved comfort history stays on this device.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)

                if mode == .signUp { TextField("full name", text: $name).field() }
                TextField("email address", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .field()
                Group {
                    if showingPassword {
                        TextField("password", text: $password)
                    } else {
                        SecureField("password", text: $password)
                    }
                }
                .field()
                if mode == .signUp {
                    Group {
                        if showingPassword {
                            TextField("confirm password", text: $confirm)
                        } else {
                            SecureField("confirm password", text: $confirm)
                        }
                    }
                    .field()
                    PasswordMeter(password: password)
                }
                Button(showingPassword ? "hide password" : "show password") { showingPassword.toggle() }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)

                BlackButton(title: mode == .signIn ? "sign in" : "create account", action: submit, disabled: !valid)
            }
            .frame(maxWidth: 430)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .alert("luna", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("ok") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func submit() {
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if mode == .signIn {
            guard let account = store.account(for: cleanEmail) else {
                alertMessage = "No account exists for this email. Switch to sign up to create one."
                return
            }
            guard store.passwordMatches(password, for: cleanEmail) else {
                alertMessage = "That password does not match this account."
                return
            }
            store.activate(account)
            store.markSignedIn(for: cleanEmail)
            signedIn()
        } else {
            guard store.account(for: cleanEmail) == nil else {
                alertMessage = "An account already exists for this email. Switch to sign in."
                return
            }
            let account = LunaAccount(email: cleanEmail, name: name, provider: "email", passwordDigest: AccountStore.digest(password), verified: true, report: nil, schedule: nil)
            store.activate(account)
            // Keep the account and its empty data, then return to the sign-in
            // form so the next entry is an explicit login rather than an
            // automatic jump into the product.
            mode = .signIn
            password = ""
            confirm = ""
            alertMessage = "Account created. Sign in to continue; your future comfort logs will stay with this account."
        }
    }

}

struct AuthModeButton: View {
    let title: String
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(active ? .white : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(active ? Color.lunaInk : .clear)
            .clipShape(Rectangle())
            .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: active ? 0 : 1))
            .buttonStyle(LunaPressStyle())
    }
}

struct PasswordMeter: View {
    let password: String
    private var score: Int {
        [password.count >= 8, password.rangeOfCharacter(from: .uppercaseLetters) != nil, password.rangeOfCharacter(from: .decimalDigits) != nil, password.rangeOfCharacter(from: .symbols) != nil].filter { $0 }.count
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { index in
                    Rectangle().fill(index < score ? (score == 4 ? Color.lunaSafe : Color.lunaSignal) : .black.opacity(0.1)).frame(height: 8)
                }
            }
            Text(["start with 8 characters", "weak · add length", "fair · add a number", "good · add a symbol", "strong password"][score])
                .font(.system(size: 11))
                .foregroundStyle(score == 4 ? .green : .secondary)
            Text("8+ characters · uppercase · number · symbol")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Home, report, wellness

final class ReminderManager: ObservableObject {
    @Published private(set) var status = "reminders off"
    private let center = UNUserNotificationCenter.current()

    init() { refreshStatus() }

    func enable() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            guard let self else { return }
            if granted {
                self.scheduleReminders()
            } else {
                DispatchQueue.main.async { self.status = "notifications are off in iOS Settings" }
            }
        }
    }

    private func refreshStatus() {
        center.getNotificationSettings { [weak self] settings in
            let enabled = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { self?.status = enabled ? "daily reminders on" : "reminders off" }
        }
    }

    private func scheduleReminders() {
        center.removePendingNotificationRequests(withIdentifiers: ["luna.daily.scan", "luna.eye.break", "luna.water.break", "luna.food.break"])
        scheduleCalendar(id: "luna.daily.scan", title: "comfort check-in", body: "How do your eyes feel today? Your optional quick eye check keeps the camera view hidden.", hour: 9)
        scheduleInterval(id: "luna.eye.break", title: "distance break", body: "Look away from the screen and blink naturally for 20 seconds.", seconds: 7_200)
        scheduleInterval(id: "luna.water.break", title: "water break", body: "A quick water break can support comfort during screen time.", seconds: 10_800)
        scheduleCalendar(id: "luna.food.break", title: "colorful food check", body: "Add a leafy green, orange vegetable, pepper, or citrus food today.", hour: 13)
        DispatchQueue.main.async { self.status = "daily reminders on" }
    }

    private func scheduleCalendar(id: String, title: String, body: String, hour: Int) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var components = DateComponents()
        components.hour = hour
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)))
    }

    private func scheduleInterval(id: String, title: String, body: String, seconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: true)))
    }
}

struct HomeView: View {
    @ObservedObject var store: AccountStore
    let checkIn: () -> Void
    @StateObject private var reminders = ReminderManager()

    private var report: ScreeningReport? { store.activeAccount?.report }

    private var dueText: String {
        guard let report else { return "start with how you feel" }
        return Date().timeIntervalSince(report.capturedAt) >= 86_400 ? "today's check-in is ready" : "today's comfort is logged"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    RetroTypeSwitcher(title: "your safety desk", phrases: ["protect your focus", "notice comfort early", "choose a gentler next step"])
                    Spacer()
                    Image(systemName: "cross.case.fill")
                        .frame(width: 46, height: 46)
                        .background(Color.lunaSignal)
                        .foregroundStyle(Color.lunaInk)
                        .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 2))
                }
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(dueText).font(.system(size: 21, weight: .medium))
                        Text("Log how you feel, then use the optional quick eye check. Front-camera landmarks are processed on-device without showing or saving the picture.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        BlackButton(title: "log eye comfort", icon: "hand.tap", action: checkIn)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("overall health score").font(.system(size: 18, weight: .medium)).foregroundStyle(Color.lunaPurple)
                            Spacer()
                            Text(store.hasTodayEyeScore ? "\(store.overallHealthScore)" : "—")
                                .font(.system(size: 34, weight: .black, design: .monospaced))
                            Text("/100").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text(store.hasTodayEyeScore ? "Eye results 40% · water 20% · screen-free 25% · breathing 15%. Higher is better." : "Complete the eye check to unlock the overall score. Your habit inputs are already being saved.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            scoreChip("EYE", store.todayEyeScore.map(String.init) ?? "—")
                            scoreChip("HABITS", "\(store.todayHabitScore)")
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("daily health inputs").font(.system(size: 17, weight: .medium)).foregroundStyle(Color.lunaPurple)
                            Spacer()
                            Text("\(store.todayHabitScore)").font(.system(size: 30, weight: .black, design: .monospaced))
                            Text("/100").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text("Full points: 6 cups water, 8 hours screen-free, and 10 minutes of detected breathing practice.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack {
                            Label("\(store.todayWater)/6 cups", systemImage: "drop.fill")
                            Spacer()
                            Label("\(store.todayScreenFreeMinutes)/480m off phone", systemImage: "iphone.slash")
                        }
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        Label("\(store.todayBreathingMinutes)/\(store.breathingGoalMinutes)m breathing", systemImage: "waveform.path")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        Text("Water \(store.todayWaterPoints)/20 · off phone \(store.todayScreenFreePoints)/25 · breathing \(store.todayBreathingPoints)/15")
                            .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Color.lunaBlue)
                        BlackButton(title: store.todayWater >= store.waterGoal ? "water goal met" : "log one water", icon: "drop.fill") { store.logWater() }
                            .disabled(store.todayWater >= store.waterGoal)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("safety reminders").font(.system(size: 16, weight: .medium)).foregroundStyle(Color.lunaTeal)
                        Text(reminders.status).font(.system(size: 13)).foregroundStyle(.secondary)
                        BlackButton(title: "enable safety reminders", icon: "bell.badge") { reminders.enable() }
                    }
                }
            }
            .padding(20)
        }
    }

    private func scoreChip(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Color.lunaBlue)
            Text(value).foregroundStyle(Color.lunaInk)
        }
        .font(.system(size: 10, weight: .black, design: .monospaced))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.lunaSignal.opacity(0.45))
        .overlay(Rectangle().stroke(Color.lunaInk.opacity(0.35), lineWidth: 1))
    }
}

struct SafetyCheckInView: View {
    let done: (ScreeningReport) -> Void
    let back: () -> Void
    @State private var selected: Set<String> = []
    @State private var selectedContexts: Set<String> = []
    @State private var severity = 2.0
    @State private var closeRotation = 0.0
    @State private var showFunctionalChecks = false

    private let choices = [
        ("dry or gritty eyes", "drop", Color.lunaTeal),
        ("tired or heavy eyes", "moon.zzz", Color.lunaLavender),
        ("blur after near work", "textformat.size", Color.lunaCoral),
        ("headache near screens", "bolt", Color.lunaPeach),
        ("light feels uncomfortable", "sun.max", Color.lunaBeige)
    ]
    private let contextChoices = ["long near-work block", "window or lamp glare", "dim room", "fan or dry airflow", "contacts or glasses", "short sleep"]

    var body: some View {
        if showFunctionalChecks {
            FunctionalEyeCheckView(
                symptoms: Array(selected).sorted(),
                contexts: Array(selectedContexts).sorted(),
                severity: selected.isEmpty ? 0 : Int(severity),
                back: { showFunctionalChecks = false },
                done: done
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.7)) { closeRotation = 30 }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { back() }
                    } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44).background(Color.lunaPaper)
                            .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 2))
                    }
                    .rotationEffect(.degrees(closeRotation))
                    .buttonStyle(LunaPressStyle())
                    Spacer()
                    Text("PRIVATE · CAMERA VIEW HIDDEN").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Color.lunaTeal)
                }

                RetroTypeSwitcher(title: "comfort check-in", phrases: ["tap what you feel", "skip what you do not", "save a truthful pattern"])
                Text("First, select only sensations you notice right now. The next screen explains the simple quick eye check before anything starts.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)

                ForEach(choices, id: \.0) { choice in
                    let active = selected.contains(choice.0)
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.68)) {
                            if active { selected.remove(choice.0) } else { selected.insert(choice.0) }
                        }
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: choice.1)
                                .frame(width: 40, height: 40)
                                .background(active ? choice.2 : choice.2.opacity(0.22))
                                .overlay(Rectangle().stroke(Color.lunaInk.opacity(active ? 1 : 0.35), lineWidth: 1))
                                .rotationEffect(.degrees(active ? -7 : 0))
                            Text(choice.0).font(.system(size: 16, weight: .medium)).foregroundStyle(Color.lunaInk)
                            Spacer()
                            Image(systemName: active ? "checkmark.square.fill" : "square")
                                .foregroundStyle(active ? choice.2 : .secondary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Rectangle().fill(Color.lunaBrown.opacity(0.16)).frame(height: 1) }
                    }
                    .buttonStyle(LunaPressStyle())
                }

                if !selected.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("how noticeable?").font(.system(size: 16, weight: .medium))
                            Spacer()
                            Text(["", "very mild", "mild", "moderate", "strong", "very strong"][Int(severity)])
                                .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Color.lunaPurple)
                        }
                        HStack(spacing: 6) {
                            ForEach(1...5, id: \.self) { level in
                                Button {
                                    withAnimation(.snappy(duration: 0.16)) { severity = Double(level) }
                                } label: {
                                    Text("\(level)")
                                        .font(.system(size: 13, weight: .black, design: .monospaced))
                                        .foregroundStyle(Int(severity) == level ? Color.lunaPaper : Color.lunaInk)
                                        .frame(maxWidth: .infinity).frame(height: 38)
                                        .background(Int(severity) == level ? Color.lunaInk : Color.lunaPaper)
                                        .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 2))
                                }
                                .buttonStyle(LunaPressStyle())
                            }
                        }
                        Text("what was happening?").font(.system(size: 16, weight: .medium)).padding(.top, 4)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 8)], spacing: 8) {
                            ForEach(contextChoices, id: \.self) { context in
                                let active = selectedContexts.contains(context)
                                Button {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                                        if active { selectedContexts.remove(context) } else { selectedContexts.insert(context) }
                                    }
                                } label: {
                                    Text(context).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.lunaInk)
                                        .frame(maxWidth: .infinity).frame(minHeight: 42)
                                        .background(active ? Color.lunaLavender : Color.white.opacity(0.58))
                                        .clipShape(Rectangle())
                                        .overlay(Rectangle().stroke(Color.lunaInk.opacity(0.35), lineWidth: 1))
                                }
                                .buttonStyle(LunaPressStyle())
                            }
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                BlackButton(title: "continue to function checks", icon: "rectangle.and.hand.point.up.left") {
                    showFunctionalChecks = true
                }
                }
                .padding(20)
            }
        }
    }
}

final class HiddenEyeObserver: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var isRunning = false
    @Published private(set) var isComplete = false
    @Published private(set) var eyesVisible = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var trackingPercent = 0
    @Published private(set) var blinkCount = 0
    @Published private(set) var blinkRatePerMinute: Double? = nil
    @Published private(set) var blinkIntervals: [Double] = []
    @Published private(set) var blinkRhythmVariabilityPercent: Int? = nil
    @Published private(set) var partialClosurePercent: Int? = nil
    @Published private(set) var signalLoad = 0
    @Published private(set) var coverageTarget: EyeSide? = nil
    @Published private(set) var coveragePercent = 0
    @Published private(set) var coverageComplete = false
    @Published private(set) var coverageReady = false
    @Published private(set) var handCoverageDetected = false
    @Published private(set) var status = "camera ready"

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "luna.hidden-eye.session")
    private let analysisQueue = DispatchQueue(label: "luna.hidden-eye.analysis")
    private var configured = false
    private var startedAt: Date?
    private var analyzedFrames = 0
    private var trackedFrames = 0
    private var finishedState = false
    private var coverageMode = false
    private var coverageStartedAt: Date?
    private var coverageAnalyzedFrames = 0
    private var coveragePassingFrames = 0
    private var coverageConsecutivePassingFrames = 0
    private var engine = BlinkEngine()
    private var monitor = EyeStrainSignalMonitor()
    private let targetSeconds = 15

    func start() {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        if authorization == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.authorization = granted ? .authorized : .denied
                    if granted { self?.startAuthorized() }
                    else { self?.status = "camera permission is off" }
                }
            }
        } else if authorization == .authorized {
            startAuthorized()
        } else {
            status = "camera permission is off"
        }
    }

    func stop() {
        finishedState = true
        sessionQueue.async { [weak self] in self?.session.stopRunning() }
        DispatchQueue.main.async { [weak self] in self?.isRunning = false }
    }

    func startCoverageVerification(target: EyeSide) {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        if authorization == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.authorization = granted ? .authorized : .denied
                    if granted { self?.startCoverageAuthorized(target: target) }
                    else { self?.status = "camera permission is off" }
                }
            }
        } else if authorization == .authorized {
            startCoverageAuthorized(target: target)
        } else {
            status = "camera permission is off"
        }
    }

    private func startAuthorized() {
        reset()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured { self.configureSession() }
            guard self.configured else {
                DispatchQueue.main.async { self.status = "front camera unavailable" }
                return
            }
            self.session.startRunning()
            DispatchQueue.main.async {
                self.isRunning = true
                self.status = "hold the phone normally · blink naturally"
            }
        }
    }

    private func reset() {
        startedAt = nil
        analyzedFrames = 0
        trackedFrames = 0
        finishedState = false
        engine.reset()
        monitor.reset()
        isComplete = false
        eyesVisible = false
        elapsedSeconds = 0
        trackingPercent = 0
        blinkCount = 0
        blinkRatePerMinute = nil
        blinkIntervals = []
        blinkRhythmVariabilityPercent = nil
        partialClosurePercent = nil
        signalLoad = 0
        coverageTarget = nil
        coveragePercent = 0
        coverageComplete = false
        coverageReady = false
        handCoverageDetected = false
        coverageMode = false
        coverageStartedAt = nil
        coverageAnalyzedFrames = 0
        coveragePassingFrames = 0
        coverageConsecutivePassingFrames = 0
    }

    private func startCoverageAuthorized(target: EyeSide) {
        finishedState = false
        coverageMode = true
        coverageTarget = target
        coveragePercent = 0
        coverageComplete = false
        coverageReady = false
        handCoverageDetected = false
        coverageStartedAt = nil
        coverageAnalyzedFrames = 0
        coveragePassingFrames = 0
        coverageConsecutivePassingFrames = 0
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured { self.configureSession() }
            guard self.configured else {
                DispatchQueue.main.async { self.status = "front camera unavailable" }
                return
            }
            self.session.startRunning()
            DispatchQueue.main.async {
                self.isRunning = true
                self.status = "checking one-eye coverage · no preview"
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .medium
        defer { session.commitConfiguration() }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: analysisQueue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        configured = true
    }

    private static func imageRect(for region: VNFaceLandmarkRegion2D, face: VNFaceObservation) -> CGRect? {
        let points = region.normalizedPoints.map {
            CGPoint(
                x: face.boundingBox.minX + CGFloat($0.x) * face.boundingBox.width,
                y: face.boundingBox.minY + CGFloat($0.y) * face.boundingBox.height
            )
        }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(),
              maxX > minX, maxY > minY else { return nil }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return rect.insetBy(dx: -max(0.035, rect.width * 1.2), dy: -max(0.05, rect.height * 2.0))
    }

    private static func handRect(_ observation: VNHumanHandPoseObservation) -> CGRect? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        let locations = points.values
            .filter { $0.confidence >= 0.35 }
            .map(\.location)
        guard let minX = locations.map(\.x).min(), let maxX = locations.map(\.x).max(),
              let minY = locations.map(\.y).min(), let maxY = locations.map(\.y).max(),
              maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !finishedState, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date()
        if startedAt == nil { startedAt = now }
        analyzedFrames += 1
        let timestamp = now.timeIntervalSinceReferenceDate
        let request = VNDetectFaceLandmarksRequest()
        let handRequest = VNDetectHumanHandPoseRequest()
        handRequest.maximumHandCount = 2
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .leftMirrored)
        try? handler.perform([request, handRequest])
        let face = (request.results ?? []).max { $0.boundingBox.width < $1.boundingBox.width }
        let leftPoints = face?.landmarks?.leftEye?.normalizedPoints.map { EyePoint(x: $0.x, y: $0.y) }
        let rightPoints = face?.landmarks?.rightEye?.normalizedPoints.map { EyePoint(x: $0.x, y: $0.y) }
        let left = leftPoints.flatMap(EyeLandmarkNormalizer.sixPointContour)
        let right = rightPoints.flatMap(EyeLandmarkNormalizer.sixPointContour)
        let visible = left != nil && right != nil
        let leftEyeRect = face.flatMap { face in face.landmarks?.leftEye.flatMap { Self.imageRect(for: $0, face: face) } }
        let rightEyeRect = face.flatMap { face in face.landmarks?.rightEye.flatMap { Self.imageRect(for: $0, face: face) } }
        let handRects = (handRequest.results ?? []).compactMap(Self.handRect)
        let leftHandCoversEye = leftEyeRect.map { eye in handRects.contains { $0.intersects(eye) } } ?? false
        let rightHandCoversEye = rightEyeRect.map { eye in handRects.contains { $0.intersects(eye) } } ?? false

        if coverageMode {
            if coverageStartedAt == nil { coverageStartedAt = now }
            coverageAnalyzedFrames += 1
            let targetIsCovered: Bool
            let remainingEyeVisible: Bool
            let handCoversTarget: Bool
            switch coverageTarget {
            case .left:
                targetIsCovered = left == nil || leftHandCoversEye
                remainingEyeVisible = right != nil
                handCoversTarget = leftHandCoversEye
            case .right:
                targetIsCovered = right == nil || rightHandCoversEye
                remainingEyeVisible = left != nil
                handCoversTarget = rightHandCoversEye
            case .none:
                targetIsCovered = false
                remainingEyeVisible = false
                handCoversTarget = false
            }
            let passing = targetIsCovered && remainingEyeVisible
            if passing {
                coveragePassingFrames += 1
                coverageConsecutivePassingFrames += 1
            } else {
                coverageConsecutivePassingFrames = 0
            }
            let percent = coverageAnalyzedFrames == 0 ? 0 : Int((Double(coveragePassingFrames) / Double(coverageAnalyzedFrames) * 100).rounded())
            let elapsed = now.timeIntervalSince(coverageStartedAt ?? now)
            // A hand-over-eye overlap is the strong signal. If Vision loses
            // the covered eye before it can classify the hand, use a longer
            // landmark-only window so a normal blink cannot advance the test.
            let ready = passing && ((handCoversTarget && coverageConsecutivePassingFrames >= 2) || (!handCoversTarget && coverageConsecutivePassingFrames >= 10))
            DispatchQueue.main.async { [weak self] in
                self?.coveragePercent = percent
                self?.handCoverageDetected = handCoversTarget
                self?.status = ready ? "hand coverage confirmed · moving to the eye check" : (handCoversTarget ? "hand found over the requested eye · hold briefly" : "cover the requested eye · \(percent)% signal")
            }
            if ready {
                finishCoverage(confirmed: true)
            } else if elapsed >= 4.0 {
                finishCoverage()
            }
            return
        }

        if visible { trackedFrames += 1 }
        let update = engine.process(left: left, right: right, timestamp: timestamp)
        monitor.ingest(update, timestamp: timestamp)
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt ?? now)))
        let tracking = analyzedFrames == 0 ? 0 : Int((Double(trackedFrames) / Double(analyzedFrames) * 100).rounded())
        DispatchQueue.main.async { [weak self] in
            self?.eyesVisible = visible
            self?.elapsedSeconds = min(self?.targetSeconds ?? 15, elapsed)
            self?.trackingPercent = tracking
            self?.blinkCount = update.blinkCount
            self?.status = visible ? "eyes found · blink naturally" : "move the phone until both eyes are found"
        }
        if elapsed >= targetSeconds { finish() }
    }

    private func finish() {
        guard !finishedState else { return }
        finishedState = true
        let assessment = monitor.assessment()
        let load = assessment.score.map { min(20, max(0, (100 - $0) / 5)) } ?? 0
        sessionQueue.async { [weak self] in self?.session.stopRunning() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.signalLoad = load
            self.blinkRatePerMinute = assessment.blinkRatePerMinute
            self.blinkIntervals = zip(self.monitor.blinkTimestamps.dropFirst(), self.monitor.blinkTimestamps).map { max(0, $0 - $1) }
            self.blinkRhythmVariabilityPercent = assessment.blinkRhythmVariabilityPercent
            self.partialClosurePercent = assessment.partialClosurePercent
            self.isRunning = false
            self.isComplete = true
            self.status = self.trackingPercent >= 65 ? "hidden eye observation complete" : "limited eye tracking · other tasks still count"
        }
    }

    private func finishCoverage(confirmed: Bool = false) {
        guard !finishedState else { return }
        finishedState = true
        sessionQueue.async { [weak self] in self?.session.stopRunning() }
        let percent = coverageAnalyzedFrames == 0 ? 0 : Int((Double(coveragePassingFrames) / Double(coverageAnalyzedFrames) * 100).rounded())
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.coveragePercent = percent
            self.coverageReady = confirmed || percent >= 65
            self.coverageComplete = true
            self.isRunning = false
            self.status = self.coverageReady ? "coverage likely confirmed" : "coverage not confirmed · continue manually"
        }
    }
}

private enum FunctionalCheckStage: String {
    case intro, camera, coverageLeft, acuityLeft, betweenEyes, coverageRight, acuityRight, contrast, search, complete
}

struct FunctionalEyeCheckView: View {
    let symptoms: [String]
    let contexts: [String]
    let severity: Int
    let back: () -> Void
    let done: (ScreeningReport) -> Void

    @StateObject private var camera = HiddenEyeObserver()
    @State private var stage: FunctionalCheckStage = .intro
    @State private var trialIndex = 0
    @State private var currentCorrect = 0
    @State private var digitIndex = Int.random(in: 0..<4)
    @State private var leftCorrect = 0
    @State private var rightCorrect = 0
    @State private var leftLine = "not completed"
    @State private var rightLine = "not completed"
    @State private var contrastIndex = 0
    @State private var contrastCorrect = 0
    @State private var contrastDifficultyIndex = 0
    @State private var searchTrial = 0
    @State private var searchCorrect = 0
    @State private var searchTarget = Int.random(in: 0..<16)
    @State private var searchStarted = Date()
    @State private var searchTimes: [Int] = []

    private let digits = ["2", "4", "6", "8"]
    private let claritySizes: [CGFloat] = [92, 60, 38, 22, 14]
    private let clarityOpacities: [Double] = [1.0, 0.84, 0.66, 0.47, 0.30]
    private let contrastLevels = [0.34, 0.22, 0.14, 0.085]
    private let contrastSizes: [CGFloat] = [78, 59, 43, 31]

    private var testingLeft: Bool { stage == .acuityLeft }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button(action: back) {
                        Image(systemName: "arrow.left").frame(width: 44, height: 44)
                            .background(Color.lunaPaper)
                            .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 2))
                    }
                    .buttonStyle(LunaPressStyle())
                    Spacer()
                    Text("QUICK EYE CHECK // \(stage.rawValue.uppercased())")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.lunaBlue)
                }

                switch stage {
                case .intro: intro
                case .camera: cameraCheck
                case .coverageLeft, .coverageRight: coverageCheck
                case .acuityLeft, .acuityRight: acuityCheck
                case .betweenEyes: betweenEyes
                case .contrast: contrastCheck
                case .search: searchCheck
                case .complete: completion
                }
            }
            .padding(20)
        }
        .background(RetroGridBackground().ignoresSafeArea())
        .onDisappear { camera.stop() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            RetroTypeSwitcher(title: "quick eye check", phrases: ["hidden observation", "each eye separately", "timed visual search"])
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    compactStep("01", "15-sec eye signal")
                    compactStep("02", "20/x level per eye")
                    compactStep("03", "3 timed searches")
                }
            }
            Text("Wear your usual correction. Camera imagery is never shown or saved.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            BlackButton(title: "start quick eye check", icon: "eye") {
                camera.start()
                stage = .camera
            }
        }
    }

    private var cameraCheck: some View {
        VStack(alignment: .leading, spacing: 16) {
            RetroTypeSwitcher(title: "eye signal", phrases: ["hidden camera", "on device", "blink naturally"])
            Text("Hold the phone normally in even light.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            VStack(spacing: 14) {
                HStack {
                    Text("CAMERA FEED")
                    Spacer()
                    Text("HIDDEN")
                }
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(Color.lunaBlue)
                Image(systemName: camera.eyesVisible ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 52, weight: .black))
                    .foregroundStyle(camera.eyesVisible ? Color.lunaSafe : Color.lunaAlert)
                    .contentTransition(.symbolEffect(.replace))
                Text(camera.status.uppercased())
                    .font(.system(size: 12, weight: .black, design: .monospaced)).multilineTextAlignment(.center)
                RetroProgressBar(value: Double(camera.elapsedSeconds), total: 15, color: .lunaSafe)
                HStack {
                    Text("TRACKING \(camera.trackingPercent)%")
                    Spacer()
                    Text("BLINKS \(camera.blinkCount)")
                }
                .font(.system(size: 10, weight: .black, design: .monospaced))
            }
            .padding(16).background(Color.lunaPaper).overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 3))
            if camera.authorization == .denied || camera.authorization == .restricted {
                BlackButton(title: "open camera permission", icon: "gearshape") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                BlackButton(title: "continue without camera", icon: "arrow.right") {
                    resetClarity(); stage = .acuityLeft
                }
            } else if camera.isComplete {
                BlackButton(title: "continue to digit check", icon: "arrow.right") {
                    camera.startCoverageVerification(target: .right)
                    stage = .coverageLeft
                }
            }
        }
    }

    private var coverageCheck: some View {
        let coveredSide = camera.coverageTarget ?? (stage == .coverageLeft ? .right : .left)
        let testedSide: EyeSide = coveredSide == .right ? .left : .right
        let canContinue = camera.coverageReady || camera.coverageComplete || camera.authorization == .denied || camera.authorization == .restricted
        return VStack(alignment: .leading, spacing: 16) {
            RetroTypeSwitcher(title: "\(testedSide.rawValue) eye setup", phrases: ["cover \(coveredSide.rawValue)", "hidden camera check", "no preview"])
            Text("Cover your \(coveredSide.rawValue.uppercased()) eye without pressing it. Luna checks that the \(testedSide.rawValue) eye remains visible while the covered side drops out of the landmark signal.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            VStack(spacing: 12) {
                Image(systemName: camera.coverageReady ? "checkmark.shield.fill" : "eye.slash")
                    .font(.system(size: 46, weight: .black))
                    .foregroundStyle(camera.coverageReady ? Color.lunaSafe : Color.lunaAlert)
                Text(camera.status.uppercased())
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .multilineTextAlignment(.center)
                RetroProgressBar(value: Double(camera.coveragePercent), total: 100, color: camera.coverageReady ? .lunaSafe : .lunaBlue)
                Text("COVERAGE SIGNAL \(camera.coveragePercent)%")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(Color.lunaPaper)
            .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 3))
            if canContinue {
                BlackButton(title: camera.coverageReady ? "continue to \(testedSide.rawValue) eye" : "continue with manual cover", icon: "arrow.right") {
                    advanceFromCoverage()
                }
            } else {
                Text("Hold still for a moment while the hidden camera checks the cover.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .onChange(of: camera.coverageReady) { _, ready in
            if ready { advanceFromCoverage() }
        }
    }

    private func advanceFromCoverage() {
        guard stage == .coverageLeft || stage == .coverageRight else { return }
        let coveredSide = camera.coverageTarget ?? (stage == .coverageLeft ? .right : .left)
        let testedSide: EyeSide = coveredSide == .right ? .left : .right
        camera.stop()
        resetClarity()
        withAnimation(.easeInOut(duration: 0.22)) {
            stage = testedSide == .left ? .acuityLeft : .acuityRight
        }
    }

    private var acuityCheck: some View {
        VStack(alignment: .leading, spacing: 16) {
            RetroTypeSwitcher(title: testingLeft ? "left eye" : "right eye", phrases: ["20/20 → 20/50", "smaller each success", "five choices"])
            Text(testingLeft ? "Cover your RIGHT eye without pressing it." : "Cover your LEFT eye without pressing it.")
                .font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Color.lunaAlert)
            HStack {
                Text("VISION LEVEL \(acuityLevelLabel)")
                Spacer()
                Text("\(trialIndex + 1)/5")
            }
            .font(.system(size: 10, weight: .black, design: .monospaced))
            ZStack {
                Color.lunaPaper
                Text(digits[digitIndex])
                    .font(.system(size: claritySizes[min(currentCorrect, claritySizes.count - 1)], weight: .black, design: .monospaced))
                    .foregroundStyle(Color.lunaInk.opacity(clarityOpacities[min(currentCorrect, clarityOpacities.count - 1)]))
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity).frame(height: 250)
            .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 3))
            digitPad(action: answerClarity)
        }
    }

    private var betweenEyes: some View {
        VStack(alignment: .leading, spacing: 16) {
            RetroTypeSwitcher(title: "left complete", phrases: [leftLine, "switch eyes", "same five digits"])
            resultRow("LEFT RESULT", leftLine)
            Text("Now cover your LEFT eye without pressing it.")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
            BlackButton(title: "start right eye", icon: "arrow.right") {
                camera.startCoverageVerification(target: .left)
                stage = .coverageRight
            }
        }
    }

    private var contrastCheck: some View {
        VStack(alignment: .leading, spacing: 16) {
            RetroTypeSwitcher(title: "faint digit", phrases: ["both eyes open", "four levels", "every answer advances"])
            HStack {
                Text("LEVEL \(contrastIndex + 1)/\(contrastLevels.count)")
                Spacer()
                Text("\(contrastCorrect) CORRECT")
            }
            .font(.system(size: 10, weight: .black, design: .monospaced))
            ZStack {
                Color.lunaPaper
                Text(digits[digitIndex])
                    .font(.system(size: contrastSizes[min(contrastDifficultyIndex, contrastSizes.count - 1)], weight: .black, design: .monospaced))
                    .foregroundStyle(Color.lunaInk.opacity(contrastLevels[min(contrastDifficultyIndex, contrastLevels.count - 1)]))
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity).frame(height: 250)
            .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 3))
            digitPad(action: answerContrast)
        }
    }

    private var searchCheck: some View {
        VStack(alignment: .leading, spacing: 14) {
            RetroTypeSwitcher(title: "visual search", phrases: ["find C among O", "accuracy before speed", "three short grids"])
            HStack {
                Text("GRID \(searchTrial + 1)/3")
                Spacer()
                Text("\(searchCorrect) CORRECT")
            }
            .font(.system(size: 10, weight: .black, design: .monospaced))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 5) {
                ForEach(0..<16, id: \.self) { index in
                    Button { answerSearch(index) } label: {
                        Text(index == searchTarget ? "C" : "O")
                            .font(.system(size: 24, weight: .black, design: .monospaced))
                            .foregroundStyle(Color.lunaInk)
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(Color.lunaPaper)
                            .overlay(Rectangle().stroke(Color.lunaInk.opacity(0.45), lineWidth: 1))
                    }
                    .buttonStyle(LunaPressStyle())
                }
            }
            Text("Tap the C. Accuracy and response time affect the result.")
                .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Color.lunaBlue)
        }
    }

    private var completion: some View {
        let result = functionalResult
        return VStack(alignment: .leading, spacing: 14) {
            RetroTypeSwitcher(title: "check complete", phrases: ["symptoms plus tasks", "each task counted", "repeatability matters"])
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CURRENT STRAIN LOAD").font(.system(size: 10, weight: .black, design: .monospaced))
                    Text("\(result.strainLoad)/100 · \(result.strainBand.uppercased())")
                        .font(.system(size: 24, weight: .black, design: .monospaced))
                        .foregroundStyle(result.strainLoad >= 50 ? Color.lunaAlert : Color.lunaBlue)
                    Text("Confidence \(result.confidence)% from completed symptom, camera, digit, contrast, and search inputs.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            resultRow("LEFT CLARITY", result.leftClarityLine)
            resultRow("RIGHT CLARITY", result.rightClarityLine)
            if let tracking = result.hiddenCameraTrackingPercent, let blinks = result.hiddenCameraBlinkCount {
                let rate = result.hiddenCameraBlinkRatePerMinute.map { String(format: "%.1f/min", $0) } ?? "rate unavailable"
                resultRow("BLINK SIGNAL", "\(blinks) blinks · \(rate)")
                resultRow("BLINK MEANING", "\(result.blinkSignalMeaning) · +\(result.hiddenCameraSignalLoad ?? 0) load")
                resultRow("EYE TRACKING", "\(tracking)% tracked")
            }
            resultRow("CONTRAST", "\(result.contrastCorrect)/\(result.contrastTotal)")
            resultRow("VISUAL SEARCH", "\(result.searchCorrect)/\(result.searchTotal) · \(result.medianSearchMilliseconds) ms median")
            resultRow("SEARCH EFFECT", "+\(searchLoad) load points")
            resultRow("LOAD MIX", "tasks \(strainBreakdown.taskLoad) · comfort \(strainBreakdown.comfortLoad) · camera \(strainBreakdown.camera)")
            Text("20/x is a phone-distance task level, not a glasses prescription. Repeated low or uneven results should be checked with a calibrated eye chart.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            BlackButton(title: "save check-in", icon: "square.and.arrow.down") { save(result) }
        }
    }

    private func compactStep(_ number: String, _ label: String) -> some View {
        HStack(spacing: 10) {
            Text(number).foregroundStyle(Color.lunaBlue)
            Text(label)
        }
        .font(.system(size: 12, weight: .black, design: .monospaced))
    }

    private func digitPad(action: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 7) {
            ForEach(0..<4, id: \.self) { answer in
                Button { action(answer) } label: {
                    Text(digits[answer])
                        .font(.system(size: 20, weight: .black, design: .monospaced))
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .foregroundStyle(Color.lunaPaper).background(Color.lunaInk)
                        .overlay(Rectangle().stroke(Color.lunaSignal, lineWidth: 2))
                }.buttonStyle(LunaPressStyle())
            }
        }
    }

    private func resultRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 10, weight: .black, design: .monospaced)).foregroundStyle(Color.lunaBlue)
            Spacer()
            Text(value).font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .padding(11).background(Color.lunaPaper).overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 1))
    }

    private func resetClarity() {
        trialIndex = 0
        currentCorrect = 0
        digitIndex = Int.random(in: 0..<digits.count)
    }

    private var acuityLevelLabel: String {
        ["20/20", "20/25", "20/30", "20/40", "20/50"][min(currentCorrect, 4)]
    }

    private func clarityResultLine(_ correct: Int) -> String {
        let level = ["20/20", "20/25", "20/30", "20/40", "20/50"][min(correct, 4)]
        return correct == 0 ? "0/5 correct · below \(level)" : "\(correct)/5 correct · \(level) reached"
    }

    private func answerClarity(_ answer: Int) {
        let correct = currentCorrect + (answer == digitIndex ? 1 : 0)
        if trialIndex < claritySizes.count - 1 {
            currentCorrect = correct
            trialIndex += 1
            advanceDigit()
        } else if testingLeft {
            leftCorrect = correct
            leftLine = clarityResultLine(correct)
            stage = .betweenEyes
        } else {
            rightCorrect = correct
            rightLine = clarityResultLine(correct)
            contrastIndex = 0
            contrastCorrect = 0
            contrastDifficultyIndex = 0
            advanceDigit()
            stage = .contrast
        }
    }

    private func advanceDigit() {
        let previous = digitIndex
        var next = Int.random(in: 0..<digits.count)
        if next == previous { next = (previous + Int.random(in: 1..<digits.count)) % digits.count }
        digitIndex = next
    }

    private func answerContrast(_ answer: Int) {
        if answer == digitIndex {
            contrastCorrect += 1
            contrastDifficultyIndex = min(contrastDifficultyIndex + 1, contrastLevels.count - 1)
        }
        if contrastIndex < contrastLevels.count - 1 {
            contrastIndex += 1
            advanceDigit()
        } else {
            searchStarted = Date()
            stage = .search
        }
    }

    private func answerSearch(_ index: Int) {
        let elapsed = max(0, Int(Date().timeIntervalSince(searchStarted) * 1000))
        searchTimes.append(elapsed)
        if index == searchTarget { searchCorrect += 1 }
        if searchTrial < 2 {
            searchTrial += 1
            searchTarget = Int.random(in: 0..<16)
            searchStarted = Date()
        } else {
            stage = .complete
        }
    }

    private var medianSearch: Int {
        let values = searchTimes.sorted()
        guard !values.isEmpty else { return 0 }
        return values[values.count / 2]
    }

    private var searchLoad: Int {
        let missLoad = min(15, max(0, 3 - searchCorrect) * 3)
        let timeLoad = min(8, max(0, medianSearch - 900) / 250)
        return missLoad + timeLoad
    }

    private var strainInputs: FunctionalStrainInputs {
        let relevantContexts = contexts.filter { ["long near-work block", "window or lamp glare", "dim room", "short sleep"].contains($0) }.count
        return FunctionalStrainInputs(
            symptomCount: symptoms.count,
            severity: severity,
            relevantContextCount: relevantContexts,
            contrastCorrect: contrastCorrect,
            contrastTotal: contrastLevels.count,
            searchCorrect: searchCorrect,
            searchTotal: 3,
            medianSearchMilliseconds: medianSearch,
            cameraSignalLoad: camera.signalLoad,
            clarityCorrect: leftCorrect + rightCorrect,
            clarityTotal: 10
        )
    }

    private var strainBreakdown: FunctionalStrainBreakdown {
        FunctionalStrainEstimator.breakdown(strainInputs)
    }

    private var functionalResult: FunctionalEyeCheck {
        let load = FunctionalStrainEstimator.estimate(strainInputs)
        let completedCore = searchTimes.count == 3 && contrastIndex == contrastLevels.count - 1 && leftLine != "not completed" && rightLine != "not completed"
        let confidence = completedCore ? (camera.isComplete && camera.trackingPercent >= 65 ? 92 : 78) : 58
        return FunctionalEyeCheck(
            leftClarityLine: leftLine,
            rightClarityLine: rightLine,
            contrastCorrect: contrastCorrect,
            contrastTotal: contrastLevels.count,
            searchCorrect: searchCorrect,
            searchTotal: 3,
            medianSearchMilliseconds: medianSearch,
            focusRecoveryMilliseconds: 0,
            strainLoad: load,
            confidence: confidence,
            hiddenCameraSeconds: camera.isComplete ? camera.elapsedSeconds : nil,
            hiddenCameraTrackingPercent: camera.isComplete ? camera.trackingPercent : nil,
            hiddenCameraBlinkCount: camera.isComplete ? camera.blinkCount : nil,
            hiddenCameraSignalLoad: camera.isComplete ? camera.signalLoad : nil,
            hiddenCameraBlinkRatePerMinute: camera.isComplete ? camera.blinkRatePerMinute : nil,
            hiddenCameraBlinkRhythmVariabilityPercent: camera.isComplete ? camera.blinkRhythmVariabilityPercent : nil,
            hiddenCameraPartialClosurePercent: camera.isComplete ? camera.partialClosurePercent : nil,
            hiddenCameraBlinkIntervals: camera.isComplete ? camera.blinkIntervals : nil
        )
    }

    private func save(_ result: FunctionalEyeCheck) {
        done(ScreeningReport(
            capturedAt: Date(),
            summary: "current strain load \(result.strainLoad)/100 · \(result.strainBand)",
            quality: "questions plus quick on-device eye checks · \(result.confidence)% input confidence",
            interpretation: "The strain load combines reported discomfort, the hidden-camera blink rate, timing variability, partial closures and tracking coverage, digit-task misses, contrast misses, and visual-search accuracy and timing.",
            eyeStrain: nil,
            symptoms: symptoms,
            contexts: contexts,
            severity: symptoms.isEmpty ? nil : severity,
            functionalCheck: result
        ))
    }
}

struct PersonalizedSafetyPlan {
    let title: String
    let detail: String
    let actions: [String]

    static func make(for report: ScreeningReport?) -> PersonalizedSafetyPlan {
        let symptoms = Set(report?.symptoms ?? [])
        let contexts = Set(report?.contexts ?? [])
        let severity = report?.severity ?? 0
        let function = report?.functionalCheck
        guard !symptoms.isEmpty || function != nil else {
            return PersonalizedSafetyPlan(title: "comfortable baseline", detail: "No discomfort was selected in the latest check-in.", actions: ["Keep the next near-work block short enough to stay comfortable.", "Take a distance look before symptoms begin rather than waiting for them."])
        }

        let title: String
        if function.map({ $0.strainLoad >= 75 }) == true { title = "high current strain load" }
        else if function.map({ $0.strainLoad >= 50 }) == true { title = "elevated current strain load" }
        else if severity >= 4 || symptoms.count >= 4 { title = "higher-discomfort day" }
        else if symptoms.contains("dry or gritty eyes") && (contexts.contains("fan or dry airflow") || contexts.contains("contacts or glasses")) { title = "surface-comfort pattern" }
        else if symptoms.contains("blur after near work") && contexts.contains("long near-work block") { title = "close-focus overload pattern" }
        else if (symptoms.contains("headache near screens") || symptoms.contains("light feels uncomfortable")) && contexts.contains("window or lamp glare") { title = "glare-linked comfort pattern" }
        else if symptoms.contains("tired or heavy eyes") && contexts.contains("short sleep") { title = "sleep-linked tired-eye pattern" }
        else { title = "mixed comfort pattern" }

        var actions: [String] = []
        if let function, function.contrastCorrect <= 3 { actions.append("Low-contrast recognition was inconsistent. Increase text contrast and size; compare again when rested rather than treating this as an acuity result.") }
        if let function, function.searchCorrect < 2 || function.medianSearchMilliseconds > 1_500 { actions.append("The visual-search task was slower or less accurate. Reduce clutter and do one visual task at a time during the next screen block.") }
        if let function, clarityNeedsFollowUp(function.leftClarityLine, function.rightClarityLine) { actions.append("The left/right clarity result was reduced or uneven. Recheck with usual correction; if it repeats, arrange a calibrated eye exam.") }
        if severity >= 4 { actions.append("Stop the current near-work task now and resume only after the sensations settle.") }
        if contexts.contains("long near-work block") { actions.append("For the next block, set a 20-minute cue and take a 20-second distance look at the cue.") }
        if contexts.contains("window or lamp glare") { actions.append("Turn the screen away from the light source, reduce reflections, and keep text comfortably readable.") }
        if contexts.contains("dim room") { actions.append("Add soft room light so the screen is not the brightest object in view.") }
        if contexts.contains("fan or dry airflow") { actions.append("Redirect the fan or vent away from your face before the next screen block.") }
        if contexts.contains("contacts or glasses") { actions.append("Clean glasses or follow your usual contact-lens wear instructions; do not keep wearing lenses that feel uncomfortable.") }
        if contexts.contains("short sleep") { actions.append("Use shorter screen blocks today and protect a consistent sleep window tonight.") }
        if symptoms.contains("blur after near work") { actions.append("Use a distance look and wait for clear focus before returning to close work.") }
        if symptoms.contains("dry or gritty eyes") && !contexts.contains("fan or dry airflow") { actions.append("Pause the screen and allow several natural, complete blinks without forcing them.") }
        if symptoms.contains("headache near screens") && !contexts.contains("window or lamp glare") { actions.append("Lower visual load: enlarge text, use comfortable brightness, and step away briefly.") }
        if symptoms.contains("light feels uncomfortable") { actions.append("Try warm focus mode and lower brightness only as far as text remains easy to read.") }
        if symptoms.contains("tired or heavy eyes") && !contexts.contains("short sleep") { actions.append("Take a screen-free reset before deciding whether to continue near work.") }

        let contextText = contexts.isEmpty ? "No trigger was selected." : "Linked with " + contexts.sorted().joined(separator: ", ") + "."
        let measuredText = function.map { " Estimated strain load \($0.strainLoad)/100 from symptoms plus completed tasks." } ?? ""
        return PersonalizedSafetyPlan(title: title, detail: "Intensity \(severity)/5. \(contextText)\(measuredText)", actions: Array(actions.prefix(4)))
    }

    private static func clarityNeedsFollowUp(_ left: String, _ right: String) -> Bool {
        let leftScore = Int(left.split(separator: "/").first ?? "") ?? 0
        let rightScore = Int(right.split(separator: "/").first ?? "") ?? 0
        return min(leftScore, rightScore) < 3 || abs(leftScore - rightScore) >= 2
    }
}

struct SafetySummaryView: View {
    let report: ScreeningReport?
    let wellness: () -> Void

    private var plan: PersonalizedSafetyPlan { .make(for: report) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RetroTypeSwitcher(title: "your safety pattern", phrases: ["problem, then action", "reported, never guessed", "small changes count"])
                Text(report?.summary ?? "nothing logged yet").font(.system(size: 22, weight: .medium))
                Text(report?.quality ?? "Use the check-in folder whenever you want to record comfort.").font(.system(size: 13)).foregroundStyle(.secondary)
                Text(reportNotice).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Color.lunaPurple)
                if let check = report?.functionalCheck {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("STRAIN LOAD").font(.system(size: 10, weight: .black, design: .monospaced))
                                Spacer()
                                Text("\(check.strainLoad)/100").font(.system(size: 25, weight: .black, design: .monospaced))
                            }
                            Text("\(check.strainBand.uppercased()) · \(check.confidence)% INPUT CONFIDENCE")
                                .font(.system(size: 10, weight: .black, design: .monospaced)).foregroundStyle(Color.lunaAlert)
                            Text("EYE SCORE · \(max(0, 100 - check.strainLoad))/100 · higher is better")
                                .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Color.lunaBlue)
                            Text("Contrast \(check.contrastCorrect)/\(check.contrastTotal) · search \(check.searchCorrect)/\(check.searchTotal) at \(check.medianSearchMilliseconds) ms")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            if let tracking = check.hiddenCameraTrackingPercent, let blinks = check.hiddenCameraBlinkCount {
                                let rate = check.hiddenCameraBlinkRatePerMinute.map { String(format: "%.1f/min", $0) } ?? "rate unavailable"
                                Text("Blink signal · \(blinks) events · \(rate) · \(check.blinkSignalMeaning) · +\(check.hiddenCameraSignalLoad ?? 0) load")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                Text("Eye tracking · \(tracking)% · no image saved")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Divider()
                            Text("CLARITY · L \(check.leftClarityLine) / R \(check.rightClarityLine)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                            Text("Clarity is kept outside the strain calculation.").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                } else if let estimate = report?.eyeStrain {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("COMFORT SIGNAL").font(.system(size: 10, weight: .black, design: .monospaced))
                                Spacer()
                                Text(String(estimate.score ?? 0) + "/100")
                                    .font(.system(size: 25, weight: .black, design: .monospaced))
                            }
                            Text(estimate.label.uppercased())
                                .font(.system(size: 10, weight: .black, design: .monospaced))
                                .foregroundStyle(Color.lunaBlue)
                            Text(estimate.scoreMeaning)
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(plan.title.uppercased()).font(.system(size: 18, weight: .black, design: .monospaced)).foregroundStyle(Color.lunaAlert)
                Text(plan.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(Array(plan.actions.enumerated()), id: \.offset) { index, action in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                            .frame(width: 28, height: 28).background(index.isMultiple(of: 2) ? Color.lunaAlert : Color.lunaBlue).clipShape(Rectangle())
                        Text(action).font(.system(size: 14)).foregroundStyle(Color.lunaInk)
                    }
                    .padding(.vertical, 8)
                }
                BlackButton(title: "open improvements", icon: "sparkles", action: wellness)
            }
            .padding(20)
        }
    }
}

enum WellnessExercise: String, Identifiable {
    case breathing, fitness
    var id: String { rawValue }
}

struct ExerciseButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 20, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.lunaInk)
            .frame(maxWidth: .infinity).frame(height: 74)
            .overlay(Rectangle().stroke(Color.lunaTeal.opacity(0.55), lineWidth: 2))
        }
        .buttonStyle(LunaPressStyle())
    }
}

struct WellnessExerciseSheet: View {
    let exercise: WellnessExercise
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if exercise == .breathing {
                    BreathExerciseView(dismiss: { dismiss() })
                } else {
                    MovementResetView(dismiss: { dismiss() })
                }
            }
            .padding(24)
            .background(Color.lunaBackground.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("close") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

enum BreathPhase: String {
    case ready, inhale, hold, exhale, settle

    var title: String {
        switch self {
        case .ready: return "ready"
        case .inhale: return "inhale"
        case .hold: return "soft hold"
        case .exhale: return "exhale"
        case .settle: return "settle"
        }
    }

    var tip: String {
        switch self {
        case .ready: return "Start the microphone check, then breathe normally."
        case .inhale: return "Let the breath arrive slowly; do not force a deep inhale."
        case .hold: return "Keep your shoulders relaxed and let the signal settle."
        case .exhale: return "Make the exhale a little longer than the inhale."
        case .settle: return "A quiet moment between breaths helps the detector separate cycles."
        }
    }
}

/// A small, on-device audio envelope/state-machine detector. It follows the
/// same privacy-first shape as shiihaa-breath-detection: the microphone is
/// sampled locally, a smoothed energy signal is classified into breath phases,
/// and no raw audio leaves the phone.
final class BreathSession: NSObject, ObservableObject {
    @Published private(set) var phase: BreathPhase = .ready
    @Published private(set) var breathCount = 0
    @Published private(set) var amplitude = 0.0
    @Published private(set) var quality = "microphone is off"
    @Published private(set) var tip = BreathPhase.ready.tip
    @Published private(set) var isRunning = false
    @Published private(set) var confidence = 0.0
    @Published private(set) var calibrationProgress = 0.0

    private let engine = AVAudioEngine()
    private let processingQueue = DispatchQueue(label: "luna.breath.signal")
    private var tapInstalled = false
    private var samples: [Double] = []
    private var lastEnergy = 0.0
    private var smoothedEnergy = 0.0
    private var noiseFloor = 0.008
    private var lastPhase: BreathPhase = .ready
    private var lastTransition = Date.distantPast
    private var processedFrames = 0
    private var calibrationEnergy = 0.0

    func start() {
        guard !isRunning else { return }
        quality = "requesting microphone…"
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.quality = "microphone permission is needed for breath feedback"
                    return
                }
                self.configureAudio()
            }
        }
    }

    func stop() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            if self.tapInstalled { self.engine.inputNode.removeTap(onBus: 0); self.tapInstalled = false }
            self.engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            DispatchQueue.main.async {
                self.isRunning = false
                self.phase = .ready
                self.tip = BreathPhase.ready.tip
                self.quality = "microphone is off"
                self.amplitude = 0
                self.confidence = 0
                self.calibrationProgress = 0
            }
        }
    }

    deinit { stop() }

    private func configureAudio() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            do {
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.record, mode: .measurement, options: [.duckOthers, .allowBluetoothHFP])
                try audio.setActive(true, options: .notifyOthersOnDeactivation)
                let input = self.engine.inputNode
                let format = input.inputFormat(forBus: 0)
                guard format.sampleRate > 0 else { throw NSError(domain: "luna.breath", code: 1) }
                if self.tapInstalled { input.removeTap(onBus: 0) }
                input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
                    self?.process(buffer: buffer)
                }
                self.tapInstalled = true
                self.engine.prepare()
                try self.engine.start()
                DispatchQueue.main.async {
                    self.isRunning = true
                    self.phase = .settle
                    self.lastPhase = .settle
                    self.breathCount = 0
                    self.samples.removeAll(keepingCapacity: true)
                    self.processedFrames = 0
                    self.calibrationEnergy = 0
                    self.quality = "calibrating room sound · stay quiet"
                    self.tip = BreathPhase.settle.tip
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.quality = "microphone could not start"
                    self.tip = "Check microphone access in Settings, then try again."
                }
            }
        }
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum = 0.0
        for index in 0..<count {
            let value = Double(channel[index])
            sum += value * value
        }
        let rms = sqrt(sum / Double(count))
        smoothedEnergy = smoothedEnergy * 0.82 + rms * 0.18
        processedFrames += 1
        if processedFrames <= 36 {
            calibrationEnergy += smoothedEnergy
            noiseFloor = max(0.0008, calibrationEnergy / Double(processedFrames))
            let progress = Double(processedFrames) / 36.0
            DispatchQueue.main.async {
                self.amplitude = min(1, self.smoothedEnergy / 0.05)
                self.phase = .settle
                self.confidence = 0
                self.calibrationProgress = progress
                self.quality = "calibrating room sound · \(Int(progress * 100))%"
            }
            return
        }
        if smoothedEnergy < noiseFloor * 1.45 {
            noiseFloor = noiseFloor * 0.995 + smoothedEnergy * 0.005
        }
        let delta = smoothedEnergy - lastEnergy
        lastEnergy = smoothedEnergy
        let relative = max(0, smoothedEnergy - noiseFloor)
        samples.append(relative)
        if samples.count > 18 { samples.removeFirst() }
        let trend = samples.count > 3 ? (samples.last! - samples[max(0, samples.count - 4)]) / 4 : delta
        let audible = relative > max(0.004, noiseFloor * 0.55)
        let next: BreathPhase
        let phaseAge = Date().timeIntervalSince(lastTransition)
        if !audible {
            switch lastPhase {
            case .inhale: next = phaseAge > 0.55 ? .hold : .inhale
            case .hold: next = .hold
            case .exhale: next = .settle
            case .ready, .settle: next = .settle
            }
        } else {
            switch lastPhase {
            case .ready, .settle: next = .inhale
            case .inhale: next = trend < -0.0012 && phaseAge > 0.7 ? .hold : .inhale
            case .hold: next = .exhale
            case .exhale: next = .exhale
            }
        }
        let confidence = audible ? min(1, 0.35 + relative / 0.035 + abs(trend) / 0.004) : (next == .hold || next == .settle ? 0.55 : 0.2)
        guard next != lastPhase else {
            publish(energy: relative, phase: next, confidence: confidence)
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastTransition) > 0.22 else {
            publish(energy: relative, phase: lastPhase, confidence: confidence * 0.7)
            return
        }
        if lastPhase == .exhale && (next == .settle || next == .inhale) { breathCount += 1 }
        lastPhase = next
        lastTransition = now
        publish(energy: relative, phase: next, confidence: confidence)
    }

    private func publish(energy: Double, phase: BreathPhase, confidence: Double) {
        let normalized = min(1, energy / 0.045)
        DispatchQueue.main.async {
            self.amplitude = normalized
            self.phase = phase
            self.confidence = confidence
            self.calibrationProgress = 1
            self.tip = phase.tip
            let noun = self.breathCount == 1 ? "cycle" : "cycles"
            self.quality = confidence >= 0.65 ? "clear live estimate · " + String(self.breathCount) + " " + noun : "low confidence · reduce speech and background noise"
        }
    }
}

struct BreathExerciseView: View {
    let dismiss: () -> Void
    @StateObject private var breath = BreathSession()
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("BREATH RESET").font(.system(size: 26, weight: .black, design: .monospaced))
                Spacer()
                Text("on-device").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Color.lunaBrown)
            }
            Text("This short exercise listens to the microphone’s breathing envelope. It counts detected cycles and changes the guide when your inhale or exhale signal changes.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("LIVE AIRFLOW")
                    Spacer()
                    Text("\(breath.breathCount) CYCLES")
                }
                .font(.system(size: 10, weight: .black, design: .monospaced))
                Text(breath.phase.title.uppercased())
                    .font(.system(size: 28, weight: .black, design: .monospaced))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.lunaInk.opacity(0.10))
                        Rectangle().fill(Color.lunaBlue)
                            .frame(width: max(4, proxy.size.width * CGFloat(breath.amplitude)))
                    }
                    .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 2))
                }
                .frame(height: 34)
                HStack(spacing: 4) {
                    ForEach(0..<12, id: \.self) { index in
                        Rectangle()
                            .fill(Double(index) / 12.0 <= breath.amplitude ? Color.lunaSignal : Color.lunaInk.opacity(0.12))
                            .frame(height: pulse ? 12 : 8)
                    }
                }
                .animation(.linear(duration: 0.18), value: breath.amplitude)
            }
            .padding(16)
            .frame(maxWidth: .infinity).frame(height: 174)
            .background(Color.lunaPaper)
            .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 3))
            .background(Rectangle().fill(Color.lunaInk).offset(x: 5, y: 5))
            Text(breath.quality).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Color.lunaBrown)
            Text(breath.tip).font(.system(size: 14)).foregroundStyle(.secondary)
            Spacer()
            BlackButton(title: breath.isRunning ? "stop breath check" : "start breath check", icon: breath.isRunning ? "stop.fill" : "mic.fill") {
                if breath.isRunning { breath.stop() } else { breath.start(); pulse = true }
            }
            if breath.isRunning {
                Text("If the signal is noisy, move the phone closer and breathe without speaking.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            BlackButton(title: "done") { breath.stop(); dismiss() }
        }
        .onDisappear { breath.stop() }
    }
}

struct BreathStep {
    let phase: BreathPhase
    let seconds: Int
}

struct BreathingProgram: Identifiable {
    let id: String
    let title: String
    let purpose: String
    let duration: Int
    let steps: [BreathStep]

    static let options: [BreathingProgram] = [
        BreathingProgram(id: "steady", title: "steady 4 · 6", purpose: "Longer exhale pacing for a calm reset.", duration: 180, steps: [BreathStep(phase: .inhale, seconds: 4), BreathStep(phase: .exhale, seconds: 6)]),
        BreathingProgram(id: "box", title: "box 4 · 4 · 4 · 4", purpose: "Even pacing for attention and timing practice.", duration: 120, steps: [BreathStep(phase: .inhale, seconds: 4), BreathStep(phase: .hold, seconds: 4), BreathStep(phase: .exhale, seconds: 4), BreathStep(phase: .settle, seconds: 4)]),
        BreathingProgram(id: "soft", title: "soft 3 · 5", purpose: "A shorter, gentler slow-breathing option.", duration: 120, steps: [BreathStep(phase: .inhale, seconds: 3), BreathStep(phase: .exhale, seconds: 5)])
    ]
}

struct BreathingLabView: View {
    let back: () -> Void
    let completed: (Int) -> Void
    @StateObject private var detector = BreathSession()
    @State private var selectedID = BreathingProgram.options[0].id
    @State private var isRunning = false
    @State private var phaseIndex = 0
    @State private var phaseRemaining = 0
    @State private var totalRemaining = 0
    @State private var cycles = 0
    @State private var awaitingDetector = false

    private var program: BreathingProgram {
        BreathingProgram.options.first { $0.id == selectedID } ?? BreathingProgram.options[0]
    }

    private var step: BreathStep { program.steps[min(phaseIndex, program.steps.count - 1)] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button { detector.stop(); back() } label: {
                        Image(systemName: "arrow.left").frame(width: 44, height: 44)
                            .background(Color.lunaSignal).clipShape(Rectangle())
                            .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 2))
                    }
                    .buttonStyle(LunaPressStyle())
                    Spacer()
                    Text("BREATH LAB").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Color.lunaPurple)
                }

                Text("SELECT BREATH PROTOCOL").font(.system(size: 25, weight: .black, design: .monospaced))
                ForEach(BreathingProgram.options) { option in
                    Button {
                        stop()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { selectedID = option.id }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title).font(.system(size: 16, weight: .semibold, design: .monospaced))
                                Text(option.purpose).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: selectedID == option.id ? "checkmark.square.fill" : "square")
                        }
                        .foregroundStyle(Color.lunaInk)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Rectangle().fill(Color.lunaBrown.opacity(0.16)).frame(height: 1) }
                    }
                    .buttonStyle(LunaPressStyle())
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("MICROPHONE SENSOR")
                        Spacer()
                        Text(detector.isRunning ? "LIVE" : "STANDBY")
                            .foregroundStyle(detector.isRunning ? Color.lunaSafe : Color.lunaAlert)
                    }
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    Text(detector.isRunning ? detector.phase.title.uppercased() : (awaitingDetector ? "STARTING MIC…" : "READY"))
                        .font(.system(size: 32, weight: .black, design: .monospaced))
                        .contentTransition(.numericText())
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.lunaInk.opacity(0.10))
                            Rectangle().fill(Color.lunaBlue)
                                .frame(width: max(4, proxy.size.width * CGFloat(detector.amplitude)))
                                .animation(.linear(duration: 0.15), value: detector.amplitude)
                        }
                        .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 2))
                    }
                    .frame(height: 42)
                    HStack {
                        Text(detector.isRunning ? "CONFIDENCE \(Int(detector.confidence * 100))%" : program.title.uppercased())
                        Spacer()
                        Text("AIRFLOW \(Int(detector.amplitude * 100))")
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .padding(16)
                .frame(maxWidth: .infinity).frame(height: 210)
                .background(Color.lunaPaper)
                .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 3))
                .background(Rectangle().fill(Color.lunaInk).offset(x: 6, y: 6))

                HStack {
                    Text("\(detector.breathCount) detected cycles").font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Spacer()
                    Text(time(totalRemaining)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                }
                RetroProgressBar(value: Double(program.duration - totalRemaining), total: Double(program.duration), color: .lunaAlert)
                if isRunning {
                    HStack {
                        Text("pacing guide").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(step.phase.title) · \(phaseRemaining)s").foregroundStyle(Color.lunaPurple)
                    }
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                Text(detector.isRunning ? detector.quality : "Live detection requires microphone access and stays on-device.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if detector.isRunning && isRunning {
                    Text(detector.phase == step.phase ? "detected phase matches the guide" : "detected \(detector.phase.title) · guide says \(step.phase.title)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(detector.phase == step.phase ? Color.lunaTeal : Color.lunaBrown)
                        .contentTransition(.opacity)
                }
                BlackButton(title: (isRunning || awaitingDetector) ? "stop live detection" : "start live detection", icon: (isRunning || awaitingDetector) ? "stop.fill" : "mic.fill") {
                    (isRunning || awaitingDetector) ? stop() : requestStart()
                }
                Text("Place the phone close enough for the lower microphone to hear airflow, stay quiet during calibration, and begin with an inhale. Speech, fans, and room noise lower confidence; microphone phase direction is an estimate, not a respiratory measurement.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Slow breathing may support relaxation and autonomic regulation. This lab does not claim to reproduce glymphatic function or treat eye disease.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(22)
        }
        .background(Color.lunaBackground.ignoresSafeArea())
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard isRunning else { continue }
                tick()
            }
        }
        .onDisappear { detector.stop() }
        .onChange(of: detector.isRunning) { _, active in
            if active && awaitingDetector { beginGuidance() }
        }
        .onChange(of: detector.quality) { _, quality in
            if quality.contains("permission") || quality.contains("could not") { awaitingDetector = false }
        }
    }

    private func requestStart() {
        awaitingDetector = true
        detector.start()
    }

    private func beginGuidance() {
        awaitingDetector = false
        phaseIndex = 0
        phaseRemaining = program.steps[0].seconds
        totalRemaining = program.duration
        cycles = 0
        isRunning = true
        detector.start()
    }

    private func stop() {
        isRunning = false
        awaitingDetector = false
        detector.stop()
        phaseIndex = 0
        phaseRemaining = 0
        totalRemaining = 0
    }

    private func tick() {
        guard totalRemaining > 0 else { stop(); return }
        if totalRemaining == 1 {
            totalRemaining = 0
            completed(max(1, program.duration / 60))
            stop()
            return
        }
        totalRemaining -= 1
        if phaseRemaining > 1 {
            phaseRemaining -= 1
        } else {
            let next = (phaseIndex + 1) % program.steps.count
            if next == 0 { cycles += 1 }
            withAnimation(.easeInOut(duration: 0.3)) { phaseIndex = next }
            phaseRemaining = program.steps[next].seconds
        }
    }

    private func time(_ seconds: Int) -> String {
        String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }
}

struct MovementResetView: View {
    let dismiss: () -> Void
    @State private var seconds = 120
    @State private var isRunning = false
    @State private var phase = 0

    private let steps = ["look 20 feet away", "roll both shoulders", "stand and walk slowly", "return only when comfortable"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SCREEN-BREAK RESET").font(.system(size: 25, weight: .black, design: .monospaced))
            Text("A guided two-minute distance and movement reset. Each step has a purpose: release near-focus tension before you return to the phone.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Image(systemName: "figure.walk").font(.system(size: 28, weight: .medium)).foregroundStyle(Color.lunaBrown)
                VStack(alignment: .leading, spacing: 4) {
                    Text(steps[phase]).font(.system(size: 17, weight: .medium))
                    Text(String(format: "%02d:%02d", seconds / 60, seconds % 60)).font(.system(size: 24, weight: .semibold, design: .monospaced))
                }
                Spacer()
            }
            .padding(16).liquidGlass(16)
            RetroProgressBar(value: Double(120 - seconds), total: 120, color: .lunaBlue)
            Spacer()
            BlackButton(title: isRunning ? "pause reset" : "start reset", icon: isRunning ? "pause.fill" : "play.fill") { isRunning.toggle() }
            BlackButton(title: "done") { dismiss() }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard isRunning else { continue }
                if seconds > 0 {
                    seconds -= 1
                    if seconds % 30 == 0 { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { phase = min(steps.count - 1, phase + 1) } }
                } else { isRunning = false }
            }
        }
    }
}

struct EmptyStat: View {
    let title: String
    let value: String
    let note: String
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 18, weight: .bold, design: .monospaced))
                Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct RoutineActivitySummary: View {
    let activity: RoutineActivity

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock").foregroundStyle(Color.lunaPurple)
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.name.isEmpty ? "untitled activity" : activity.name)
                    .font(.system(size: 14, weight: .medium))
                Text("\(activity.startTime.formatted(date: .omitted, time: .shortened)) – \(activity.endTime.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct ScheduleTimelineEvent: Identifiable {
    let id = UUID()
    let time: Date
    let title: String
    let detail: String
    let icon: String
    let isSupportCue: Bool
}

struct ScheduleTimeline: View {
    let schedule: DailySchedule

    private var events: [ScheduleTimelineEvent] {
        var values: [ScheduleTimelineEvent] = [
            ScheduleTimelineEvent(time: schedule.wakeTime, title: "wake + water", detail: "Drink a glass of water before the first screen block.", icon: "sunrise.fill", isSupportCue: true)
        ]
        for activity in schedule.activities {
            values.append(ScheduleTimelineEvent(time: activity.startTime, title: activity.name.isEmpty ? "activity" : activity.name, detail: "until \(activity.endTime.formatted(date: .omitted, time: .shortened))", icon: "square.fill", isSupportCue: false))
            if activity.durationMinutes >= 30 {
                let waterTime = activity.endTime.addingTimeInterval(5 * 60)
                values.append(ScheduleTimelineEvent(time: waterTime, title: "water + distance break", detail: "Drink water, look across the room for 20 seconds, then return only if comfortable.", icon: "drop.fill", isSupportCue: true))
            }
        }
        let phoneOff = schedule.sleepTime.addingTimeInterval(-60 * 60)
        values.append(ScheduleTimelineEvent(time: phoneOff, title: "phone-off wind-down", detail: "Dim the room and put the phone away one hour before sleep.", icon: "moon.stars.fill", isSupportCue: true))
        values.append(ScheduleTimelineEvent(time: schedule.sleepTime, title: "sleep", detail: "A consistent sleep window supports comfortable near work the next day.", icon: "bed.double.fill", isSupportCue: true))
        return values.sorted { $0.time < $1.time }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Image(systemName: event.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(event.isSupportCue ? Color.lunaInk : .white)
                            .frame(width: 30, height: 30)
                            .background(event.isSupportCue ? Color.lunaBeige : Color.lunaInk)
                            .clipShape(Rectangle())
                        if index < events.count - 1 { Rectangle().fill(Color.lunaBeige).frame(width: 2, height: 34) }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(event.title).font(.system(size: 14, weight: .medium))
                            Spacer()
                            Text(event.time.formatted(date: .omitted, time: .shortened)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        }
                        Text(event.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 14)
                }
            }
        }
    }
}

struct ReportView: View {
    let report: ScreeningReport?
    let wellness: () -> Void
    let saveAssessment: (ScreeningReport) -> Void
    @State private var selectedSymptoms: Set<String> = []
    @State private var symptomsSaved = false
    private let symptomOptions = ["dry or gritty eyes", "tired eyes", "headache near screens", "blurred focus", "light sensitivity"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("YOUR COMFORT LOG").font(.system(size: 27, weight: .black, design: .monospaced))
                TextSwitcher(phrases: ["read the signal", "choose one small change", "check in again when useful"])
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.lunaBrown)
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(report?.summary ?? "no capture yet").font(.system(size: 22, weight: .medium))
                        Text(report?.quality ?? "Start a camera check to get a result.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("eye-strain signal score").font(.system(size: 16, weight: .medium))
                        if let estimate = report?.eyeStrain {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(estimate.score.map { "\($0)" } ?? "—")
                                    .font(.system(size: 36, weight: .black, design: .monospaced))
                                Text("/ 100").font(.system(size: 14)).foregroundStyle(.secondary)
                                Spacer()
                                Text(estimate.label).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.trailing)
                            }
                            Text("blink rhythm \(estimate.blinkRhythmVariabilityPercent.map { "\($0)% variation" } ?? "not enough events") · incomplete closures \(estimate.partialClosurePercent)%")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Text("what the result means").font(.system(size: 14, weight: .medium)).padding(.top, 4)
                            Text(estimate.scoreMeaning)
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        } else {
                            Text("no camera estimate yet")
                                .font(.system(size: 21, weight: .black, design: .monospaced))
                            Text("Complete the front-camera observation window to calculate your eye-strain signal.")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("quick comfort check").font(.system(size: 16, weight: .medium))
                        Text("Tap anything you felt during the check.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        ForEach(symptomOptions, id: \.self) { symptom in
                            Button {
                                if selectedSymptoms.contains(symptom) {
                                    selectedSymptoms.remove(symptom)
                                } else {
                                    selectedSymptoms.insert(symptom)
                                }
                                symptomsSaved = false
                            } label: {
                                HStack {
                                    Text(symptom).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: selectedSymptoms.contains(symptom) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(selectedSymptoms.contains(symptom) ? Color.lunaPurple : .secondary)
                                }
                                .padding(.horizontal, 14).frame(height: 44).liquidGlass(18)
                            }
                            .buttonStyle(LunaPressStyle())
                        }
                        BlackButton(title: symptomsSaved ? "comfort check saved" : "save comfort check") {
                            saveSymptoms()
                        }
                    }
                }
                BlackButton(title: "open wellness", action: wellness)
            }
            .padding(20)
        }
        .onAppear { selectedSymptoms = Set(report?.symptoms ?? []) }
    }

    private func saveSymptoms() {
        guard var report else { return }
        let values = selectedSymptoms.sorted()
        report.symptoms = values
        if let estimate = report.eyeStrain {
            report.eyeStrain = estimate.includingSymptoms(values)
        }
        saveAssessment(report)
        symptomsSaved = true
    }
}

struct DishIdea: Identifiable {
    let id: String
    let cuisine: String
    let name: String
    let icon: String
    let ingredients: [String]
    let materials: [String]
    let steps: [String]
    let shoppingNote: String
    let vitaminNote: String
}

struct FoodSupportGuidance {
    let title: String
    let message: String
    let foods: [String]
    let recipeTitle: String
    let recipe: String

    static func forScore(_ score: Int?) -> FoodSupportGuidance {
        guard let score else {
            return FoodSupportGuidance(title: "food support", message: "A scan cannot show a vitamin deficiency. Start with varied food.", foods: ["spinach", "sweet potato", "red pepper", "citrus", "broccoli"], recipeTitle: "sweet-potato pepper bowl", recipe: "Roast sweet potato; fold in spinach; top with raw red pepper, citrus, and a little olive oil.")
        }
        if score < 50 {
            return FoodSupportGuidance(title: "food support for a lower score", message: "A strain score is not a deficiency test. Ask a clinician before taking vitamin A tablets; high doses can be harmful.", foods: ["sweet potato", "spinach", "red pepper", "orange", "broccoli"], recipeTitle: "sweet-potato pepper bowl", recipe: "Roast sweet potato; fold in spinach; top with red pepper, orange segments, and olive oil.")
        }
        if score < 75 {
            return FoodSupportGuidance(title: "food support", message: "Choose food first. Vitamin A foods support normal vision; vitamin C foods add variety.", foods: ["spinach", "sweet potato", "red pepper", "kiwi", "broccoli"], recipeTitle: "spinach & pepper grain bowl", recipe: "Warm brown rice with spinach; add red pepper, broccoli, and lemon before serving.")
        }
        return FoodSupportGuidance(title: "keep food varied", message: "This score does not call for a supplement. Keep getting nutrients from colorful foods.", foods: ["leafy greens", "orange vegetables", "peppers", "citrus", "beans"], recipeTitle: "citrus greens bowl", recipe: "Toss greens, roasted squash, beans, red pepper, and citrus with olive oil.")
    }
}

struct FoodSupportCard: View {
    let score: Int?
    private var guidance: FoodSupportGuidance { .forScore(score) }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(guidance.title).font(.system(size: 17, weight: .medium)).foregroundStyle(Color.lunaTeal)
                Text(guidance.message).font(.system(size: 13)).foregroundStyle(.secondary)
                Text(guidance.foods.joined(separator: "  ·  ")).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.lunaInk)
                Text(guidance.recipeTitle).font(.system(size: 14, weight: .medium)).padding(.top, 3)
                Text(guidance.recipe).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }
}

struct FocusComfortControl: View {
    @ObservedObject var session: FocusSessionManager
    @State private var showExplanation = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("screen-off focus").font(.system(size: 18, weight: .medium)).foregroundStyle(Color.lunaTeal)
                    Spacer()
                    Button { showExplanation = true } label: { Image(systemName: "info.square") }.buttonStyle(LunaPressStyle())
                }
                if session.countdown > 0 {
                    Text("\(session.countdown)").font(.system(size: 52, weight: .black, design: .monospaced)).contentTransition(.numericText())
                        .foregroundStyle(Color.lunaCoral)
                } else if session.isArmed {
                    Text(time(session.elapsedSeconds)).font(.system(size: 30, weight: .semibold, design: .monospaced))
                } else {
                    Text("lock the phone to earn screen-free time").font(.system(size: 13, weight: .semibold, design: .monospaced))
                }
                Text(session.status).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Color.lunaBrown)
                Text("Luna starts counting after five seconds. Lock the phone; when it is unlocked again, the session pauses and the completed minutes are saved.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                BlackButton(title: session.isArmed ? "end focus session" : "start focus session", icon: session.isArmed ? "stop.fill" : "lock.iphone") {
                    if session.isArmed { session.endManually() } else { showExplanation = true }
                }
            }
        }
        .alert("how screen-off focus works", isPresented: $showExplanation) {
            Button("cancel", role: .cancel) {}
            if !session.isArmed { Button("start · 5 seconds") { session.begin() } }
        } message: {
            Text("After you start, you have five seconds to lock the phone. Luna records time only after that countdown. Unlocking the phone automatically pauses the timer, restores brightness, saves completed whole minutes, and sends a notification. Other apps and total Screen Time are not read.")
        }
    }

    private func time(_ value: Int) -> String {
        String(format: "%02d:%02d", value / 60, value % 60)
    }
}


struct WellnessView: View {
    @ObservedObject var store: AccountStore
    @ObservedObject var focusSession: FocusSessionManager
    let breathing: () -> Void
    @State private var selectedCuisine = ""
    @State private var selectedDish: DishIdea?
    @State private var selectedExercise: WellnessExercise?

    // Only cuisines with a real, ingredient-level eye-support recipe are
    // offered. An unsupported cuisine should be honest rather than receive a
    // renamed copy of the same fallback dish.
    private static let allCuisines = ["Indian", "Japanese", "Mexican"]

    private var dishes: [DishIdea] { dishIdeas(for: selectedCuisine) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RetroTypeSwitcher(title: "improvements", phrases: ["respond to comfort", "eat something colorful", "take a gentler reset"])
                Card {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("breathing lab").font(.system(size: 18, weight: .medium)).foregroundStyle(Color.lunaPurple)
                        Text("Timed slow-breathing programs with live microphone phase feedback.").font(.system(size: 13)).foregroundStyle(.secondary)
                        BlackButton(title: "open breathing lab", icon: "waveform.path") { breathing() }
                    }
                }
                FocusComfortControl(session: focusSession)
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("movement reset").font(.system(size: 18, weight: .medium)).foregroundStyle(Color.lunaCoral)
                        Text("A two-minute distance, shoulder, and walking reset.").font(.system(size: 13)).foregroundStyle(.secondary)
                        BlackButton(title: "start movement reset", icon: "figure.walk") { selectedExercise = .fitness }
                    }
                }
                if let report = store.activeAccount?.report {
                    let plan = PersonalizedSafetyPlan.make(for: report)
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("personalized next step").font(.system(size: 17, weight: .medium)).foregroundStyle(Color.lunaCoral)
                            Text(plan.title).font(.system(size: 20, weight: .medium))
                            Text(plan.actions.first ?? plan.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
                FoodSupportCard(score: store.todayEyeScore)
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("food ideas with vitamins A & C", systemImage: "leaf").font(.system(size: 17, weight: .medium))
                        Menu {
                            ForEach(Self.allCuisines, id: \.self) { cuisine in
                                Button {
                                    // Keep the selection as the single source of
                                    // truth so every menu tap refreshes the
                                    // recipe list, including after reopening it.
                                    selectedCuisine = cuisine
                                    selectedDish = nil
                                } label: {
                                    HStack {
                                        Text(cuisine)
                                        if selectedCuisine == cuisine {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(selectedCuisine.isEmpty ? "choose a cuisine" : selectedCuisine)
                                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.lunaInk)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundStyle(Color.lunaBlue)
                            }
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Color.lunaPaper)
                            .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 2))
                        }
                        .buttonStyle(LunaPressStyle())
                        Text("Choose a cuisine to see dishes selected for vitamin A and C foods.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if selectedCuisine.isEmpty {
                            Text("Open the menu to choose Indian, Japanese, or Mexican ideas.")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        ForEach(dishes) { dish in
                            Button { selectedDish = dish } label: {
                                HStack(spacing: 12) {
                                    DishIllustration(dish: dish)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(dish.name).font(.system(size: 15, weight: .medium)).foregroundStyle(.primary)
                                        Text("vitamin A + vitamin C").font(.system(size: 12)).foregroundStyle(Color.lunaPurple)
                                    }
                                    Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(alignment: .bottom) { Rectangle().fill(Color.lunaBrown.opacity(0.14)).frame(height: 1) }
                            }
                            .buttonStyle(LunaPressStyle())
                        }
                    }
                }
            }
            .padding(20)
        }
        .sheet(item: $selectedDish) { DishRecipeSheet(dish: $0) }
        .sheet(item: $selectedExercise) { WellnessExerciseSheet(exercise: $0) }
    }

}

struct RoutineActivityEditorRow: View {
    @Binding var activity: RoutineActivity
    let canDelete: Bool
    let delete: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TextField("activity name", text: $activity.name).padding(.horizontal, 13).frame(minHeight: 52, alignment: .top).liquidGlass(20)
            VStack(alignment: .leading, spacing: 5) {
                DatePicker("starts", selection: $activity.startTime, displayedComponents: .hourAndMinute).font(.system(size: 11))
                DatePicker("finishes", selection: $activity.endTime, displayedComponents: .hourAndMinute).font(.system(size: 11))
            }
            if canDelete { Button(action: delete) { Image(systemName: "minus.square.fill").foregroundStyle(.secondary) }.buttonStyle(LunaPressStyle()) }
        }
        .padding(11).liquidGlass(22)
    }
}

struct DishIllustration: View {
    let dish: DishIdea
    var body: some View {
        ZStack {
            Rectangle().fill(Color.lunaPaper).shadow(color: Color.lunaInk, radius: 0, x: 4, y: 4)
            Rectangle().stroke(Color.lunaBlue, lineWidth: 3).padding(5)
            Image(systemName: dish.icon).font(.system(size: 28, weight: .medium)).foregroundStyle(Color.lunaPurple)
        }
        .frame(width: 72, height: 72)
    }
}

private func dishIdeas(for cuisine: String) -> [DishIdea] {
    let label = cuisine.isEmpty ? "global" : cuisine
    let key = label.lowercased()
    if key.contains("japan") {
        return [DishIdea(id: "\(label)-salmon", cuisine: label, name: "miso salmon, spinach & pepper donburi", icon: "fish.fill", ingredients: ["Salmon fillet", "Spinach", "Red bell pepper", "Brown rice", "White miso, rice vinegar, ginger"], materials: ["Small bowl", "Nonstick skillet", "Rice pot", "Knife and cutting board"], steps: ["Rinse and cook brown rice according to the package directions.", "Whisk miso, rice vinegar, grated ginger, and a splash of water into a glaze.", "Sear salmon skin-side down until nearly cooked, turn it, and brush with the glaze.", "Quickly wilt spinach and slice the red pepper; keep the pepper only lightly cooked to preserve vitamin C.", "Serve rice with spinach and pepper, then place the glazed salmon on top."], shoppingNote: "Find salmon at the seafood counter, spinach and peppers in produce, and miso in the refrigerated or international aisle.", vitaminNote: "Spinach contributes provitamin A carotenoids; red pepper is a strong vitamin C food. Vitamin A is important for normal vision, while vitamin C comes mainly from fruits and vegetables."), DishIdea(id: "\(label)-sweet-potato", cuisine: label, name: "sweet potato, edamame & citrus rice", icon: "leaf.fill", ingredients: ["Sweet potato", "Edamame", "Brown rice", "Mandarin or orange", "Sesame and scallions"], materials: ["Baking tray", "Rice pot", "Small saucepan", "Citrus zester"], steps: ["Cube the sweet potato, toss with a little oil, and roast at 425°F/220°C until soft and browned.", "Cook brown rice and warm the edamame in a saucepan.", "Peel the citrus and reserve a little zest for the dressing.", "Mix citrus juice, zest, sesame, and scallions into a bright dressing.", "Layer rice, edamame, and sweet potato, then spoon over the dressing."], shoppingNote: "Sweet potatoes, citrus, and scallions are in produce; frozen edamame is usually in the freezer aisle.", vitaminNote: "Sweet potato provides beta-carotene, which the body can convert to vitamin A; citrus adds vitamin C."), DishIdea(id: "\(label)-broccoli", cuisine: label, name: "tofu, broccoli & tomato soba", icon: "fork.knife", ingredients: ["Soba noodles", "Firm tofu", "Broccoli", "Cherry tomatoes", "Low-sodium soy sauce and sesame"], materials: ["Large pot", "Wok or skillet", "Colander", "Tongs"], steps: ["Press tofu briefly, cube it, and pan-sear until golden.", "Boil soba; add broccoli during the final two minutes, then drain.", "Warm halved tomatoes in the skillet until just softened.", "Toss noodles and vegetables with soy sauce, sesame, and a little rice vinegar.", "Fold in tofu and serve warm."], shoppingNote: "Tofu, soba, and soy sauce are in the refrigerated or international aisle; broccoli and tomatoes are in produce.", vitaminNote: "Broccoli and tomatoes contribute vitamin C; adding a little oil helps the body absorb carotenoids from vegetables.")]
    }
    if key.contains("indian") || key.contains("pakistani") || key.contains("bangladesh") {
        return [DishIdea(id: "\(label)-palak", cuisine: label, name: "palak chana with red pepper", icon: "leaf.fill", ingredients: ["Spinach", "Chickpeas", "Red bell pepper", "Tomato", "Onion, garlic, cumin"], materials: ["Heavy skillet", "Blender or immersion blender", "Rice pot", "Wooden spoon"], steps: ["Soften onion and garlic in oil with cumin and turmeric.", "Add chopped tomato and cook until it breaks down.", "Blend half the spinach with a splash of water, then return it to the pan with the remaining spinach.", "Stir in chickpeas and diced red pepper; simmer until tender but keep the pepper bright.", "Serve with brown rice and a squeeze of lemon."], shoppingNote: "Spinach, peppers, tomatoes, onions, and lemons are in produce; chickpeas and spices are in the canned and international aisles.", vitaminNote: "Spinach provides provitamin A carotenoids; red pepper and tomato contribute vitamin C."), DishIdea(id: "\(label)-sweet-potato", cuisine: label, name: "sweet potato moong dal", icon: "carrot.fill", ingredients: ["Yellow moong dal", "Sweet potato", "Spinach", "Tomato", "Ginger, cumin, coriander"], materials: ["Large pot", "Small tempering pan", "Ladle", "Rice pot"], steps: ["Rinse dal and simmer with diced sweet potato until both are soft.", "Cook tomato, ginger, cumin, and coriander in a separate pan.", "Stir the spiced tomato mixture into the dal and thin with water as needed.", "Fold in spinach at the end so it wilts without overcooking.", "Taste for salt and serve with rice or whole-grain roti."], shoppingNote: "Dal and spices are in the international aisle; sweet potato, spinach, and tomato are in produce.", vitaminNote: "Sweet potato is rich in beta-carotene, while tomato and spinach add vitamin C and other carotenoids."), DishIdea(id: "\(label)-fish", cuisine: label, name: "tomato fish curry with cabbage", icon: "fish.fill", ingredients: ["White fish or salmon", "Tomato", "Cabbage", "Green pepper", "Coconut milk, curry leaves, mustard seed"], materials: ["Wide pot", "Steamer or saucepan", "Knife and cutting board", "Wooden spoon"], steps: ["Sauté mustard seed and curry leaves until fragrant.", "Add tomato, green pepper, and spices; cook until saucy.", "Pour in a modest amount of coconut milk and bring to a gentle simmer.", "Nestle fish into the sauce and cook until opaque and flaky.", "Steam cabbage separately and serve alongside the curry."], shoppingNote: "Fish is at the seafood counter, cabbage and peppers are in produce, and curry leaves/coconut milk are in the international aisle.", vitaminNote: "Tomato and green pepper provide vitamin C; fish and leafy vegetables can contribute vitamin A-related nutrients.")]
    }
    if key.contains("mexic") || key.contains("caribbean") || key.contains("puerto") {
        return [DishIdea(id: "\(label)-tostada", cuisine: label, name: "black bean & red pepper tostadas", icon: "leaf.fill", ingredients: ["Black beans", "Whole-grain tostadas", "Red bell pepper", "Cabbage", "Avocado, tomato, lime"], materials: ["Skillet", "Baking sheet", "Mixing bowl", "Knife and cutting board"], steps: ["Warm black beans with cumin and a splash of water until spreadable.", "Toast the tostadas in the oven if needed.", "Dice pepper and tomato; shred cabbage and toss with lime.", "Spread beans over each tostada and layer on the vegetables and avocado.", "Finish with lime and cilantro."], shoppingNote: "Beans and tostadas are in the canned or Latin aisle; peppers, cabbage, tomato, avocado, and lime are in produce.", vitaminNote: "Red pepper and tomato are vitamin C sources; leafy cabbage and avocado add carotenoids and healthy fats."), DishIdea(id: "\(label)-squash", cuisine: label, name: "calabaza, corn & lentil bowl", icon: "carrot.fill", ingredients: ["Winter squash", "Lentils", "Corn", "Poblano or bell pepper", "Pumpkin seeds and lime"], materials: ["Baking tray", "Saucepan", "Rice cooker or pot", "Fork"], steps: ["Roast squash cubes until caramelized and tender.", "Simmer lentils until soft but not mushy.", "Sauté corn and pepper briefly so the pepper stays crisp.", "Combine lentils, squash, corn, and pepper over brown rice.", "Top with pumpkin seeds and lime."], shoppingNote: "Squash, corn, and peppers are in produce or frozen foods; lentils and pumpkin seeds are in the dry-goods aisle.", vitaminNote: "Orange squash provides beta-carotene; peppers and lime add vitamin C."), DishIdea(id: "\(label)-fish", cuisine: label, name: "citrus fish with tomato rice", icon: "fish.fill", ingredients: ["Fish fillet", "Tomato", "Orange", "Spinach", "Brown rice and garlic"], materials: ["Skillet", "Rice pot", "Citrus juicer", "Spatula"], steps: ["Cook brown rice and fold in chopped tomato near the end.", "Season fish with garlic, orange zest, and a pinch of salt.", "Pan-cook fish until it flakes easily, then finish with orange juice.", "Wilt spinach in the warm pan after removing the fish.", "Serve fish over tomato rice with the spinach on the side."], shoppingNote: "Fish is at the seafood counter; oranges, tomatoes, and spinach are in produce; rice is in the grain aisle.", vitaminNote: "Orange, tomato, and spinach contribute vitamin C and provitamin A carotenoids.")]
    }
    return []
}

struct DishRecipeSheet: View {
    let dish: DishIdea
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        DishIllustration(dish: dish).frame(width: 96, height: 96)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(dish.name).font(.system(size: 22, weight: .black, design: .monospaced))
                            Text(dish.cuisine).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    RecipeListCard(title: "ingredients", items: dish.ingredients, bullet: "square.fill")
                    RecipeListCard(title: "materials needed", items: dish.materials, bullet: "square.fill")
                    Card {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("where to find it").font(.system(size: 16, weight: .medium))
                            Text(dish.shoppingNote).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("detailed steps").font(.system(size: 16, weight: .medium))
                            ForEach(Array(dish.steps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .top, spacing: 10) {
                                    Text("\(index + 1)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).frame(width: 24, height: 24).background(Color.lunaInk).clipShape(Rectangle())
                                    Text(step).font(.system(size: 13)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("vitamin A + vitamin C").font(.system(size: 16, weight: .medium))
                            Text(dish.vitaminNote).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    Text("Nutrition notes are general education based on public NIH and National Eye Institute guidance. They do not diagnose a deficiency or promise improved eyesight.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .padding(20)
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("done") { dismiss() } } }
        }
        .preferredColorScheme(.light)
    }
}

struct RecipeListCard: View {
    let title: String
    let items: [String]
    let bullet: String
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 16, weight: .medium))
                ForEach(items, id: \.self) { item in Label(item, systemImage: bullet).font(.system(size: 13)).foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: - Camera and report capture

#if false // Legacy prototype retained for reference; camera capture is not compiled into the privacy-first app.

enum CameraTestPhase: Equatable {
    case eyeDetection
    case blinkVideo
    case complete
}

enum CameraRunState: Equatable {
    case idle
    case countdown
    case running
    case paused
    case finished
}

final class CameraSession: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var hasEyesInFrame = false
    @Published var blinkCount = 0
    @Published var liveEAR: Double?
    @Published var trackingLabel = "warming up"
    @Published var eyeStrainAssessment: EyeStrainAssessment?
    @Published var observationProgress = 0.0
    @Published var observedSeconds = 0.0
    @Published var testPhase: CameraTestPhase = .eyeDetection
    @Published var eyeDetectionProgress = 0.0
    @Published var eyeDetectionResult: EyeDetectionTestResult?
    @Published var blinkVideoProgress = 0.0
    @Published var analyzedFPS = 0.0
    @Published var runState: CameraRunState = .idle
    @Published var countdown = 0
    @Published var faceBox: CGRect?
    @Published var faceModelLines: [[CGPoint]] = []
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "luna.camera.frames")
    private let blinkEngine = BlinkEngine()
    private var strainMonitor = EyeStrainSignalMonitor()
    private var testPhaseState: CameraTestPhase = .eyeDetection
    private var eyeTestStart: TimeInterval?
    private var eyeTestFrames = 0
    private var eyeTestTrackedFrames = 0
    private var eyeTestBothVisible = false
    private var blinkTestStart: TimeInterval?
    private var fpsStart: TimeInterval?
    private var fpsFrames = 0
    private var analyzedFPSState = 0.0
    // The live counter mirrors the original visual blink cue (closed-eye
    // detection). The strain estimate still uses only completed blink events.
    private var displayedBlinkCount = 0
    private var displayBlinkWasClosed = false
    private var runStateState: CameraRunState = .idle
    private var lastFrameTimestamp: TimeInterval?
    private var pauseStarted: TimeInterval?
    private var pausedDuration: TimeInterval = 0
    private var interruptionObservers: [NSObjectProtocol] = []
    private var configured = false
    private var frameNumber = 0

    let eyeDetectionSeconds = 2
    let blinkVideoSeconds = 30
    var canCaptureAssessment: Bool {
        // Stop means “use what was recorded,” even when the user ends the
        // observation before the preferred quality window is complete.
        runState == .finished && testPhase == .complete && eyeStrainAssessment != nil
    }

    override init() {
        super.init()
        let center = NotificationCenter.default
        interruptionObservers = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
                self?.hasEyesInFrame = false
                self?.liveEAR = nil
                self?.trackingLabel = "camera interrupted · waiting to resume"
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
                self?.trackingLabel = "resuming camera"
                self?.configureAndStart()
            }
        ]
    }

    deinit {
        interruptionObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        if authorization == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.authorization = granted ? .authorized : .denied
                    if granted { self?.configureAndStart() }
                }
            }
        } else if authorization == .authorized {
            configureAndStart()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.blinkEngine.reset()
            self.strainMonitor.reset()
            self.resetTestState()
            self.runStateState = .idle
            DispatchQueue.main.async {
                self.blinkCount = 0
                self.liveEAR = nil
                self.trackingLabel = "paused"
                self.eyeStrainAssessment = nil
                self.observationProgress = 0
                self.observedSeconds = 0
                self.testPhase = .eyeDetection
                self.eyeDetectionProgress = 0
                self.eyeDetectionResult = nil
                self.blinkVideoProgress = 0
                self.analyzedFPS = 0
                self.runState = .idle
                self.countdown = 0
                self.faceBox = nil
                self.faceModelLines = []
            }
        }
    }

    func beginTests() {
        queue.async { [weak self] in
            guard let self else { return }
            self.blinkEngine.reset()
            self.strainMonitor.reset()
            self.resetTestState()
            self.runStateState = .countdown
            DispatchQueue.main.async {
                self.testPhase = .eyeDetection
                self.eyeDetectionProgress = 0
                self.eyeDetectionResult = nil
                self.blinkVideoProgress = 0
                self.eyeStrainAssessment = nil
                self.observationProgress = 0
                self.observedSeconds = 0
                self.blinkCount = 0
                self.trackingLabel = "get ready · face model will lock first"
                self.runState = .countdown
                self.countdown = 5
                self.advanceCountdown(from: 5)
            }
        }
    }

    func retryEyeDetection() { beginTests() }

    func pauseTests() {
        queue.async { [weak self] in
            guard let self, self.runStateState == .running else { return }
            self.runStateState = .paused
            self.pauseStarted = self.lastFrameTimestamp
            DispatchQueue.main.async {
                self.runState = .paused
                self.trackingLabel = "paused · resume when ready"
            }
        }
    }

    func resumeTests() {
        queue.async { [weak self] in
            guard let self, self.runStateState == .paused else { return }
            self.runStateState = .running
            DispatchQueue.main.async {
                self.runState = .running
                self.trackingLabel = self.testPhaseState == .eyeDetection ? "eye detection test · hold still" : "blink video test · keep both eyes visible"
            }
        }
    }

    func stopTests() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.runStateState == .running || self.runStateState == .paused else { return }
            let assessment: EyeStrainAssessment
            if self.testPhaseState == .blinkVideo {
                assessment = self.strainMonitor.assessment()
            } else {
                assessment = EyeStrainAssessment(
                    score: nil,
                    label: "eye observation stopped early",
                    dataStatus: "insufficient",
                    observedSeconds: 0,
                    trackingPercent: 0,
                    blinkRatePerMinute: nil,
                    prolongedClosureSeconds: 0,
                    partialClosurePercent: 0,
                    symptomCount: 0,
                    signals: ["The recording ended before the blink observation began."]
                )
            }
            self.testPhaseState = .complete
            self.runStateState = .finished
            DispatchQueue.main.async {
                self.testPhase = .complete
                self.eyeStrainAssessment = assessment
                self.runState = .finished
                self.blinkVideoProgress = self.testPhaseState == .complete ? self.blinkVideoProgress : 0
                self.observationProgress = self.strainMonitor.progress
                self.observedSeconds = self.strainMonitor.observedSeconds
                self.countdown = 0
                self.trackingLabel = "recording stopped · results ready"
            }
        }
    }

    private func advanceCountdown(from value: Int) {
        guard runState == .countdown else { return }
        if value <= 0 {
            queue.async { [weak self] in
                guard let self else { return }
                self.runStateState = .running
                DispatchQueue.main.async {
                    self.runState = .running
                    self.countdown = 0
                    self.trackingLabel = "eye detection test · hold still"
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.runState == .countdown else { return }
            self.countdown = value - 1
            self.advanceCountdown(from: value - 1)
        }
    }

    private func resetTestState() {
        testPhaseState = .eyeDetection
        eyeTestStart = nil
        eyeTestFrames = 0
        eyeTestTrackedFrames = 0
        eyeTestBothVisible = false
        blinkTestStart = nil
        fpsStart = nil
        fpsFrames = 0
        analyzedFPSState = 0
        displayedBlinkCount = 0
        displayBlinkWasClosed = false
        lastFrameTimestamp = nil
        pauseStarted = nil
        pausedDuration = 0
    }

    private func configureAndStart() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .high
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front), let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    return
                }
                self.session.addInput(input)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.setSampleBufferDelegate(self, queue: self.queue)
                if self.session.canAddOutput(output) { self.session.addOutput(output) }
                self.session.commitConfiguration()
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameNumber += 1
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp.isFinite else { return }
        lastFrameTimestamp = timestamp
        if fpsStart == nil { fpsStart = timestamp }
        fpsFrames += 1
        if let fpsStart, timestamp - fpsStart >= 1 {
            let fps = Double(fpsFrames) / max(0.001, timestamp - fpsStart)
            analyzedFPSState = fps
            DispatchQueue.main.async { self.analyzedFPS = fps }
            self.fpsStart = timestamp
            self.fpsFrames = 0
        }
        let request = VNDetectFaceLandmarksRequest { [weak self] request, _ in
            guard let self else { return }
            let faces = (request.results as? [VNFaceObservation]) ?? []
            let face = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
            let left = face.flatMap { Self.normalizedPoints($0.landmarks?.leftEye) }
            let right = face.flatMap { Self.normalizedPoints($0.landmarks?.rightEye) }
            let contour = face.flatMap { Self.normalizedPoints($0.landmarks?.faceContour) }
            let leftContour = left.flatMap(EyeLandmarkNormalizer.sixPointContour)
            let rightContour = right.flatMap(EyeLandmarkNormalizer.sixPointContour)
            let bothEyesVisible = leftContour != nil && rightContour != nil
            let modelLines = [contour, left, right].compactMap { $0 }.map { $0.map { CGPoint(x: $0.x, y: $0.y) } }
            DispatchQueue.main.async {
                self.faceBox = face?.boundingBox
                self.faceModelLines = modelLines
                if self.runState == .idle || self.runState == .countdown {
                    self.hasEyesInFrame = bothEyesVisible
                    self.trackingLabel = bothEyesVisible ? "face model ready · hold the phone steady" : "show both eyes in frame"
                }
            }
            guard self.runStateState == .running else { return }
            if let pauseStarted = self.pauseStarted {
                self.pausedDuration += max(0, timestamp - pauseStarted)
                self.pauseStarted = nil
            }
            let update = self.blinkEngine.process(left: leftContour, right: rightContour, timestamp: timestamp)
            self.recordTestFrame(update, timestamp: timestamp - self.pausedDuration, bothEyesVisible: bothEyesVisible)
        }
        try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .leftMirrored, options: [:]).perform([request])
    }

    private func recordTestFrame(_ update: BlinkUpdate, timestamp: TimeInterval, bothEyesVisible: Bool) {
        switch testPhaseState {
        case .eyeDetection:
            if eyeTestStart == nil { eyeTestStart = timestamp }
            eyeTestFrames += 1
            if bothEyesVisible && update.isFaceTracked { eyeTestTrackedFrames += 1 }
            eyeTestBothVisible = bothEyesVisible
            let elapsed = max(0, timestamp - (eyeTestStart ?? timestamp))
            let result = EyeDetectionTestResult.evaluate(
                observedSeconds: elapsed,
                analyzedFrames: eyeTestFrames,
                trackedFrames: eyeTestTrackedFrames,
                bothEyesVisible: eyeTestBothVisible,
                minimumSeconds: Double(eyeDetectionSeconds)
            )
            DispatchQueue.main.async {
                self.hasEyesInFrame = bothEyesVisible
                self.liveEAR = update.meanEAR
                self.eyeDetectionProgress = min(1, elapsed / Double(self.eyeDetectionSeconds))
                self.eyeDetectionResult = result
                self.trackingLabel = bothEyesVisible ? "eye detection test · hold still" : "eye detection test · show both eyes"
            }
            if elapsed >= Double(eyeDetectionSeconds) {
                if result.passed {
                    testPhaseState = .blinkVideo
                    blinkTestStart = timestamp
                    blinkEngine.reset()
                    strainMonitor.reset()
                    DispatchQueue.main.async {
                        self.testPhase = .blinkVideo
                        self.eyeDetectionProgress = 1
                        self.blinkVideoProgress = 0
                        self.eyeStrainAssessment = nil
                        self.observationProgress = 0
                        self.observedSeconds = 0
                        self.blinkCount = 0
                        self.trackingLabel = "blink video test · keep both eyes visible"
                    }
                } else {
                    eyeTestStart = nil
                    eyeTestFrames = 0
                    eyeTestTrackedFrames = 0
                    eyeTestBothVisible = false
                    DispatchQueue.main.async {
                        self.testPhase = .eyeDetection
                        self.trackingLabel = "eye detection needs a clearer view · retrying"
                    }
                }
            }
        case .blinkVideo:
            if blinkTestStart == nil { blinkTestStart = timestamp }
            strainMonitor.ingest(update, timestamp: timestamp)
            let elapsed = max(0, timestamp - (blinkTestStart ?? timestamp))
            let assessment = strainMonitor.assessment()
            let displayBlinkStarted = update.isClosed && !displayBlinkWasClosed
            displayBlinkWasClosed = update.isClosed
            if displayBlinkStarted {
                displayedBlinkCount += 1
            }
            let visibleBlinkCount = max(displayedBlinkCount, update.blinkCount)
            DispatchQueue.main.async {
                self.hasEyesInFrame = bothEyesVisible
                self.liveEAR = update.meanEAR
                self.blinkCount = visibleBlinkCount
                // Keep the previous live feedback behavior: the cue appears
                // as soon as the bilateral closure is detected. The display
                // counter above advances on that same detector event.
                self.trackingLabel = bothEyesVisible
                    ? (update.isPartialClosure ? "partial closure · keep both eyes visible" : (update.isClosed ? "blink recorded" : "blink video test · keep still"))
                    : "blink video test · show both eyes"
                self.eyeStrainAssessment = assessment
                self.observationProgress = self.strainMonitor.progress
                self.observedSeconds = self.strainMonitor.observedSeconds
                self.blinkVideoProgress = min(1, elapsed / Double(self.blinkVideoSeconds))
            }
            if elapsed >= Double(blinkVideoSeconds) {
                testPhaseState = .complete
                runStateState = .finished
                DispatchQueue.main.async {
                    self.testPhase = .complete
                    self.runState = .finished
                    self.blinkVideoProgress = 1
                    self.trackingLabel = BlinkVideoQuality.isUsable(fps: self.analyzedFPSState, assessment: assessment) ? "blink test complete" : "blink test complete · video quality insufficient"
                }
            }
        case .complete:
            break
        }
    }

    private static func normalizedPoints(_ region: VNFaceLandmarkRegion2D?) -> [EyePoint]? {
        guard let points = region?.normalizedPoints, points.count >= 6 else { return nil }
        return points.map(EyePoint.init)
    }
}

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CameraSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        configure(connection: view.previewLayer.connection)
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {
        view.previewLayer.session = camera.session
        configure(connection: view.previewLayer.connection)
    }

    private func configure(connection: AVCaptureConnection?) {
        guard let connection else { return }
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct FaceModelOverlay: View {
    let faceBox: CGRect?
    let modelLines: [[CGPoint]]
    let eyesTracked: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let faceBox {
                    let rect = CGRect(
                        x: faceBox.minX * proxy.size.width,
                        y: (1 - faceBox.maxY) * proxy.size.height,
                        width: faceBox.width * proxy.size.width,
                        height: faceBox.height * proxy.size.height
                    )
                    RoundedRectangle(cornerRadius: 32)
                        .stroke(eyesTracked ? Color.white.opacity(0.88) : Color.white.opacity(0.42), style: StrokeStyle(lineWidth: 2, dash: eyesTracked ? [] : [7, 6]))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    ForEach(Array(modelLines.enumerated()), id: \.offset) { _, line in
                        Path { path in
                            for (index, point) in line.enumerated() {
                                let mapped = CGPoint(
                                    x: (faceBox.minX + point.x * faceBox.width) * proxy.size.width,
                                    y: (1 - (faceBox.minY + point.y * faceBox.height)) * proxy.size.height
                                )
                                if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
                            }
                        }
                        .stroke(Color.lunaPeach.opacity(0.92), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                        ForEach(Array(line.enumerated()), id: \.offset) { _, point in
                            Circle()
                                .fill(Color.white.opacity(0.95))
                                .frame(width: 4, height: 4)
                                .position(x: (faceBox.minX + point.x * faceBox.width) * proxy.size.width,
                                          y: (1 - (faceBox.minY + point.y * faceBox.height)) * proxy.size.height)
                        }
                    }
                    Text("face model")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.82))
                        .position(x: rect.midX, y: rect.maxY + 16)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct CaptureView: View {
    let done: (ScreeningReport) -> Void
    let back: () -> Void
    @StateObject private var camera = CameraSession()
    @State private var closeRotation = 0.0

    private var phaseTitle: String {
        switch camera.testPhase {
        case .eyeDetection: return "eye detection"
        case .blinkVideo: return "blink observation"
        case .complete: return "test complete"
        }
    }

    private var phaseDetail: String {
        switch camera.runState {
        case .idle: return "When you are ready, start a short on-device check."
        case .countdown: return "Center your face. The eye check starts at zero."
        case .running:
            return camera.testPhase == .eyeDetection ? "Hold still while the face model finds both eyes." : "Blink naturally while the live signal is measured."
        case .paused: return "The camera is paused. Resume when your face is centered."
        case .finished:
            return camera.eyeStrainAssessment?.score == nil ? "The recording is saved as insufficient data; the app will not invent a score." : "Your signal is ready to save to this account."
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.authorization == .authorized {
                CameraPreview(camera: camera).ignoresSafeArea()
            }
            Color.black.opacity(camera.runState == .countdown ? 0.08 : 0.26).ignoresSafeArea()
            FaceModelOverlay(faceBox: camera.faceBox, modelLines: camera.faceModelLines, eyesTracked: camera.hasEyesInFrame).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.72)) { closeRotation = 30 }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { back() }
                    } label: {
                        Image(systemName: "xmark").foregroundStyle(.white).frame(width: 44, height: 44).background(.white.opacity(0.14)).clipShape(Circle())
                    }
                    .rotationEffect(.degrees(closeRotation))
                    .buttonStyle(LunaPressStyle())
                    Spacer()
                    Text(camera.authorization == .authorized ? phaseTitle : "camera access")
                        .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 8).background(.white.opacity(0.14)).clipShape(Capsule())
                }
                .padding(.top, 6)

                VStack(alignment: .leading, spacing: 7) {
                    Text(camera.authorization == .authorized ? camera.trackingLabel : "camera permission is required")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(phaseDetail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.78))
                    Text(camera.testPhase == .eyeDetection
                         ? "purpose · confirm the front camera can track both eyes before measuring blinks"
                         : "purpose · measure blink frequency, incomplete closures, and prolonged closures in this window")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.62))
                }
                .foregroundStyle(.white)
                .padding(16)
                .background(.black.opacity(0.42))
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 18)

                Spacer()

                if camera.authorization == .authorized && camera.runState == .running {
                    Text(camera.testPhase == .eyeDetection
                         ? "eye check · \(Int(camera.eyeDetectionProgress * 100))%"
                         : "recording · \(Int(camera.blinkVideoProgress * 100))% · \(camera.blinkCount) blink\(camera.blinkCount == 1 ? "" : "s")")
                        .foregroundStyle(.white).font(.system(size: 15, weight: .medium))
                    ProgressView(value: camera.testPhase == .eyeDetection ? camera.eyeDetectionProgress : camera.blinkVideoProgress)
                        .tint(.white).frame(maxWidth: 250).padding(.top, 8)
                }
                if camera.authorization == .authorized && camera.testPhase == .blinkVideo && camera.runState == .running {
                    Text("live video analyzed on-device · \(Int(camera.analyzedFPS.rounded())) fps · not saved")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.72)).padding(.top, 6)
                }

                Spacer()

                if camera.authorization == .authorized {
                    switch camera.runState {
                    case .idle:
                        BlackButton(title: "start eye test", icon: "play.fill") { camera.beginTests() }
                        Text("5-second countdown · then a 30-second blink observation")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.72))
                    case .countdown:
                        Text("starting eye test")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.72))
                    case .running:
                        HStack(spacing: 10) {
                            BlackButton(title: "pause", icon: "pause.fill") { camera.pauseTests() }
                            BlackButton(title: "stop", icon: "stop.fill") { camera.stopTests() }
                        }
                    case .paused:
                        HStack(spacing: 10) {
                            BlackButton(title: "resume", icon: "play.fill") { camera.resumeTests() }
                            BlackButton(title: "stop", icon: "stop.fill") { camera.stopTests() }
                        }
                    case .finished:
                        if camera.canCaptureAssessment {
                            BlackButton(title: "save results", icon: "checkmark") {
                                if let assessment = camera.eyeStrainAssessment { done(MockBackend.report(eyeStrain: assessment)) }
                            }
                        } else {
                            BlackButton(title: "try again", icon: "arrow.clockwise") { camera.beginTests() }
                        }
                    }
                } else {
                    BlackButton(title: "allow camera in settings", icon: "camera.fill") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 26)

            if camera.runState == .countdown {
                Color.white.opacity(0.94).ignoresSafeArea()
                VStack(spacing: 12) {
                    Text("center your face").font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(Color.lunaInk)
                    Text("\(max(1, camera.countdown))")
                        .font(.system(size: 112, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.lunaInk)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.34, dampingFraction: 0.7), value: camera.countdown)
                    Text("eye test begins next").font(.system(size: 13)).foregroundStyle(Color.lunaBrown)
                }
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }
}
#endif

// MARK: - Blink rhythm and settings

struct BlinkRhythmView: View {
    @ObservedObject var store: AccountStore

    private var latest: ScreeningReport? {
        let saved = store.activeAccount?.reportHistory ?? []
        return (saved + (store.activeAccount?.report.map { [$0] } ?? []))
            .max { $0.capturedAt < $1.capturedAt }
    }

    private var check: FunctionalEyeCheck? { latest?.functionalCheck }
    private var intervals: [Double] { check?.hiddenCameraBlinkIntervals ?? [] }
    private var rateText: String {
        guard let rate = check?.hiddenCameraBlinkRatePerMinute else { return "rate unavailable" }
        return String(format: "%.1f blinks/min", rate)
    }
    private var averageGapText: String {
        guard !intervals.isEmpty else { return "—" }
        return String(format: "%.2f s", intervals.reduce(0, +) / Double(intervals.count))
    }
    private var rangeText: String {
        guard let shortest = intervals.min(), let longest = intervals.max() else { return "—" }
        return String(format: "%.2f–%.2f s", shortest, longest)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RetroTypeSwitcher(title: "blink rhythm", phrases: ["latest session", "gap length", "pattern only"])
                if let latest, let check {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("LATEST RECORDED RHYTHM").font(.system(size: 10, weight: .black, design: .monospaced)).foregroundStyle(Color.lunaBlue)
                            Text(latest.capturedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                            HStack(spacing: 8) {
                                rhythmMetric("RATE", rateText)
                                rhythmMetric("AVERAGE GAP", averageGapText)
                                rhythmMetric("RANGE", rangeText)
                            }
                            Text("Each bar is one gap between detected blinks. Taller means more time passed before the next blink.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            if intervals.isEmpty {
                                Text("Not enough detected blinks to show spacing yet.")
                                    .font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(Color.lunaBrown)
                            } else {
                                BlinkSpacingChart(intervals: intervals).frame(height: 174)
                            }
                            Text("Observed blink rhythm: \(check.blinkSignalMeaning). This screen describes the latest signal and does not change scoring.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("NO BLINK TIMING YET").font(.system(size: 12, weight: .black, design: .monospaced)).foregroundStyle(Color.lunaBlue)
                            Text("No blink timing is saved yet. A recorded blink session will appear here.")
                                .font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func rhythmMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 8, weight: .black, design: .monospaced)).foregroundStyle(Color.lunaBlue)
            Text(value).font(.system(size: 12, weight: .bold, design: .monospaced)).lineLimit(1, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.lunaSignal.opacity(0.22))
        .overlay(Rectangle().stroke(Color.lunaInk.opacity(0.18), lineWidth: 1))
    }
}

struct BlinkSpacingChart: View {
    let intervals: [Double]

    var body: some View {
        let visibleIntervals = Array(intervals.suffix(10))
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("GAP LENGTH · SECONDS").font(.system(size: 9, weight: .black, design: .monospaced)).foregroundStyle(Color.lunaBlue)
                Spacer()
                Text("LAST \(visibleIntervals.count)").font(.system(size: 9, weight: .black, design: .monospaced)).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let maximum = max(1.0, visibleIntervals.max() ?? 1.0)
                ZStack(alignment: .bottomLeading) {
                    VStack(spacing: 0) {
                        Rectangle().fill(Color.lunaInk.opacity(0.08)).frame(height: 1)
                        Spacer()
                        Rectangle().fill(Color.lunaInk.opacity(0.08)).frame(height: 1)
                        Spacer()
                        Rectangle().fill(Color.lunaInk.opacity(0.20)).frame(height: 1)
                    }
                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(Array(visibleIntervals.enumerated()), id: \.offset) { index, interval in
                            VStack(spacing: 4) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(index.isMultiple(of: 2) ? Color.lunaBlue : Color.lunaLavender)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: max(12, (proxy.size.height - 22) * CGFloat(interval / maximum)))
                                Text("\(index + 1)")
                                    .font(.system(size: 8, weight: .black, design: .monospaced))
                                    .foregroundStyle(Color.lunaInk.opacity(0.7))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            .frame(height: 132)
        }
        .padding(10)
        .background(Color.lunaPaper)
        .overlay(Rectangle().stroke(Color.lunaInk.opacity(0.30), lineWidth: 1))
        .animation(.easeOut(duration: 0.25), value: visibleIntervals)
    }
}

struct SettingsView: View {
    @ObservedObject var store: AccountStore
    @Binding var contrast: Bool
    let signOut: () -> Void
    @State private var search = ""
    @AppStorage("luna.fontStyle") private var fontStyle = LunaFontStyle.mono.rawValue
    @AppStorage("luna.autoComfortBrightness") private var autoComfortBrightness = false
    @State private var settingsMessage: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RetroTypeSwitcher(title: "settings", phrases: ["clear type", "gentle display", "private by default"])
                GooeyInput(text: $search, placeholder: "search settings")
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("signed in as").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(store.activeAccount?.email ?? "no account")
                        Text(store.activeAccount?.provider.capitalized ?? "")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 86, alignment: .center)
                    .multilineTextAlignment(.center)
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 5) {
                            ForEach(LunaFontStyle.allCases) { style in
                                Button {
                                    fontStyle = style.rawValue
                                } label: {
                                    Text(style.label.uppercased())
                                        .font(.system(size: 9, weight: .black, design: .monospaced))
                                        .foregroundStyle(fontStyle == style.rawValue ? Color.lunaPaper : Color.lunaInk)
                                        .frame(maxWidth: .infinity).frame(height: 36)
                                        .background(fontStyle == style.rawValue ? Color.lunaInk : Color.lunaPaper)
                                        .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 1))
                                }
                                .buttonStyle(LunaPressStyle())
                            }
                        }
                        Text("Type style updates the reading rhythm across luna. Choose the one that feels clearest during a check-in.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Divider()
                        RetroToggle(title: "high contrast", isOn: $contrast)
                        Divider()
                        RetroToggle(title: "automatic comfort brightness", isOn: $autoComfortBrightness)
                            .onChange(of: autoComfortBrightness) { _, enabled in
                                if enabled { applyComfortBrightness(showMessage: true) }
                            }
                        Text("Applies a moderate 38% brightness preset while you use luna. It does not pretend to measure the room or your eyes.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        BlackButton(title: "apply comfort brightness", icon: "sun.max") {
                            applyComfortBrightness(showMessage: true)
                        }
                    }
                }
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                } label: {
                    Label("open iOS settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .foregroundStyle(.white).background(Color.lunaInk).clipShape(Rectangle())
                        .overlay(Rectangle().stroke(Color.lunaSignal, lineWidth: 2))
                }
                .buttonStyle(LunaPressStyle())
                Button("sign out", action: signOut)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .foregroundStyle(.white).background(Color.lunaInk).clipShape(Rectangle())
                    .overlay(Rectangle().stroke(Color.lunaSignal, lineWidth: 2))
                    .buttonStyle(LunaPressStyle())
            }
            .padding(20)
        }
        .alert("display comfort", isPresented: Binding(get: { settingsMessage != nil }, set: { if !$0 { settingsMessage = nil } })) {
            Button("ok") { settingsMessage = nil }
        } message: {
            Text(settingsMessage ?? "")
        }
    }

    private func applyComfortBrightness(showMessage: Bool) {
        let target: CGFloat = 0.38
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first ?? UIScreen.main
        screen.brightness = target
        if showMessage { settingsMessage = "Brightness set to the 38% comfort preset. Adjust it again if reading feels difficult." }
    }
}

// MARK: - Shared visual components

struct RetroGridBackground: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.lunaBackground))
            var grid = Path()
            stride(from: 0.0, through: size.width, by: 24).forEach { x in
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            stride(from: 0.0, through: size.height, by: 24).forEach { y in
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(.lunaInk.opacity(0.045)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

struct LiquidGlass: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(Rectangle().fill(Color.lunaPaper))
            .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 2))
            .clipShape(Rectangle())
            .background(Rectangle().fill(Color.lunaInk).offset(x: 4, y: 4))
    }
}

extension View {
    func liquidGlass(_ radius: CGFloat = 24) -> some View { modifier(LiquidGlass(radius: radius)) }
    func field() -> some View {
        padding(.horizontal, 14)
            .frame(height: 52)
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .liquidGlass(0)
            .clipShape(Rectangle())
    }
}

struct RetroProgressBar: View {
    let value: Double
    let total: Double
    var color: Color = .lunaBlue

    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, value / total))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.lunaInk.opacity(0.10))
                Rectangle().fill(color).frame(width: proxy.size.width * progress)
            }
            .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 2))
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.18), value: progress)
    }
}

struct RetroToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { isOn.toggle() }
        } label: {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                Spacer()
                ZStack {
                    Rectangle().fill(isOn ? Color.lunaSafe : Color.lunaPaper)
                    if isOn { Image(systemName: "checkmark").font(.system(size: 12, weight: .black)).foregroundStyle(Color.lunaPaper) }
                }
                .frame(width: 28, height: 28)
                .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 2))
            }
            .foregroundStyle(Color.lunaInk)
        }
        .buttonStyle(LunaPressStyle())
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.lunaPaper)
            .overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 2))
            .background(Rectangle().fill(Color.lunaInk).offset(x: 4, y: 4))
    }
}

struct Brand: View {
    let foreground: Color
    var showIcon = true
    var body: some View {
        HStack(spacing: 12) {
            if showIcon {
                Image(systemName: "shield.checkered").font(.system(size: 22, weight: .black)).foregroundStyle(Color.lunaInk).frame(width: 48, height: 48).background(Color.lunaSignal).overlay(Rectangle().stroke(Color.lunaInk, lineWidth: 2))
            }
            Text("LUNA").font(.system(size: 21, weight: .black, design: .monospaced)).tracking(-1).foregroundStyle(foreground)
        }
    }
}

enum LunaFontStyle: String, CaseIterable, Identifiable {
    case rounded, mono, serif
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rounded: return "Console"
        case .mono: return "Terminal"
        case .serif: return "System"
        }
    }
    var baseFont: Font {
        switch self {
        case .rounded: return .system(size: 16, weight: .medium, design: .monospaced)
        case .mono: return .system(size: 16, weight: .regular, design: .monospaced)
        case .serif: return .system(size: 16, weight: .semibold, design: .default)
        }
    }
}

struct RetroTypeSwitcher: View {
    let title: String
    let phrases: [String]
    @State private var phase = 0

    private var weights: [Font.Weight] { [.black, .bold, .heavy] }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Rectangle().fill(Color.lunaSafe).frame(width: 9, height: 9)
                Text("LUNA // SAFETY DESK")
            }
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .foregroundStyle(Color.lunaBlue)
            Text(title.uppercased())
                .font(.system(size: 27, weight: weights[phase % weights.count], design: .monospaced))
                .tracking(-1.2)
                .foregroundStyle(Color.lunaInk)
                .contentTransition(.interpolate)
            if !phrases.isEmpty {
                Text(phrases[phase % phrases.count])
                    .id(phase)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.lunaAlert)
                    .transition(.asymmetric(insertion: .push(from: .bottom), removal: .opacity))
            }
        }
        .task {
            guard !phrases.isEmpty else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.48, dampingFraction: 0.82)) { phase += 1 }
            }
        }
    }
}

struct TextSwitcher: View {
    let phrases: [String]
    var interval: TimeInterval = 3.0
    @State private var index = 0

    var body: some View {
        Group {
            if phrases.isEmpty { EmptyView() }
            else { Text(phrases[index % phrases.count]).id(index % phrases.count).transition(.asymmetric(insertion: .push(from: .bottom), removal: .opacity)) }
        }
        .clipped()
        .task {
            guard phrases.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.35)) { index += 1 }
            }
        }
    }
}

struct LunaPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .offset(x: configuration.isPressed ? 3 : 0, y: configuration.isPressed ? 3 : 0)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.snappy(duration: 0.13), value: configuration.isPressed)
    }
}

struct BlackButton: View {
    let title: String
    var icon: String?
    let action: () -> Void
    var disabled = false
    @State private var shimmer = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .frame(maxWidth: .infinity).frame(height: 54)
            .font(.system(size: 14, weight: .black, design: .monospaced))
            .foregroundStyle(.white)
            .background(Color.lunaInk).clipShape(Rectangle())
            .overlay(Rectangle().stroke(Color.lunaSignal, lineWidth: 2))
            .overlay(alignment: .leading) {
                Rectangle().fill(shimmer ? Color.lunaSafe : Color.lunaSignal).frame(width: shimmer ? 12 : 5)
            }
            .background(Rectangle().fill(Color.lunaInk.opacity(0.75)).offset(x: 4, y: 4))
        }
        .buttonStyle(LunaPressStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .onAppear { withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: true)) { shimmer = true } }
    }
}

struct GooeyInput: View {
    @Binding var text: String
    let placeholder: String
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.square.fill") }.buttonStyle(LunaPressStyle())
            }
        }
        .padding(.horizontal, 14).frame(height: 52).liquidGlass(0).clipShape(Rectangle())
    }
}

struct LunaNav: View {
    @Binding var route: LunaRoute
    var body: some View {
        HStack(spacing: 3) {
            NavButton(title: "home", icon: "house", accent: .lunaBeige, active: route == .home) { route = .home }
            NavButton(title: "check-in", icon: "hand.tap", accent: .lunaCoral, active: route == .checkin) { route = .checkin }
            NavButton(title: "blink rhythm", icon: "waveform.path.ecg", accent: .lunaLavender, active: route == .rhythm) { route = .rhythm }
            NavButton(title: "improve", icon: "sparkles", accent: .lunaTeal, active: route == .wellness) { route = .wellness }
            NavButton(title: "settings", icon: "gearshape", accent: .lunaPeach, active: route == .settings) { route = .settings }
        }
        .padding(.horizontal, 5).padding(.top, 8).padding(.bottom, 4)
        .background(Color.lunaPaper)
        .overlay(alignment: .top) { Rectangle().fill(Color.lunaInk).frame(height: 4) }
    }
}

struct NavButton: View {
    let title: String
    let icon: String
    let accent: Color
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                Text(title.uppercased()).font(.system(size: 8, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(active ? Color.lunaInk : .secondary)
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(active ? accent.opacity(0.9) : Color.clear)
            .clipShape(Rectangle())
            .overlay(Rectangle().stroke(Color.lunaInk.opacity(active ? 1 : 0.16), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if active { Rectangle().fill(Color.lunaInk).frame(width: 28, height: 5).offset(y: -3) }
            }
            .offset(y: active ? -3 : 0)
            .animation(.snappy(duration: 0.18), value: active)
        }
        .buttonStyle(LunaPressStyle())
    }
}

extension Color {
    static let lunaBackground = Color(red: 0.975, green: 0.948, blue: 0.885)
    static let lunaPaper = Color(red: 0.995, green: 0.982, blue: 0.944)
    static let lunaInk = Color(red: 0.08, green: 0.14, blue: 0.21)
    static let lunaSignal = Color(red: 0.72, green: 0.88, blue: 0.96)
    static let lunaSafe = Color(red: 0.61, green: 0.84, blue: 0.76)
    static let lunaAlert = Color(red: 0.91, green: 0.58, blue: 0.59)
    static let lunaBlue = Color(red: 0.30, green: 0.60, blue: 0.79)
    static let lunaBeige = Color(red: 0.95, green: 0.82, blue: 0.68)
    static let lunaBrown = Color(red: 0.30, green: 0.25, blue: 0.23)
    static let lunaClay = Color(red: 0.86, green: 0.66, blue: 0.61)
    static let lunaLavender = Color(red: 0.78, green: 0.73, blue: 0.91)
    static let lunaPurple = Color(red: 0.48, green: 0.42, blue: 0.70)
    static let lunaPeach = Color(red: 0.96, green: 0.76, blue: 0.61)
    static let lunaCoral = Color(red: 0.91, green: 0.58, blue: 0.59)
    static let lunaTeal = Color(red: 0.38, green: 0.72, blue: 0.70)
}
