import Cocoa
@preconcurrency import EventKit
import CryptoKit
import CoreImage.CIFilterBuiltins

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

private final class SyncViewController: NSViewController {
    private let cli = FeishuCLI()
    private var hasLoaded = false
    private var isBusy = false
    private var authorizationCancellation: CLICancellation?
    private var authorizationPanel: NSPanel?
    private var authorizationURL: URL?
    private var activeBatch: SyncBatch<PreviewItem>?
    private let connectionLabel = NSTextField(labelWithString: "正在检查飞书连接…")
    private let connectButton = NSButton(title: "连接／重新授权飞书", target: nil, action: nil)
    private let selectAllButton = NSButton(title: "全选", target: nil, action: nil)
    private let selectNoneButton = NSButton(title: "全不选", target: nil, action: nil)
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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 730))
        let title = NSTextField(labelWithString: "Apple 日历 → 飞书手动同步")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "每次由你选择范围、预览变化并确认。同步到飞书主日历的日程会标记为忙碌。")
        subtitle.textColor = .secondaryLabelColor

        connectButton.target = self
        connectButton.action = #selector(connectFeishu)
        connectionLabel.textColor = .secondaryLabelColor
        connectionLabel.lineBreakMode = .byTruncatingTail
        let connectionRow = NSStackView(views: [connectButton, connectionLabel])
        connectionRow.orientation = .horizontal
        connectionRow.spacing = 12
        connectionRow.alignment = .centerY

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

        selectAllButton.target = self
        selectAllButton.action = #selector(selectAllCalendars)
        selectAllButton.bezelStyle = .inline
        selectNoneButton.target = self
        selectNoneButton.action = #selector(selectNoCalendars)
        selectNoneButton.bezelStyle = .inline
        let selectionRow = NSStackView(views: [selectAllButton, selectNoneButton])
        selectionRow.orientation = .horizontal
        selectionRow.spacing = 12

        privateEvents.state = .on
        includeAllDay.state = .off
        syncDeletions.state = .off
        for control in [includeAllDay, privateEvents, syncDeletions] {
            control.target = self
            control.action = #selector(invalidatePreview)
        }
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

        let main = NSStackView(views: [title, subtitle, connectionRow, dateRow, calendarHeader, calendarScroll, selectionRow, options, previewHeader, previewScroll, bottom])
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
        guard !hasLoaded else { return }
        hasLoaded = true
        loadRecords()
        requestCalendarAccess()
        checkConnection()
    }

    private func configure(_ picker: NSDatePicker) {
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .yearMonthDay
        picker.locale = Locale(identifier: "zh_CN")
        picker.target = self
        picker.action = #selector(invalidatePreview)
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
        choices.forEach {
            $0.button.target = self
            $0.button.action = #selector(invalidatePreview)
            $0.button.isEnabled = !isBusy
            calendarStack.addArrangedSubview($0.button)
        }
        statusLabel.stringValue = "找到 \(choices.count) 个 Apple 日历"
        previewButton.isEnabled = !isBusy && !choices.isEmpty
    }

    private func showCalendarAccessError(_ error: Error?) {
        statusLabel.stringValue = "未获得 Apple 日历访问权限"
        showAlert("需要访问 Apple 日历", "请在“系统设置 → 隐私与安全性 → 日历”中允许本工具访问。" + (error.map { "\n\($0.localizedDescription)" } ?? ""))
    }

    @objc private func selectAllCalendars() { choices.forEach { $0.button.state = .on }; invalidatePreview() }
    @objc private func selectNoCalendars() { choices.forEach { $0.button.state = .off }; invalidatePreview() }

    @objc private func invalidatePreview() {
        guard !isBusy else { return }
        previewItems = []
        syncButton.isEnabled = false
        previewText.string = "设置已变化，请重新点击“预览变化”。"
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        for control: NSControl in [startPicker, endPicker, includeAllDay, privateEvents, syncDeletions, selectAllButton, selectNoneButton] {
            control.isEnabled = !busy
        }
        choices.forEach { $0.button.isEnabled = !busy }
        connectButton.isEnabled = !busy
        previewButton.isEnabled = !busy && !choices.isEmpty
        syncButton.isEnabled = !busy && previewItems.contains { [.create, .update, .delete].contains($0.action) }
    }

    private func checkConnection() {
        guard !isBusy else { return }
        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Result { try self.cli.identity() }
            DispatchQueue.main.async {
                self.setBusy(false)
                switch result {
                case .success(let identity): self.displayIdentity(identity)
                case .failure: self.connectionLabel.stringValue = "飞书连接不可用，请点击连接按钮"
                }
            }
        }
    }

    private func displayIdentity(_ identity: FeishuIdentity) {
        connectionLabel.stringValue = identity.isReady
            ? "飞书已连接" + (identity.name.map { "：\($0)" } ?? "")
            : "尚未连接或授权已失效"
    }

    @objc private func connectFeishu() {
        guard !isBusy else { return }
        beginAuthorization()
    }

    private func beginAuthorization() {
        let cancellation = CLICancellation()
        authorizationCancellation = cancellation
        setBusy(true)
        connectionLabel.stringValue = "正在获取飞书授权链接…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let authorization = try self.cli.beginAuthorization(cancellation: cancellation)
                DispatchQueue.main.async {
                    guard !cancellation.isCancelled else { return }
                    self.showAuthorization(authorization)
                }
                let identity = try self.cli.finishAuthorization(authorization, cancellation: cancellation)
                DispatchQueue.main.async { self.authorizationFinished(.success(identity)) }
            } catch {
                DispatchQueue.main.async { self.authorizationFinished(.failure(error)) }
            }
        }
    }

    private func showAuthorization(_ authorization: FeishuAuthorization) {
        authorizationURL = authorization.url
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 490), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "连接飞书"
        let title = NSTextField(labelWithString: "请用原来的飞书账号扫码授权")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: activeBatch == nil
            ? "完成授权后会自动检查连接，随后可继续预览和同步。"
            : "完成授权后会自动继续本次已确认的同步，已完成的日程不会重复处理。")
        let qr = NSImageView()
        qr.imageScaling = .scaleProportionallyUpOrDown
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(authorization.url.absoluteString.utf8)
        if let output = filter.outputImage,
           let image = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) {
            qr.image = NSImage(cgImage: image, size: NSSize(width: 224, height: 224))
        }
        let link = NSTextField(wrappingLabelWithString: authorization.url.absoluteString)
        link.isSelectable = true
        link.font = .systemFont(ofSize: 11)
        link.textColor = .secondaryLabelColor
        let expiry = NSTextField(labelWithString: "授权链接约 \(max(1, Int(authorization.expiresIn / 60))) 分钟内有效；正在等待授权…")
        expiry.textColor = .secondaryLabelColor
        let open = NSButton(title: "打开授权页面", target: self, action: #selector(openAuthorizationPage))
        let cancel = NSButton(title: "取消授权", target: self, action: #selector(cancelAuthorization))
        let buttons = NSStackView(views: [open, cancel])
        buttons.spacing = 12
        let stack = NSStackView(views: [title, detail, qr, link, expiry, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 24),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            link.widthAnchor.constraint(equalTo: stack.widthAnchor),
            qr.widthAnchor.constraint(equalToConstant: 224), qr.heightAnchor.constraint(equalToConstant: 224)
        ])
        authorizationPanel = panel
        connectionLabel.stringValue = "等待飞书扫码或网页授权…"
        view.window?.beginSheet(panel)
        openAuthorizationPage()
    }

    @objc private func openAuthorizationPage() {
        if let authorizationURL { NSWorkspace.shared.open(authorizationURL) }
    }

    @objc private func cancelAuthorization() {
        guard let cancellation = authorizationCancellation else { return }
        cancellation.cancel()
        connectionLabel.stringValue = "正在取消授权…"
    }

    func stopRunningCommands() {
        authorizationCancellation?.cancel()
        cli.cancelRunningCommands()
    }

    private func authorizationFinished(_ result: Result<FeishuIdentity, Error>) {
        let outcome: Result<FeishuIdentity, Error> = authorizationCancellation?.isCancelled == true
            ? .failure(CLIError.cancelled) : result
        if let panel = authorizationPanel { view.window?.endSheet(panel); panel.orderOut(nil) }
        authorizationPanel = nil
        authorizationURL = nil
        authorizationCancellation = nil
        switch outcome {
        case .success(let identity):
            displayIdentity(identity)
            if let batch = activeBatch {
                do { try batch.acceptIdentity(identity) }
                catch {
                    stopBatch("飞书账号已变化", error.localizedDescription)
                    return
                }
                continueSync(batch)
            } else {
                setBusy(false)
                statusLabel.stringValue = "授权成功，可以继续同步"
            }
        case .failure(let error):
            connectionLabel.stringValue = "未完成授权，请重新连接"
            if activeBatch != nil {
                stopBatch("同步已暂停", error.localizedDescription + "\n已完成的日程已保存；重新连接后，请预览并确认剩余项目。")
            } else {
                setBusy(false)
                showAlert("未完成飞书授权", error.localizedDescription)
            }
        }
    }

    @objc private func buildPreview() {
        guard !isBusy else { return }
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
        let batch = SyncBatch(items: previewItems.filter { [.create, .update, .delete].contains($0.action) })
        guard !batch.items.isEmpty else { return }
        activeBatch = batch
        setBusy(true)
        statusLabel.stringValue = "正在检查飞书授权…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let identity = try self.cli.identity()
                batch.expectedOpenID = identity.openID
                DispatchQueue.main.async {
                    self.displayIdentity(identity)
                    if identity.isReady { self.continueSync(batch) }
                    else { batch.attemptedAuthorization = true; self.beginAuthorization() }
                }
            } catch {
                DispatchQueue.main.async { self.stopBatch("无法连接飞书", error.localizedDescription) }
            }
        }
    }

    private func continueSync(_ batch: SyncBatch<PreviewItem>) {
        statusLabel.stringValue = "正在同步 \(batch.nextIndex) / \(batch.items.count)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let finished = batch.run(perform: self.syncItem, title: {
                $0.snapshot?.event.title ?? $0.record?.title ?? "未知日程"
            }, progress: { index in
                DispatchQueue.main.async { self.statusLabel.stringValue = "正在同步 \(index) / \(batch.items.count)…" }
            })
            DispatchQueue.main.async {
                if !finished {
                    self.connectionLabel.stringValue = "飞书授权已失效"
                    if batch.attemptedAuthorization {
                        self.stopBatch("同步已暂停", "重新授权后仍无法操作日历。请检查飞书应用权限，再预览并确认剩余项目。")
                    } else {
                        batch.attemptedAuthorization = true
                        self.beginAuthorization()
                    }
                    return
                }
                self.activeBatch = nil
                self.setBusy(false)
                self.buildPreview()
                self.statusLabel.stringValue = "同步完成：成功 \(batch.succeeded) 项，失败 \(batch.failures.count) 项"
                if batch.failures.isEmpty {
                    self.showAlert("同步完成", "已成功处理 \(batch.succeeded) 个飞书日程，并标记为忙碌。")
                } else {
                    self.showAlert("部分日程同步失败", batch.failures.prefix(8).joined(separator: "\n"))
                }
            }
        }
    }

    private func stopBatch(_ title: String, _ message: String) {
        activeBatch = nil
        setBusy(false)
        buildPreview()
        statusLabel.stringValue = title
        showAlert(title, message)
    }

    private func syncItem(_ item: PreviewItem) throws {
        switch item.action {
        case .create:
            guard let snapshot = item.snapshot else { return }
            let response = try cli.call([
                "calendar", "events", "create", "--as", "user", "--calendar-id", "primary",
                "--idempotency-key", hash(snapshot.sourceKey), "--data", json(snapshot.payload), "--format", "json"
            ])
            guard let eventID = eventID(from: response) else { throw CLIError.failed("飞书未返回日程 ID") }
            records[snapshot.sourceKey] = record(for: snapshot, eventID: eventID)
        case .update:
            guard let snapshot = item.snapshot, let old = item.record else { return }
            _ = try cli.call([
                "calendar", "events", "patch", "--as", "user", "--calendar-id", "primary",
                "--event-id", old.feishuEventID, "--data", json(snapshot.payload), "--format", "json"
            ])
            records[snapshot.sourceKey] = record(for: snapshot, eventID: old.feishuEventID)
        case .delete:
            guard let old = item.record else { return }
            _ = try cli.call([
                "calendar", "events", "delete", "--as", "user", "--calendar-id", "primary",
                "--event-id", old.feishuEventID, "--need-notification", "false", "--format", "json"
            ])
            records.removeValue(forKey: old.sourceKey)
        default: return
        }
        try saveRecords()
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
        window.setContentSize(NSSize(width: 760, height: 730))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        (window.contentViewController as? SyncViewController)?.stopRunningCommands()
    }
}

@main
private enum AppleToFeishuApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
