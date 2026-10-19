import Foundation

enum ServiceInstaller {
    static let label = "local.mouseDetect"

    static func install() throws {
        let paths = try Paths()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)

        if paths.executable != paths.installedBinary {
            if fileManager.fileExists(atPath: paths.installedBinary.path) {
                try fileManager.removeItem(at: paths.installedBinary)
            }
            try fileManager.copyItem(at: paths.executable, to: paths.installedBinary)
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.installedBinary.path)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [paths.installedBinary.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "ThrottleInterval": 2,
            "StandardOutPath": paths.logFile.path,
            "StandardErrorPath": paths.logFile.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: paths.plist, options: .atomic)

        let domain = "gui/\(getuid())"
        _ = runLaunchctl(["bootout", domain, paths.plist.path])
        let bootstrapped = runLaunchctl(["bootstrap", domain, paths.plist.path])
        _ = runLaunchctl(["enable", "\(domain)/\(label)"])
        guard bootstrapped == 0 else {
            throw InstallError.launchctlFailed(bootstrapped)
        }

        print("已安装后台服务，登录后会自动运行。")
        print("程序: \(paths.installedBinary.path)")
        print("日志: \(paths.logFile.path)")
        print("移除: mouseDetect uninstall")
    }

    static func uninstall() throws {
        let paths = try Paths()
        let domain = "gui/\(getuid())"
        _ = runLaunchctl(["bootout", domain, paths.plist.path])
        _ = runLaunchctl(["bootout", "\(domain)/\(label)"])

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: paths.plist.path) {
            try fileManager.removeItem(at: paths.plist)
        }
        if fileManager.fileExists(atPath: paths.installedBinary.path) {
            try fileManager.removeItem(at: paths.installedBinary)
        }
        if fileManager.fileExists(atPath: paths.supportDirectory.path),
           let children = try? fileManager.contentsOfDirectory(atPath: paths.supportDirectory.path),
           children.isEmpty {
            try? fileManager.removeItem(at: paths.supportDirectory)
        }
        print("已移除后台服务。当前的自然滚动状态保持不变。")
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private struct Paths {
    let executable: URL
    let installedBinary: URL
    let supportDirectory: URL
    let plist: URL
    let logFile: URL

    init() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let executablePath = Bundle.main.executableURL?.resolvingSymlinksInPath()
            ?? CommandLine.arguments.first.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath() }) else {
            throw InstallError.missingExecutable
        }
        executable = executablePath
        supportDirectory = home.appendingPathComponent("Library/Application Support/mouseDetect", isDirectory: true)
        installedBinary = supportDirectory.appendingPathComponent("mouseDetect")
        plist = home.appendingPathComponent("Library/LaunchAgents/local.mouseDetect.plist")
        logFile = home.appendingPathComponent("Library/Logs/mouseDetect.log")
    }
}

private enum InstallError: LocalizedError {
    case missingExecutable
    case launchctlFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "找不到当前程序路径，无法安装。"
        case .launchctlFailed(let code):
            return "launchctl 加载失败，退出码 \(code)。"
        }
    }
}
