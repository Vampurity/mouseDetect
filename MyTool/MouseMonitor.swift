import Foundation
import IOKit
import IOKit.hid

/// 监听外接鼠标的接入和拔出。
/// 有鼠标时关闭「自然滚动」，全部拔出后重新打开。
/// 只看 IORegistry 里的设备出现和消失，不打开 HID，因此不需要「输入监视」权限。
final class MouseMonitor {
    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var mice: [UInt64: String] = [:]
    private var loggedIgnored: Set<UInt64> = []
    private var mouseConnected = false
    private var didApply = false
    private var enableNaturalWork: DispatchWorkItem?
    private var signalSources: [DispatchSourceSignal] = []

    /// 蓝牙鼠标休眠时会短暂从注册表消失。拔出后稍等再打开自然滚动，避免来回切换。
    private let disconnectDelay: TimeInterval = 2

    func run() throws -> Never {
        try startNotifications()
        if mice.isEmpty {
            log("当前没有外接鼠标")
        } else {
            let names = mice.values.sorted().joined(separator: "、")
            log("当前已接入外接鼠标: \(names)")
        }
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/local.mouseDetect.plist")
        if FileManager.default.fileExists(atPath: plist.path) {
            log("正在监听鼠标插拔")
        } else {
            log("正在监听鼠标插拔。若要登录后一直驻留后台，执行 mouseDetect install")
        }
        applyScrollSetting()
        installSignalHandlers()
        CFRunLoopRun()
        exit(0)
    }

    func printStatus() throws {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, try mouseMatching(), &iterator)
        guard result == KERN_SUCCESS else {
            throw MonitorError.registryFailed(result)
        }
        drain(iterator, added: true, announce: false, updateSetting: false, reportIgnored: false)
        IOObjectRelease(iterator)

