import Cocoa
@preconcurrency import EventKit
import CryptoKit

private struct SyncRecord: Codable {
    var sourceKey: String
    var calendarIdentifier: String
    var calendarTitle: String
    var title: String
    var startEpoch: TimeInterval
    var endEpoch: TimeInterval
    var isAllDay: Bool
    var fingerprint: String
    var feishuEventID: String
}

private final class EventSnapshot {
    let event: EKEvent
    let sourceKey: String
    let payload: [String: Any]
    let fingerprint: String

    init(event: EKEvent, privateVisibility: Bool) {
        self.event = event
        let occurrence = event.occurrenceDate ?? event.startDate ?? Date()
        sourceKey = [
            event.calendar.calendarIdentifier,
            event.calendarItemIdentifier,
            String(Int(occurrence.timeIntervalSince1970))
        ].joined(separator: "|")
        payload = EventSnapshot.makePayload(event: event, privateVisibility: privateVisibility)
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func makePayload(event: EKEvent, privateVisibility: Bool) -> [String: Any] {
        let eventStart = event.startDate ?? Date()
        let eventEnd = event.endDate ?? eventStart
        var result: [String: Any] = [
            "summary": event.title?.isEmpty == false ? event.title! : "无标题日程",
            "free_busy_status": "busy",
            "visibility": privateVisibility ? "private" : "default",
            "attendee_ability": "none",
            "need_notification": false,
            "reminders": [],
            "vchat": ["vc_type": "no_meeting"]
        ]

        if event.isAllDay {
            let calendar = Calendar(identifier: .gregorian)
            let zone = event.timeZone ?? .current
            let endInclusive = calendar.date(byAdding: .day, value: -1, to: eventEnd) ?? eventStart
            result["start_time"] = ["date": dateOnly(eventStart, zone: zone), "timezone": "UTC"]
            result["end_time"] = ["date": dateOnly(max(endInclusive, eventStart), zone: zone), "timezone": "UTC"]
        } else {
            let zone = event.timeZone ?? .current
            result["start_time"] = ["timestamp": String(Int(eventStart.timeIntervalSince1970)), "timezone": zone.identifier]
            result["end_time"] = ["timestamp": String(Int(eventEnd.timeIntervalSince1970)), "timezone": zone.identifier]
        }

        if let notes = event.notes, !notes.isEmpty { result["description"] = notes }
        if let location = event.location, !location.isEmpty { result["location"] = ["name": location] }

        return result
    }

    private static func dateOnly(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private enum SyncAction {
    case create, update, unchanged, delete, keepDeleted

    var label: String {
        switch self {
        case .create: return "新增"
        case .update: return "更新"
        case .unchanged: return "无变化"
        case .delete: return "删除"
        case .keepDeleted: return "已删除（保留飞书）"
        }
    }
}

private struct PreviewItem {
    let action: SyncAction
    let snapshot: EventSnapshot?
    let record: SyncRecord?
}

private final class CalendarChoice {
    let calendar: EKCalendar
    let button: NSButton

    init(calendar: EKCalendar) {
        self.calendar = calendar
        button = NSButton(checkboxWithTitle: "\(calendar.source.title) — \(calendar.title)", target: nil, action: nil)
        button.state = (calendar.type == .birthday || calendar.type == .subscription) ? .off : .on
        button.toolTip = calendar.source.title
    }
}

private enum CLIError: LocalizedError {
    case missing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missing: return "未找到飞书官方 CLI。请确认 lark-cli 已安装。"
        case .failed(let message): return message
        }
    }
}

private final class SyncViewController: NSViewController {
    private let eventStore = EKEventStore()
    private var choices: [CalendarChoice] = []
    private var previewItems: [PreviewItem] = []
    private var records: [String: SyncRecord] = [:]

    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private let calendarStack = NSStackView()
    private let includeAllDay = NSButton(checkboxWithTitle: "同步全天日程（会占用整天）", target: nil, action: nil)
    private let privateEvents = NSButton(checkboxWithTitle: "设为私密（同事仅看到忙碌）", target: nil, action: nil)
    private let syncDeletions = NSButton(checkboxWithTitle: "同步删除 Apple 中已移除的日程", target: nil, action: nil)
    private let previewText = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "正在请求 Apple 日历访问权限…")
    private let previewButton = NSButton(title: "预览变化", target: nil, action: nil)
    private let syncButton = NSButton(title: "开始同步", target: nil, action: nil)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 660))
        let title = NSTextField(labelWithString: "Apple 日历 → 飞书手动同步")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "每次由你选择范围、预览变化并确认。同步到飞书主日历的日程会标记为忙碌。")
        subtitle.textColor = .secondaryLabelColor

        configure(startPicker)
        configure(endPicker)
        let today = Calendar.current.startOfDay(for: Date())
        startPicker.dateValue = today
        endPicker.dateValue = Calendar.current.date(byAdding: .month, value: 1, to: today) ?? today

        let dateRow = NSStackView(views: [
            NSTextField(labelWithString: "开始日期"), startPicker,
            NSTextField(labelWithString: "结束日期"), endPicker
        ])
        dateRow.orientation = .horizontal
        dateRow.spacing = 10
        dateRow.alignment = .centerY

        let calendarHeader = NSTextField(labelWithString: "来源日历")
        calendarHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        calendarStack.orientation = .vertical
        calendarStack.alignment = .leading
        calendarStack.spacing = 4
        calendarStack.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 8)

        let calendarScroll = NSScrollView()
        calendarScroll.hasVerticalScroller = true
        calendarScroll.borderType = .bezelBorder
        calendarScroll.documentView = calendarStack
        calendarScroll.translatesAutoresizingMaskIntoConstraints = false
        calendarStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            calendarStack.leadingAnchor.constraint(equalTo: calendarScroll.contentView.leadingAnchor),
            calendarStack.trailingAnchor.constraint(equalTo: calendarScroll.contentView.trailingAnchor),
            calendarStack.topAnchor.constraint(equalTo: calendarScroll.contentView.topAnchor),
            calendarStack.widthAnchor.constraint(equalTo: calendarScroll.contentView.widthAnchor)
        ])

        let selectAll = NSButton(title: "全选", target: self, action: #selector(selectAllCalendars))
        selectAll.bezelStyle = .inline
        let selectNone = NSButton(title: "全不选", target: self, action: #selector(selectNoCalendars))
        selectNone.bezelStyle = .inline
        let selectionRow = NSStackView(views: [selectAll, selectNone])
        selectionRow.orientation = .horizontal
        selectionRow.spacing = 12

        privateEvents.state = .on
        includeAllDay.state = .off
        syncDeletions.state = .off
        let options = NSStackView(views: [privateEvents, includeAllDay, syncDeletions])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 5

        let previewHeader = NSTextField(labelWithString: "同步预览")
        previewHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        previewText.isEditable = false
        previewText.isSelectable = true
        previewText.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        previewText.string = "选择日期和日历后，点击“预览变化”。"
        previewText.textContainerInset = NSSize(width: 8, height: 8)
        let previewScroll = NSScrollView()
        previewScroll.hasVerticalScroller = true
        previewScroll.borderType = .bezelBorder
        previewScroll.documentView = previewText
        previewScroll.translatesAutoresizingMaskIntoConstraints = false

        previewButton.target = self
        previewButton.action = #selector(buildPreview)
        previewButton.isEnabled = false
        syncButton.target = self
        syncButton.action = #selector(confirmSync)
        syncButton.isEnabled = false
        syncButton.keyEquivalent = "\r"

        let spacer = NSView()
        let bottom = NSStackView(views: [statusLabel, spacer, previewButton, syncButton])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 10
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let main = NSStackView(views: [title, subtitle, dateRow, calendarHeader, calendarScroll, selectionRow, options, previewHeader, previewScroll, bottom])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 10
        main.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(main)
        NSLayoutConstraint.activate([
            main.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            main.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            main.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            main.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
            subtitle.widthAnchor.constraint(equalTo: main.widthAnchor),
            calendarScroll.widthAnchor.constraint(equalTo: main.widthAnchor),
            calendarScroll.heightAnchor.constraint(equalToConstant: 145),
            previewScroll.widthAnchor.constraint(equalTo: main.widthAnchor),
            previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 205),
            bottom.widthAnchor.constraint(equalTo: main.widthAnchor)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        loadRecords()
        requestCalendarAccess()
    }

    private func configure(_ picker: NSDatePicker) {
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .yearMonthDay
        picker.locale = Locale(identifier: "zh_CN")
    }

    private func requestCalendarAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: loadCalendars()
        case .notDetermined, .writeOnly:
            eventStore.requestFullAccessToEvents { [weak self] granted, error in
                DispatchQueue.main.async {
                    granted ? self?.loadCalendars() : self?.showCalendarAccessError(error)
                }
            }
        default: showCalendarAccessError(nil)
        }
    }

    private func loadCalendars() {
        choices = eventStore.calendars(for: .event)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
            .map(CalendarChoice.init)
        calendarStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        choices.forEach { calendarStack.addArrangedSubview($0.button) }
        statusLabel.stringValue = "飞书已连接；找到 \(choices.count) 个 Apple 日历"
        previewButton.isEnabled = !choices.isEmpty
    }

    private func showCalendarAccessError(_ error: Error?) {
        statusLabel.stringValue = "未获得 Apple 日历访问权限"
        showAlert("需要访问 Apple 日历", "请在“系统设置 → 隐私与安全性 → 日历”中允许本工具访问。" + (error.map { "\n\($0.localizedDescription)" } ?? ""))
    }

    @objc private func selectAllCalendars() { choices.forEach { $0.button.state = .on } }
    @objc private func selectNoCalendars() { choices.forEach { $0.button.state = .off } }

    @objc private func buildPreview() {
        let selected = choices.filter { $0.button.state == .on }.map(\.calendar)
        guard !selected.isEmpty else { showAlert("未选择日历", "请至少选择一个来源日历。"); return }
        let systemCalendar = Calendar.current
        let start = systemCalendar.startOfDay(for: startPicker.dateValue)
        let selectedEnd = systemCalendar.startOfDay(for: endPicker.dateValue)
        guard selectedEnd >= start, let end = systemCalendar.date(byAdding: .day, value: 1, to: selectedEnd) else {
            showAlert("日期范围无效", "结束日期不能早于开始日期。")
            return
        }

        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: selected)
        let snapshots = eventStore.events(matching: predicate)
            .filter { $0.status != .canceled }
            .filter { includeAllDay.state == .on || !$0.isAllDay }
            .map { EventSnapshot(event: $0, privateVisibility: privateEvents.state == .on) }
            .sorted { ($0.event.startDate ?? .distantPast) < ($1.event.startDate ?? .distantPast) }

        var items: [PreviewItem] = []
        let liveKeys = Set(snapshots.map(\.sourceKey))
        for snapshot in snapshots {
            if let record = records[snapshot.sourceKey] {
                items.append(PreviewItem(action: record.fingerprint == snapshot.fingerprint ? .unchanged : .update, snapshot: snapshot, record: record))
            } else {
                items.append(PreviewItem(action: .create, snapshot: snapshot, record: nil))
            }
        }

        let selectedIDs = Set(selected.map(\.calendarIdentifier))
        let missing = records.values.filter {
            selectedIDs.contains($0.calendarIdentifier) &&
            $0.startEpoch < end.timeIntervalSince1970 && $0.endEpoch > start.timeIntervalSince1970 &&
            !liveKeys.contains($0.sourceKey)
        }.sorted { $0.startEpoch < $1.startEpoch }
        items += missing.map { PreviewItem(action: syncDeletions.state == .on ? .delete : .keepDeleted, snapshot: nil, record: $0) }
        previewItems = items
        renderPreview()
    }

    private func renderPreview() {
        let counts = Dictionary(grouping: previewItems, by: \.action.label).mapValues(\.count)
        var lines = ["新增 \(counts["新增", default: 0])　更新 \(counts["更新", default: 0])　无变化 \(counts["无变化", default: 0])　删除 \(counts["删除", default: 0])"]
        lines.append(String(repeating: "─", count: 64))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for item in previewItems {
            if let snapshot = item.snapshot {
                let event = snapshot.event
                let time = event.isAllDay ? "全天" : "\(formatter.string(from: event.startDate ?? Date())) – \(formatter.string(from: event.endDate ?? event.startDate ?? Date()))"
                lines.append("[\(item.action.label)] \(time)　\(event.title ?? "无标题")　〈\(event.calendar.title)〉")
            } else if let record = item.record {
                lines.append("[\(item.action.label)] \(formatter.string(from: Date(timeIntervalSince1970: record.startEpoch)))　\(record.title)　〈\(record.calendarTitle)〉")
            }
        }
        if previewItems.isEmpty { lines.append("此范围内没有可同步的日程。") }
        previewText.string = lines.joined(separator: "\n")
        let actionable = previewItems.contains { [.create, .update, .delete].contains($0.action) }
        syncButton.isEnabled = actionable
        statusLabel.stringValue = "预览完成，共 \(previewItems.count) 项"
    }

    @objc private func confirmSync() {
        let createCount = previewItems.filter { $0.action == .create }.count
        let updateCount = previewItems.filter { $0.action == .update }.count
        let deleteCount = previewItems.filter { $0.action == .delete }.count
        let alert = NSAlert()
        alert.messageText = "确认同步到飞书主日历？"
        alert.informativeText = "将新增 \(createCount) 项、更新 \(updateCount) 项、删除 \(deleteCount) 项。所有新增或更新日程都将占用忙闲。"
        alert.addButton(withTitle: "开始同步")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runSync()
    }

    private func runSync() {
        let actionable = previewItems.filter { [.create, .update, .delete].contains($0.action) }
        previewButton.isEnabled = false
        syncButton.isEnabled = false
        statusLabel.stringValue = "正在同步 0 / \(actionable.count)…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var succeeded = 0
            var failures: [String] = []
            for (index, item) in actionable.enumerated() {
                do {
                    switch item.action {
                    case .create:
                        guard let snapshot = item.snapshot else { continue }
                        let response = try self.callCLI([
                            "calendar", "events", "create", "--as", "user", "--calendar-id", "primary",
                            "--idempotency-key", self.hash(snapshot.sourceKey), "--data", self.json(snapshot.payload), "--format", "json"
                        ])
                        guard let eventID = self.eventID(from: response) else { throw CLIError.failed("飞书未返回日程 ID") }
                        self.records[snapshot.sourceKey] = self.record(for: snapshot, eventID: eventID)
                    case .update:
                        guard let snapshot = item.snapshot, let old = item.record else { continue }
                        _ = try self.callCLI([
                            "calendar", "events", "patch", "--as", "user", "--calendar-id", "primary",
                            "--event-id", old.feishuEventID, "--data", self.json(snapshot.payload), "--format", "json"
                        ])
                        self.records[snapshot.sourceKey] = self.record(for: snapshot, eventID: old.feishuEventID)
                    case .delete:
                        guard let old = item.record else { continue }
                        _ = try self.callCLI([
                            "calendar", "events", "delete", "--as", "user", "--calendar-id", "primary",
                            "--event-id", old.feishuEventID, "--need-notification", "false", "--format", "json"
                        ])
                        self.records.removeValue(forKey: old.sourceKey)
                    default: continue
                    }
                    try self.saveRecords()
                    succeeded += 1
                } catch {
                    let title = item.snapshot?.event.title ?? item.record?.title ?? "未知日程"
                    failures.append("\(title)：\(error.localizedDescription)")
                }
                DispatchQueue.main.async { self.statusLabel.stringValue = "正在同步 \(index + 1) / \(actionable.count)…" }
            }
            DispatchQueue.main.async {
                self.previewButton.isEnabled = true
                self.statusLabel.stringValue = failures.isEmpty ? "同步完成：成功 \(succeeded) 项" : "同步完成：成功 \(succeeded) 项，失败 \(failures.count) 项"
                if failures.isEmpty {
                    self.showAlert("同步完成", "已成功处理 \(succeeded) 个飞书日程，并标记为忙碌。")
                } else {
                    self.showAlert("部分日程同步失败", failures.prefix(8).joined(separator: "\n"))
                }
                self.buildPreview()
            }
        }
    }

    private func callCLI(_ arguments: [String]) throws -> [String: Any] {
        let candidates = ["/opt/homebrew/bin/lark-cli", "/usr/local/bin/lark-cli"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw CLIError.missing }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let cliDirectory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        environment["PATH"] = [cliDirectory, "/opt/homebrew/bin", "/usr/local/bin", existingPath].joined(separator: ":")
        environment["LARKSUITE_CLI_NO_UPDATE_NOTIFIER"] = "1"
        environment["LARKSUITE_CLI_NO_SKILLS_NOTIFIER"] = "1"
        process.environment = environment
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        let data = stdout.isEmpty ? stderr : stdout
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.failed(String(data: data, encoding: .utf8) ?? "飞书命令返回了无法识别的结果")
        }
        if process.terminationStatus != 0 || (object["ok"] as? Bool) != true {
            let errorObject = object["error"] as? [String: Any]
            throw CLIError.failed(errorObject?["message"] as? String ?? "飞书操作失败（代码 \(process.terminationStatus)）")
        }
        return object
    }

    private func eventID(from response: [String: Any]) -> String? {
        let data = response["data"] as? [String: Any]
        let event = data?["event"] as? [String: Any]
        return event?["event_id"] as? String
    }

    private func record(for snapshot: EventSnapshot, eventID: String) -> SyncRecord {
        let event = snapshot.event
        return SyncRecord(sourceKey: snapshot.sourceKey, calendarIdentifier: event.calendar.calendarIdentifier,
                          calendarTitle: event.calendar.title, title: event.title ?? "无标题日程",
                          startEpoch: (event.startDate ?? Date()).timeIntervalSince1970, endEpoch: (event.endDate ?? event.startDate ?? Date()).timeIntervalSince1970,
                          isAllDay: event.isAllDay, fingerprint: snapshot.fingerprint, feishuEventID: eventID)
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private var recordsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AppleToFeishuManualSync", isDirectory: true).appendingPathComponent("mappings.json")
    }

    private func loadRecords() {
        guard let data = try? Data(contentsOf: recordsURL), let values = try? JSONDecoder().decode([SyncRecord].self, from: data) else { return }
        records = Dictionary(uniqueKeysWithValues: values.map { ($0.sourceKey, $0) })
    }

    private func saveRecords() throws {
        try FileManager.default.createDirectory(at: recordsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Array(records.values))
        try data.write(to: recordsURL, options: .atomic)
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentViewController: SyncViewController())
        window.title = "Apple 日历 → 飞书手动同步"
        window.setContentSize(NSSize(width: 720, height: 660))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
