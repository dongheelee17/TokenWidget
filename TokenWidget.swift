import SwiftUI
import AppKit

// MARK: - Model

struct Limit {
    var leftPercent: Double   // 0...100
    var resetsAt: Date?
}

struct UsageInfo {
    var fiveHour: Limit?
    var weekly: Limit?
    var error: String?
}

// MARK: - Data sources

enum CodexSource {
    static func load() -> UsageInfo {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return UsageInfo(error: "~/.codex/sessions 없음")
        }
        var files: [(URL, Date)] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((url, d))
        }
        files.sort { $0.1 > $1.1 }
        // 최근 파일부터 rate_limits 이벤트를 찾는다
        for (url, _) in files.prefix(20) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      let rl = payload["rate_limits"] as? [String: Any] else { continue }
                return UsageInfo(fiveHour: limit(rl["primary"]), weekly: limit(rl["secondary"]))
            }
        }
        return UsageInfo(error: "Codex 사용 기록 없음")
    }

    private static func limit(_ any: Any?) -> Limit? {
        guard let d = any as? [String: Any], let used = d["used_percent"] as? Double else { return nil }
        let reset = (d["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        // 로그는 마지막 Codex 사용 시점 기준이라, 리셋 시간이 지났으면 100%로 본다
        if let reset, reset < Date() { return Limit(leftPercent: 100, resetsAt: nil) }
        return Limit(leftPercent: max(0, 100 - used), resetsAt: reset)
    }
}

enum ClaudeSource {
    enum Result {
        case ok(UsageInfo, Data)
        case rateLimited(retryAfter: TimeInterval?)
        case failed(String)
    }

    static func fetch() async -> Result {
        guard let token = accessToken() else { return .failed("Claude 로그인 정보 없음") }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                switch http.statusCode {
                case 429:
                    let retry = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
                    return .rateLimited(retryAfter: retry)
                case 401: return .failed("토큰 만료 (claude 한번 실행)")
                default: return .failed("HTTP \(http.statusCode)")
                }
            }
            guard let info = parse(data) else { return .failed("응답 형식 오류") }
            return .ok(info, data)
        } catch {
            return .failed("네트워크 오류")
        }
    }

    static func parse(_ data: Data) -> UsageInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return UsageInfo(fiveHour: limit(obj["five_hour"]), weekly: limit(obj["seven_day"]))
    }

    private static func limit(_ any: Any?) -> Limit? {
        guard let d = any as? [String: Any], let used = d["utilization"] as? Double else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let reset = (d["resets_at"] as? String).flatMap { f.date(from: $0) }
        return Limit(leftPercent: max(0, 100 - used), resetsAt: reset)
    }

    private static func accessToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["accessToken"] as? String
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var codex = UsageInfo()
    @Published var claude = UsageInfo()
    @Published var now = Date()
    @Published var page = UserDefaults.standard.integer(forKey: "page") {
        didSet { UserDefaults.standard.set(page, forKey: "page") }
    }
    @Published var compact = UserDefaults.standard.bool(forKey: "compact") {
        didSet { UserDefaults.standard.set(compact, forKey: "compact") }
    }
    private var timer: Timer?
    static let pageCount = 2

    // Claude 사용량 API는 요청 제한이 빡빡해서 5분마다만 조회하고, 429가 나면 간격을 늘린다
    private static let claudeInterval: TimeInterval = 300
    private var claudeBackoff: TimeInterval = 300
    private var claudeNextFetch = Date.distantPast
    private var claudeFetching = false

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "claudeCache"), let info = ClaudeSource.parse(data),
           let at = d.object(forKey: "claudeCacheTime") as? Date {
            claude = info
            claudeNextFetch = at.addingTimeInterval(Store.claudeInterval)
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        now = Date()
        Task.detached {
            let c = CodexSource.load()
            await MainActor.run { self.codex = c }
        }
        refreshClaude(force: false)
    }

    func refreshClaude(force: Bool) {
        let now = Date()
        guard !claudeFetching, force || now >= claudeNextFetch else { return }
        claudeFetching = true
        Task {
            let result = await ClaudeSource.fetch()
            claudeFetching = false
            switch result {
            case .ok(let info, let data):
                claude = info
                claudeBackoff = Store.claudeInterval
                claudeNextFetch = Date().addingTimeInterval(Store.claudeInterval)
                UserDefaults.standard.set(data, forKey: "claudeCache")
                UserDefaults.standard.set(Date(), forKey: "claudeCacheTime")
            case .rateLimited(let retryAfter):
                // 이전 값이 있으면 그대로 보여주고 조용히 나중에 다시 시도
                claudeBackoff = min(claudeBackoff * 2, 1800)
                claudeNextFetch = Date().addingTimeInterval(max(retryAfter ?? 0, claudeBackoff))
                if claude.fiveHour == nil { claude = UsageInfo(error: "요청 제한 중, 잠시 후 자동 재시도") }
            case .failed(let msg):
                claudeNextFetch = Date().addingTimeInterval(60)
                if claude.fiveHour == nil || msg.hasPrefix("토큰") { claude = UsageInfo(error: msg) }
            }
        }
    }

    func go(_ delta: Int) {
        let next = min(max(page + delta, 0), Store.pageCount - 1)
        guard next != page else { return }
        withAnimation(.easeInOut(duration: 0.25)) { page = next }
    }
}

