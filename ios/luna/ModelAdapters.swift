import Combine
import CryptoKit
import Foundation
import Security

struct ScreeningReport: Codable, Equatable {
    let capturedAt: Date
    let summary: String
    let quality: String
    let interpretation: String
    var eyeStrain: EyeStrainAssessment?
    var symptoms: [String]?
    var contexts: [String]? = nil
    var severity: Int? = nil
    var functionalCheck: FunctionalEyeCheck? = nil
}

struct FunctionalEyeCheck: Codable, Equatable {
    var leftClarityLine: String
    var rightClarityLine: String
    var contrastCorrect: Int
    var contrastTotal: Int
    var searchCorrect: Int
    var searchTotal: Int
    var medianSearchMilliseconds: Int
    var focusRecoveryMilliseconds: Int
    var strainLoad: Int
    var confidence: Int
    var hiddenCameraSeconds: Int? = nil
    var hiddenCameraTrackingPercent: Int? = nil
    var hiddenCameraBlinkCount: Int? = nil
    var hiddenCameraSignalLoad: Int? = nil
    var hiddenCameraBlinkRatePerMinute: Double? = nil
    var hiddenCameraBlinkRhythmVariabilityPercent: Int? = nil
    var hiddenCameraPartialClosurePercent: Int? = nil
    var hiddenCameraBlinkIntervals: [Double]? = nil

    var blinkSignalMeaning: String {
        guard let rate = hiddenCameraBlinkRatePerMinute else { return "signal unavailable" }
        if hiddenCameraPartialClosurePercent.map({ $0 >= 15 }) == true { return "partial closures" }
        if hiddenCameraBlinkRhythmVariabilityPercent.map({ $0 >= 55 }) == true { return "irregular timing" }
        if rate < 8 { return "low blink frequency" }
        return "steady in this window"
    }

    var strainBand: String {
        switch strainLoad {
        case 0..<25: return "low load"
        case 25..<50: return "mild load"
        case 50..<75: return "elevated load"
        default: return "high load"
        }
    }
}

struct RoutineActivity: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var startTime: Date
    var endTime: Date

    init(id: UUID = UUID(), name: String = "", startTime: Date = Date(), endTime: Date = Date().addingTimeInterval(30 * 60)) {
        self.id = id
        self.name = name
        self.startTime = startTime
        self.endTime = endTime
    }

    var durationMinutes: Int {
        max(0, Int(endTime.timeIntervalSince(startTime) / 60))
    }
}

struct DailySchedule: Codable, Equatable {
    var wakeTime: Date
    var sleepTime: Date
    var focusMinutes: Int
    var waterGoal: Int
    var routineTitle: String
    var routineText: String
    var cuisine: String
    var activities: [RoutineActivity]

    init(wakeTime: Date, sleepTime: Date, focusMinutes: Int, waterGoal: Int, routineTitle: String = "", routineText: String = "", cuisine: String = "", activities: [RoutineActivity] = []) {
        self.wakeTime = wakeTime
        self.sleepTime = sleepTime
        self.focusMinutes = focusMinutes
        self.waterGoal = waterGoal
        self.routineTitle = routineTitle
        self.routineText = routineText
        self.cuisine = cuisine
        self.activities = activities
    }

    private enum CodingKeys: String, CodingKey {
        case wakeTime, sleepTime, focusMinutes, waterGoal, routineTitle, routineText, cuisine, activities
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        wakeTime = try values.decode(Date.self, forKey: .wakeTime)
        sleepTime = try values.decode(Date.self, forKey: .sleepTime)
        focusMinutes = try values.decode(Int.self, forKey: .focusMinutes)
        waterGoal = try values.decode(Int.self, forKey: .waterGoal)
        routineTitle = try values.decodeIfPresent(String.self, forKey: .routineTitle) ?? ""
        routineText = try values.decodeIfPresent(String.self, forKey: .routineText) ?? ""
        cuisine = try values.decodeIfPresent(String.self, forKey: .cuisine) ?? ""
        activities = try values.decodeIfPresent([RoutineActivity].self, forKey: .activities) ?? []
    }

    var sleepHours: Double {
        let calendar = Calendar.current
        var seconds = sleepTime.timeIntervalSince(wakeTime)
        if seconds < 0 { seconds += 24 * 60 * 60 }
        _ = calendar
        return seconds / 3600
    }
}