        let names = mice.values.sorted()
        if names.isEmpty {
            print("外接鼠标: 无")
        } else {
            print("外接鼠标: \(names.joined(separator: "、"))")
        }
        print("自然滚动: \(NaturalScrolling.isEnabled() ? "开" : "关")")
    }

    private func startNotifications() throws {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw MonitorError.registryFailed(KERN_FAILURE)
        }
        notificationPort = port
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
            .defaultMode
        )

        let context = Unmanaged.passUnretained(self).toOpaque()
        let addResult = IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            try mouseMatching(),
            { context, iterator in
                guard let context else { return }
                let monitor = Unmanaged<MouseMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.drain(iterator, added: true, announce: true, updateSetting: true, reportIgnored: true)
            },
            context,
            &addedIterator
        )
        guard addResult == KERN_SUCCESS else {
            throw MonitorError.registryFailed(addResult)
        }
        drain(addedIterator, added: true, announce: false, updateSetting: false, reportIgnored: true)

        let removeResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            try mouseMatching(),
            { context, iterator in
                guard let context else { return }
                let monitor = Unmanaged<MouseMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.drain(iterator, added: false, announce: false, updateSetting: true, reportIgnored: false)
            },
            context,
            &removedIterator
        )
        guard removeResult == KERN_SUCCESS else {
            throw MonitorError.registryFailed(removeResult)
        }
        drain(removedIterator, added: false, announce: false, updateSetting: false, reportIgnored: false)
    }

    private func mouseMatching() throws -> CFDictionary {
        guard let dictionary = IOServiceMatching("IOHIDDevice") else {
            throw MonitorError.registryFailed(KERN_FAILURE)
        }
        let matching = dictionary as NSMutableDictionary
        matching[kIOHIDPrimaryUsagePageKey] = NSNumber(value: kHIDPage_GenericDesktop)
        matching[kIOHIDPrimaryUsageKey] = NSNumber(value: kHIDUsage_GD_Mouse)
        return matching
    }

    private func drain(
        _ iterator: io_iterator_t,
        added: Bool,
        announce: Bool,
        updateSetting: Bool,
        reportIgnored: Bool
    ) {
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            if added {
                handleAdded(service, announce: announce, updateSetting: updateSetting, reportIgnored: reportIgnored)
            } else {
                handleRemoved(service)
            }
            IOObjectRelease(service)
        }
    }

    private func handleAdded(
        _ service: io_registry_entry_t,
        announce: Bool,
        updateSetting: Bool,
        reportIgnored: Bool
    ) {
        guard let entry = entryID(service) else { return }
        let name = productName(service)
        guard isExternalMouse(service) else {
            if reportIgnored, isMouseDevice(service), loggedIgnored.insert(entry).inserted {
                log("忽略 \(name): \(ignoreReason(service))")
            }
            return
        }

        let isNewMouse = mice[entry] == nil
        mice[entry] = name
        guard isNewMouse else { return }
        if announce {
            log("鼠标接入: \(name)")
        }
        if updateSetting {
            applyScrollSetting()
        }
    }

    private func handleRemoved(_ service: io_registry_entry_t) {
        guard let entry = entryID(service), let name = mice.removeValue(forKey: entry) else { return }
        log("鼠标拔出: \(name)")
        applyScrollSetting()
    }

    private func applyScrollSetting() {
        let connected = !mice.isEmpty
        if connected {
            enableNaturalWork?.cancel()
            enableNaturalWork = nil
            let shouldUpdate = !didApply || !mouseConnected
            mouseConnected = true
            didApply = true
            guard shouldUpdate else { return }
            if NaturalScrolling.setEnabled(false) {
                log("已关闭自然滚动")
            } else {
                log("自然滚动已经是关闭状态")
            }
            return
        }

        if !didApply {
            didApply = true
            mouseConnected = false
            if NaturalScrolling.setEnabled(true) {
                log("已打开自然滚动")
            } else {
                log("自然滚动已经是打开状态")
            }
            return
        }

        guard mouseConnected else { return }
        enableNaturalWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mice.isEmpty else { return }
            self.mouseConnected = false
            if NaturalScrolling.setEnabled(true) {
                log("已打开自然滚动")
            } else {
                log("自然滚动已经是打开状态")
            }
        }
        enableNaturalWork = work
        log("外接鼠标已全部拔出，\(Int(disconnectDelay)) 秒后打开自然滚动")
        DispatchQueue.main.asyncAfter(deadline: .now() + disconnectDelay, execute: work)
    }

    private func isExternalMouse(_ service: io_registry_entry_t) -> Bool {
        guard isMouseDevice(service) else { return false }
        if isBuiltIn(service) { return false }
        let name = productName(service).lowercased()
        let blockedFragments = ["trackpad", "touchpad", "touch pad", "keyboard", "keybord", "dongle"]
        return !blockedFragments.contains(where: name.contains)
    }

    private func isMouseDevice(_ service: io_registry_entry_t) -> Bool {
        intProperty(service, kIOHIDPrimaryUsagePageKey) == Int(kHIDPage_GenericDesktop)
            && intProperty(service, kIOHIDPrimaryUsageKey) == Int(kHIDUsage_GD_Mouse)
    }

    private func isBuiltIn(_ service: io_registry_entry_t) -> Bool {
        if boolProperty(service, kIOHIDBuiltInKey) { return true }
        let transport = (stringProperty(service, kIOHIDTransportKey) ?? "").lowercased()
        return transport == "spi" || transport == "spmi"
    }

    private func ignoreReason(_ service: io_registry_entry_t) -> String {
        if isBuiltIn(service) { return "内置触控板或键盘" }
        return "设备名像触控板或键盘接收器，不当作鼠标"
    }

    private func productName(_ service: io_registry_entry_t) -> String {
        stringProperty(service, kIOHIDProductKey) ?? "未知鼠标"
    }

    private func entryID(_ service: io_registry_entry_t) -> UInt64? {
        var identifier: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS else { return nil }
        return identifier
    }

    private func property(_ service: io_registry_entry_t, _ key: String) -> AnyObject? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return value.takeRetainedValue()
    }

    private func stringProperty(_ service: io_registry_entry_t, _ key: String) -> String? {
        property(service, key) as? String
    }

    private func intProperty(_ service: io_registry_entry_t, _ key: String) -> Int? {
        (property(service, key) as? NSNumber)?.intValue
    }

    private func boolProperty(_ service: io_registry_entry_t, _ key: String) -> Bool {
        (property(service, key) as? NSNumber)?.boolValue ?? false
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                log("停止监听")
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

private enum MonitorError: LocalizedError {
    case registryFailed(kern_return_t)

    var errorDescription: String? {
        switch self {
        case .registryFailed(let code):
            return "无法监听设备插拔（kern_return \(code)）。"
        }
    }
}

private let logTimestamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

func log(_ message: String) {
    print("\(logTimestamp.string(from: Date())) \(message)")
    fflush(stdout)
}