// MARK: - Views

func resetText(_ date: Date?, now: Date) -> String {
    guard let date else { return "Resets —" }
    let s = max(0, date.timeIntervalSince(now))
    let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
    if h >= 24 { return "Resets in \(h / 24)일 \(h % 24)시간" }
    if h > 0 { return "Resets in \(h)시간" + (m > 0 && h < 5 ? " \(m)분" : "") }
    return "Resets in \(m)분"
}

struct Bar: View {
    let percent: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(.white.opacity(0.8))
                    .frame(width: g.size.width * CGFloat(percent / 100))
            }
        }
        .frame(height: 5)
    }
}

struct LimitRow: View {
    let title: String
    let limit: Limit?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(limit.map { "\(Int($0.leftPercent.rounded()))% left" } ?? "—")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            Bar(percent: limit?.leftPercent ?? 0)
            Text(resetText(limit?.resetsAt, now: now))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
        }
    }
}

struct Header: View {
    let name: String
    let symbol: String
    var size: CGFloat = 17
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: size - 2, weight: .medium))
            Text(name).font(.system(size: size, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.9))
    }
}

struct PageContent: View {
    let name: String
    let symbol: String
    let info: UsageInfo
    let now: Date
    let compact: Bool

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Header(name: name, symbol: symbol, size: 13)
                    Spacer()
                    Text(info.fiveHour.map { "\(Int($0.leftPercent.rounded()))%" } ?? "—")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                Bar(percent: info.fiveHour?.leftPercent ?? 0)
                Text(info.error ?? resetText(info.fiveHour?.resetsAt, now: now))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Header(name: name, symbol: symbol)
                if let err = info.error {
                    Spacer()
                    Text(err).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                } else {
                    LimitRow(title: "5 hours", limit: info.fiveHour, now: now)
                    LimitRow(title: "Weekly", limit: info.weekly, now: now)
                }
            }
        }
    }
}

// 창 뒤 배경을 흐리게 비치는 반투명 블러
struct Blur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct WidgetView: View {
    @ObservedObject var store: Store
    @AppStorage("alwaysOnTop") var alwaysOnTop = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: store.compact ? 18 : 26, style: .continuous)
        ZStack(alignment: .bottom) {
            ZStack {
                if store.page == 0 {
                    PageContent(name: "Codex", symbol: "terminal", info: store.codex, now: store.now, compact: store.compact)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    PageContent(name: "Claude", symbol: "sparkle", info: store.claude, now: store.now, compact: store.compact)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, store.compact ? 12 : 16)
            .padding(.bottom, store.compact ? 16 : 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack(spacing: 5) {
                ForEach(0..<Store.pageCount, id: \.self) { i in
                    Circle().fill(.white.opacity(i == store.page ? 0.85 : 0.3))
                        .frame(width: 5, height: 5)
                        .onTapGesture { store.go(i - store.page) }
                }
            }
            .padding(.bottom, store.compact ? 6 : 9)
        }
        .frame(width: store.compact ? 170 : 180, height: store.compact ? 82 : 180)
        .background(Blur())
        .background(Color.black.opacity(0.35))
        .clipShape(shape)
        .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
        .clipped()
        // 창 기본 그림자는 밝은 배경에서 검은 테두리가 생겨서 직접 부드러운 그림자를 그린다
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(16)
        .fixedSize()
        .contextMenu {
            Button("새로고침") { store.refresh(); store.refreshClaude(force: true) }
            Button(store.compact ? "크게 보기" : "작게 보기") { store.compact.toggle() }
            Divider()
            Toggle("항상 위에 표시", isOn: $alwaysOnTop)
            Divider()
            Button("종료") { NSApp.terminate(nil) }
        }
        .onChange(of: alwaysOnTop) { _, v in AppDelegate.shared?.applyLevel(v) }
        .onChange(of: store.compact) { _, _ in AppDelegate.shared?.fit() }
    }
}