enum WellnessMetrics {
    static func habitsScore(for schedule: DailySchedule?) -> Int? {
        guard let schedule else { return nil }
        var score = 0
        let sleep = schedule.sleepHours
        if sleep >= 7 && sleep <= 9 { score += 35 }
        else if sleep >= 6 { score += 25 }
        else { score += 10 }
        if !schedule.activities.isEmpty { score += 25 }
        if schedule.activities.contains(where: { $0.durationMinutes >= 45 }) { score += 20 }
        else if !schedule.activities.isEmpty { score += 10 }
        if schedule.waterGoal >= 6 { score += 20 }
        else if schedule.waterGoal >= 4 { score += 12 }
        return min(100, score)
    }

    /// Combines the camera estimate with the routine score when both exist.
    /// The camera estimate carries the saved comfort check, so selecting dry
    /// or gritty eyes changes this score rather than disappearing on the
    /// report screen.
    static func eyeWellnessScore(report: ScreeningReport?, schedule: DailySchedule?) -> Int? {
        let scanScore: Int? = {
            if let functional = report?.functionalCheck {
                return max(0, 100 - functional.strainLoad)
            }
            return report?.eyeStrain?.score
        }()
        let routineScore = habitsScore(for: schedule)
        switch (scanScore, routineScore) {
        case let (scan?, routine?):
            return Int((Double(scan) * 0.7 + Double(routine) * 0.3).rounded())
        case let (scan?, nil):
            return scan
        case let (nil, routine?):
            return routine
        case (nil, nil):
            return nil
        }
    }

    static func comfortTips(for report: ScreeningReport?) -> [String] {
        let symptoms = Set(report?.symptoms ?? [])
        guard !symptoms.isEmpty else { return [] }
        var tips: [String] = []
        if symptoms.contains("dry or gritty eyes") {
            tips.append("Dry or gritty eyes was included in your score. Take regular distance breaks, blink fully, and avoid directing a fan or vent at your eyes.")
        }
        if symptoms.contains("tired eyes") || symptoms.contains("blurred focus") {
            tips.append("For tired or blurred focus, pause near work and refocus on something farther away before returning to the screen.")
        }
        if symptoms.contains("headache near screens") || symptoms.contains("light sensitivity") {
            tips.append("For headaches or light sensitivity, reduce glare and pause the task; persistent or sudden symptoms deserve an eye-care professional's advice.")
        }
        return tips
    }

    static func tips(for schedule: DailySchedule?) -> [String] {
        guard let schedule else {
            return ["Build a routine with your real activities first; luna will add practical break and water cues around it."]
        }
        var tips: [String] = []
        if schedule.sleepHours < 7 { tips.append("Your planned sleep window is under 7 hours. If possible, move bedtime earlier and keep wake time consistent.") }
        if schedule.activities.isEmpty { tips.append("Add the activities that make up your day so your break guidance is based on your schedule.") }
        if schedule.activities.contains(where: { $0.durationMinutes >= 45 }) { tips.append("Long focus blocks benefit from a 20-second distance look about every 20 minutes; add it as a cue between activities.") }
        if schedule.waterGoal < 6 { tips.append("Add water at wake-up, meals, and one or two activity transitions instead of waiting until you feel thirsty.") }
        if tips.isEmpty { tips.append("Your routine covers the basics. Keep the sleep window consistent and use distance breaks during long near-work sessions.") }
        return tips
    }

    static func supportItems(for schedule: DailySchedule) -> [String] {
        var items: [String] = []
        let sorted = schedule.activities.sorted { $0.startTime < $1.startTime }
        for activity in sorted where activity.durationMinutes >= 45 {
            items.append("After \(activity.name.isEmpty ? "this activity" : activity.name): look at least 20 feet away for 20 seconds, then relax your focus.")
        }
        if !sorted.isEmpty {
            items.append("Water cue: drink at wake-up and at each meal; add a bottle beside your longest activity.")
        }
        if schedule.sleepHours < 7 {
            items.append("Sleep cue: start winding down before your planned bedtime and keep the room comfortably dark.")
        }
        return items
    }
}

