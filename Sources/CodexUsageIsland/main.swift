import AppKit
import Foundation

struct LimitWindow {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: TimeInterval

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

struct CodexUsage {
    let primary: LimitWindow
    let secondary: LimitWindow
    let planType: String
    let sourceDate: Date
}

final class UsageReader {
    private let sessionsURL: URL
    private let authURL: URL
    private let fileManager = FileManager.default
    private let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let plainISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init() {
        let codexURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex", isDirectory: true)
        sessionsURL = codexURL.appendingPathComponent("sessions", isDirectory: true)
        authURL = codexURL.appendingPathComponent("auth.json")
    }

    func latestUsage() -> CodexUsage? {
        latestUsageFromWhamAPI() ?? latestUsageFromSessionFiles()
    }

    private func latestUsageFromWhamAPI() -> CodexUsage? {
        guard let token = accessToken() else { return nil }
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("en", forHTTPHeaderField: "OAI-Language")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("codex_desktop", forHTTPHeaderField: "OpenAI-Beta")

        var resultData: Data?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let httpResponse = response as? HTTPURLResponse,
               (200..<300).contains(httpResponse.statusCode) {
                resultData = data
            }
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + 10) == .success,
              let data = resultData,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = object["rate_limit"] as? [String: Any],
              let primaryObject = limits["primary_window"] as? [String: Any],
              let secondaryObject = limits["secondary_window"] as? [String: Any],
              let primary = parseWindow(primaryObject),
              let secondary = parseWindow(secondaryObject) else {
            return nil
        }

        return CodexUsage(
            primary: primary,
            secondary: secondary,
            planType: "codex",
            sourceDate: Date()
        )
    }