// MARK: - App / Window

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var store: Store?
    private var dragStartMouse: NSPoint?
    private var swipeFired = false
    private var swipeAccum: CGFloat = 0

    // 윗부분(로고 줄)을 잡으면 창 이동, 나머지는 좌우로 쓸어서 페이지 넘기기
    private func isInHeader(_ event: NSEvent) -> Bool {
        let compact = MainActor.assumeIsolated { store?.compact ?? false }
        let headerHeight: CGFloat = compact ? 42 : 58
        return event.locationInWindow.y > frame.height - headerHeight
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if isInHeader(event) && event.clickCount == 1 {
                performDrag(with: event)
                return
            }
            dragStartMouse = NSEvent.mouseLocation
            swipeFired = false
        case .leftMouseDragged:
            if let start = dragStartMouse {
                let p = NSEvent.mouseLocation
                let dx = p.x - start.x, dy = p.y - start.y
                if !swipeFired && abs(dx) > 40 && abs(dx) > abs(dy) {
                    swipeFired = true
                    MainActor.assumeIsolated { store?.go(dx < 0 ? 1 : -1) }
                }
                return
            }
        case .leftMouseUp:
            let moved = dragStartMouse.map { hypot(NSEvent.mouseLocation.x - $0.x, NSEvent.mouseLocation.y - $0.y) > 4 } ?? false
            dragStartMouse = nil
            if !moved && event.clickCount == 2 {
                MainActor.assumeIsolated { store?.compact.toggle() }
            }
        case .scrollWheel:
            // 트랙패드 두 손가락 좌우 스와이프로 페이지 전환
            if event.phase == .began { swipeAccum = 0; swipeFired = false }
            if event.momentumPhase == [] && !swipeFired {
                swipeAccum += event.scrollingDeltaX
                if abs(swipeAccum) > 30 {
                    swipeFired = true
                    let dir = swipeAccum < 0 ? 1 : -1
                    MainActor.assumeIsolated { store?.go(dir) }
                }
            }
            if event.phase == .ended || event.phase == .cancelled { swipeAccum = 0; swipeFired = false }
            return
        default:
            break
        }
        super.sendEvent(event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    var panel: FloatingPanel!
    var hosting: NSHostingView<WidgetView>!

    @MainActor
    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        let store = Store()
        hosting = NSHostingView(rootView: WidgetView(store: store))
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 192, height: 192),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.store = store
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let size = hosting.fittingSize
        panel.setContentSize(size)
        if !panel.setFrameUsingName("TokenWidget2") {
            if let s = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: s.maxX - size.width - 20, y: s.maxY - size.height - 20))
            }
        }
        panel.setFrameAutosaveName("TokenWidget2")
        fit()
        let onTop = UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? true
        applyLevel(onTop)
        panel.orderFrontRegardless()
    }

    func applyLevel(_ onTop: Bool) {
        panel.level = onTop ? .floating : .normal
    }

    // 크기가 바뀌어도 왼쪽 위 모서리는 그대로 둔다
    func fit() {
        DispatchQueue.main.async {
            let size = self.hosting.fittingSize
            var f = self.panel.frame
            f.origin.y += f.height - size.height
            f.size = size
            self.panel.setFrame(f, display: true, animate: false)
        }
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