struct LunaAccount: Codable, Equatable {
    let email: String
    var name: String
    var provider: String
    var passwordDigest: String?
    var verified: Bool
    var report: ScreeningReport?
    var schedule: DailySchedule?
    var reportHistory: [ScreeningReport] = []
    var waterByDay: [String: Int] = [:]
    var screenFreeMinutesByDay: [String: Int] = [:]
    var breathingMinutesByDay: [String: Int] = [:]

    private enum CodingKeys: String, CodingKey {
        case email, name, provider, passwordDigest, verified, report, schedule, reportHistory, waterByDay, screenFreeMinutesByDay, breathingMinutesByDay
    }

    init(email: String, name: String, provider: String, passwordDigest: String?, verified: Bool, report: ScreeningReport?, schedule: DailySchedule?, reportHistory: [ScreeningReport] = [], waterByDay: [String: Int] = [:], screenFreeMinutesByDay: [String: Int] = [:], breathingMinutesByDay: [String: Int] = [:]) {
        self.email = email
        self.name = name
        self.provider = provider
        self.passwordDigest = passwordDigest
        self.verified = verified
        self.report = report
        self.schedule = schedule
        self.reportHistory = reportHistory
        self.waterByDay = waterByDay
        self.screenFreeMinutesByDay = screenFreeMinutesByDay
        self.breathingMinutesByDay = breathingMinutesByDay
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        email = try values.decode(String.self, forKey: .email)
        name = try values.decode(String.self, forKey: .name)
        provider = try values.decode(String.self, forKey: .provider)
        passwordDigest = try values.decodeIfPresent(String.self, forKey: .passwordDigest)
        verified = try values.decode(Bool.self, forKey: .verified)
        report = try values.decodeIfPresent(ScreeningReport.self, forKey: .report)
        schedule = try values.decodeIfPresent(DailySchedule.self, forKey: .schedule)
        reportHistory = try values.decodeIfPresent([ScreeningReport].self, forKey: .reportHistory) ?? (report.map { [$0] } ?? [])
        waterByDay = try values.decodeIfPresent([String: Int].self, forKey: .waterByDay) ?? [:]
        screenFreeMinutesByDay = try values.decodeIfPresent([String: Int].self, forKey: .screenFreeMinutesByDay) ?? [:]
        breathingMinutesByDay = try values.decodeIfPresent([String: Int].self, forKey: .breathingMinutesByDay) ?? [:]
    }
}

private enum LunaKeychain {
    private static let service = "com.kiranbathala.luna"