    private func accessToken() -> String? {
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private func latestUsageFromSessionFiles() -> CodexUsage? {
        guard let files = enumeratorJSONLFiles() else { return nil }
        let sortedFiles = files.sorted {
            modificationDate($0) > modificationDate($1)
        }

        var bestUsage: CodexUsage?
        for file in sortedFiles.prefix(40) {
            if let usage = latestUsage(in: file) {
                if bestUsage == nil || usage.sourceDate > bestUsage!.sourceDate {
                    bestUsage = usage
                }
            }
        }
        return bestUsage
    }

    private func enumeratorJSONLFiles() -> [URL]? {
        guard let enumerator = fileManager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            urls.append(url)
        }
        return urls
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private func latestUsage(in url: URL) -> CodexUsage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let readSize = min(UInt64(1_500_000), size)
        try? handle.seek(toOffset: size - readSize)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var bestUsage: CodexUsage?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("\"rate_limits\""),
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let usage = parseUsage(from: object) else {
                continue
            }
            if bestUsage == nil || usage.sourceDate > bestUsage!.sourceDate {
                bestUsage = usage
            }
        }
        return bestUsage
    }

    private func parseUsage(from object: [String: Any]) -> CodexUsage? {
        guard let payload = object["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any],
              let primaryObject = limits["primary"] as? [String: Any],
              let secondaryObject = limits["secondary"] as? [String: Any],
              let primary = parseWindow(primaryObject),
              let secondary = parseWindow(secondaryObject) else {
            return nil
        }

        guard let timestampString = object["timestamp"] as? String,
              let timestamp = parseTimestamp(timestampString) else {
            return nil
        }
        return CodexUsage(
            primary: primary,
            secondary: secondary,
            planType: limits["plan_type"] as? String ?? "codex",
            sourceDate: timestamp
        )
    }

    private func parseTimestamp(_ text: String) -> Date? {
        fractionalISOFormatter.date(from: text) ?? plainISOFormatter.date(from: text)
    }

    private func parseWindow(_ object: [String: Any]) -> LimitWindow? {
        let used = doubleValue(object["used_percent"])
        let minutes = intValue(object["window_minutes"])
            ?? intValue(object["limit_window_seconds"]).map { $0 / 60 }
        let reset = doubleValue(object["resets_at"])
            ?? doubleValue(object["reset_at"])
            ?? doubleValue(object["reset_after_seconds"]).map { Date().timeIntervalSince1970 + $0 }

        guard let used, let minutes, let reset else {
            return nil
        }
        return LimitWindow(usedPercent: used, windowMinutes: minutes, resetsAt: reset)
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}

final class IslandView: NSView {
    var usage: CodexUsage? {
        didSet { needsDisplay = true }
    }
    var expanded = false {
        didSet {
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }
    var onToggle: (() -> Void)?
    var onQuit: (() -> Void)?

    override var intrinsicContentSize: NSSize {
        expanded ? NSSize(width: 360, height: 118) : NSSize(width: 238, height: 44)
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onQuit?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.black.withAlphaComponent(0.88).setFill()
        path.fill()

        NSColor.white.withAlphaComponent(0.12).setStroke()
        path.lineWidth = 1
        path.stroke()

        guard let usage else {
            drawText("Codex usage unavailable", at: NSPoint(x: 18, y: bounds.midY - 7), size: 12, weight: .medium, color: .white)
            return
        }

        if expanded {
            drawExpanded(usage)
        } else {
            drawCompact(usage)
        }
    }

    private func drawCompact(_ usage: CodexUsage) {
        drawText("5h \(Int(round(usage.primary.remainingPercent)))%", at: NSPoint(x: 18, y: 22), size: 12, weight: .semibold, color: .white)
        drawText("1w \(Int(round(usage.secondary.remainingPercent)))%", at: NSPoint(x: 126, y: 22), size: 12, weight: .semibold, color: .white)
        drawBar(x: 18, y: 12, width: 88, height: 5, percent: usage.primary.remainingPercent, color: color(for: usage.primary.remainingPercent))
        drawBar(x: 126, y: 12, width: 88, height: 5, percent: usage.secondary.remainingPercent, color: color(for: usage.secondary.remainingPercent))
    }

    private func drawExpanded(_ usage: CodexUsage) {
        drawText("Codex \(usage.planType.capitalized)", at: NSPoint(x: 22, y: 90), size: 13, weight: .semibold, color: .white)
        drawText("Click collapse   Right click quit", at: NSPoint(x: 188, y: 91), size: 10, weight: .regular, color: NSColor.white.withAlphaComponent(0.54))

        drawLimitRow(label: "5 hours", window: usage.primary, y: 58)
        drawLimitRow(label: "1 week", window: usage.secondary, y: 25)
    }

    private func drawLimitRow(label: String, window: LimitWindow, y: CGFloat) {
        let remaining = Int(round(window.remainingPercent))
        drawText(label, at: NSPoint(x: 22, y: y + 7), size: 11, weight: .medium, color: NSColor.white.withAlphaComponent(0.72))
        drawText("\(remaining)% left", at: NSPoint(x: 82, y: y + 7), size: 11, weight: .semibold, color: .white)
        drawText("resets \(relativeReset(window.resetsAt))", at: NSPoint(x: 268, y: y + 7), size: 10, weight: .regular, color: NSColor.white.withAlphaComponent(0.54))
        drawBar(x: 22, y: y - 4, width: 316, height: 7, percent: window.remainingPercent, color: color(for: window.remainingPercent))
    }

    private func drawBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, percent: Double, color: NSColor) {
        let bg = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: height / 2, yRadius: height / 2)
        NSColor.white.withAlphaComponent(0.14).setFill()
        bg.fill()

        let fillWidth = max(height, width * CGFloat(max(0, min(100, percent)) / 100))
        let fg = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: fillWidth, height: height), xRadius: height / 2, yRadius: height / 2)
        color.setFill()
        fg.fill()
    }

    private func drawText(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ]
        text.draw(at: point, withAttributes: attrs)
    }

    private func color(for remaining: Double) -> NSColor {
        if remaining < 20 { return NSColor.systemRed }
        if remaining < 45 { return NSColor.systemOrange }
        return NSColor.systemGreen
    }

    private func relativeReset(_ timestamp: TimeInterval) -> String {
        let delta = max(0, timestamp - Date().timeIntervalSince1970)
        if delta < 60 { return "soon" }
        let minutes = Int(delta / 60)
        if minutes < 90 { return "\(minutes)m" }
        let hours = minutes / 60
        let mins = minutes % 60
        if hours < 48 { return "\(hours)h \(mins)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let reader = UsageReader()
    private let islandView = IslandView(frame: NSRect(x: 0, y: 0, width: 238, height: 44))
    private var window: NSPanel!
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 238, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.contentView = islandView
        window.ignoresMouseEvents = false

        islandView.onToggle = { [weak self] in
            guard let self else { return }
            self.islandView.expanded.toggle()
            self.resizeAndPlace()
        }
        islandView.onQuit = {
            NSApp.terminate(nil)
        }

        update()
        resizeAndPlace()
        window.orderFrontRegardless()

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    private func update() {
        islandView.usage = reader.latestUsage()
        resizeAndPlace()
    }

    private func resizeAndPlace() {
        guard let screen = NSScreen.main else { return }
        let size = islandView.intrinsicContentSize
        var frame = window.frame
        frame.size = size
        frame.origin.x = screen.frame.midX - size.width / 2
        frame.origin.y = screen.frame.maxY - size.height - 8
        window.setFrame(frame, display: true, animate: false)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
if CommandLine.arguments.contains("--print-usage") {
    if let usage = UsageReader().latestUsage() {
        print("5h remaining: \(Int(round(usage.primary.remainingPercent)))%")
        print("1w remaining: \(Int(round(usage.secondary.remainingPercent)))%")
        print("5h used: \(usage.primary.usedPercent)%")
        print("1w used: \(usage.secondary.usedPercent)%")
        print("source: \(ISO8601DateFormatter().string(from: usage.sourceDate))")
    } else {
        print("No Codex usage found")
        exit(1)
    }
} else {
    app.run()
}