    static func string(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) != errSecSuccess {
            var item = query
            item.merge(attributes) { _, new in new }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func remove(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class AccountStore: ObservableObject {
    @Published private(set) var activeAccount: LunaAccount?

    private let accountsKey = "luna.accounts.v2"
    private let activeEmailKey = "luna.activeEmail.v2"
    private let dailySignInKey = "luna.dailySignInByEmail.v1"
    private var accounts: [String: LunaAccount] = [:]

    init() { load() }

    var requiresDailySignIn: Bool {
        guard let activeAccount else { return true }
        let signIns = UserDefaults.standard.dictionary(forKey: dailySignInKey) as? [String: String] ?? [:]
        return signIns[normalized(activeAccount.email)] != Self.dayKey()
    }

    func markSignedIn(for email: String) {
        var signIns = UserDefaults.standard.dictionary(forKey: dailySignInKey) as? [String: String] ?? [:]
        signIns[normalized(email)] = Self.dayKey()
        UserDefaults.standard.set(signIns, forKey: dailySignInKey)
    }

    func account(for email: String) -> LunaAccount? {
        accounts[normalized(email)]
    }

    func passwordMatches(_ password: String, for email: String) -> Bool {
        guard let digest = account(for: email)?.passwordDigest else { return false }
        return digest == Self.digest(password)
    }

    func activate(_ account: LunaAccount) {
        accounts[normalized(account.email)] = account
        activeAccount = account
        persist()
    }

    func verifyAndActivate(_ account: LunaAccount) {
        var verified = account
        verified.verified = true
        activate(verified)
    }

    func updateReport(_ report: ScreeningReport) {
        guard var account = activeAccount else { return }
        account.report = report
        if let existingIndex = account.reportHistory.firstIndex(where: { $0.capturedAt == report.capturedAt }) {
            account.reportHistory[existingIndex] = report
        } else {
            account.reportHistory.append(report)
        }
        account.reportHistory.sort { $0.capturedAt < $1.capturedAt }
        activate(account)
    }

    func updateSchedule(_ schedule: DailySchedule) {
        guard var account = activeAccount else { return }
        account.schedule = schedule
        activate(account)
    }

    var todayWater: Int { activeAccount?.waterByDay[Self.dayKey()] ?? 0 }
    var todayScreenFreeMinutes: Int { activeAccount?.screenFreeMinutesByDay[Self.dayKey()] ?? 0 }
    var todayBreathingMinutes: Int { activeAccount?.breathingMinutesByDay[Self.dayKey()] ?? 0 }
    var waterGoal: Int { 6 }
    var breathingGoalMinutes: Int { 10 }

    var todayWaterPoints: Int { min(20, Int((Double(todayWater) / 6.0 * 20.0).rounded())) }
    var todayScreenFreePoints: Int { min(25, Int((Double(todayScreenFreeMinutes) / 480.0 * 25.0).rounded())) }
    var todayBreathingPoints: Int { min(15, Int((Double(todayBreathingMinutes) / 10.0 * 15.0).rounded())) }
    var todayHabitScore: Int {
        Int((Double(todayWaterPoints + todayScreenFreePoints + todayBreathingPoints) / 60.0 * 100.0).rounded())
    }

    var todayEyeScore: Int? {
        guard let report = activeAccount?.report else { return nil }
        if let functional = report.functionalCheck { return max(0, 100 - functional.strainLoad) }
        return report.eyeStrain?.score
    }

    var hasTodayEyeScore: Bool { todayEyeScore != nil }
    var overallHealthScore: Int {
        let eyePoints = Int((Double(todayEyeScore ?? 0) * 0.40).rounded())
        return min(100, eyePoints + todayWaterPoints + todayScreenFreePoints + todayBreathingPoints)
    }

    func logWater() {
        guard var account = activeAccount else { return }
        let key = Self.dayKey()
        account.waterByDay[key] = min(waterGoal, (account.waterByDay[key] ?? 0) + 1)
        activate(account)
    }

    func addScreenFreeMinutes(_ minutes: Int) {
        guard minutes > 0, var account = activeAccount else { return }
        let key = Self.dayKey()
        account.screenFreeMinutesByDay[key] = (account.screenFreeMinutesByDay[key] ?? 0) + minutes
        activate(account)
    }

    func logBreathingMinutes(_ minutes: Int) {
        guard minutes > 0, var account = activeAccount else { return }
        let key = Self.dayKey()
        account.breathingMinutesByDay[key] = min(60, (account.breathingMinutesByDay[key] ?? 0) + minutes)
        activate(account)
    }

    private static func dayKey(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func signOut() {
        activeAccount = nil
        UserDefaults.standard.removeObject(forKey: activeEmailKey)
        LunaKeychain.remove(activeEmailKey)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let decoded = try? JSONDecoder().decode([String: LunaAccount].self, from: data) {
            accounts = decoded
        }
        let activeEmail = LunaKeychain.string(for: activeEmailKey) ?? UserDefaults.standard.string(forKey: activeEmailKey)
        if let activeEmail {
            activeAccount = accounts[normalized(activeEmail)]
            if activeAccount != nil {
                LunaKeychain.set(normalized(activeEmail), for: activeEmailKey)
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
        if let activeAccount {
            let email = normalized(activeAccount.email)
            UserDefaults.standard.set(email, forKey: activeEmailKey)
            LunaKeychain.set(email, for: activeEmailKey)
        }
    }

    private func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum MockBackend {
    static func report(eyeStrain: EyeStrainAssessment) -> ScreeningReport {
        ScreeningReport(
            capturedAt: Date(),
            summary: eyeStrain.score == nil ? "eye observation saved" : "eye-region recording analyzed",
            quality: eyeStrain.score == nil ? "recording saved · insufficient stable data for a score" : "both eye landmarks visible",
            interpretation: "Calculated from the live blink, closure, tracking, and comfort signals captured in this check-in.",
            eyeStrain: eyeStrain,
            symptoms: []
        )
    }
}
