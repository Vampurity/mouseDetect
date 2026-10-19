import CoreFoundation
import Darwin
import Foundation

/// 「自然滚动」是全局开关，触控板和鼠标共用。
/// 只写 `com.apple.swipescrolldirection` 不会立刻生效，窗口服务器要到重新登录才读新值。
/// 系统设置本身调用的是 PreferencePanesSupport 里的 `setSwipeScrollDirection`。
enum NaturalScrolling {
    private typealias SetFunction = @convention(c) (Int32) -> Void
    private typealias GetFunction = @convention(c) () -> Int32

    private static let preferenceKey = "com.apple.swipescrolldirection" as CFString
    private static let support: (set: SetFunction, get: GetFunction)? = loadSupport()

    static var isSupported: Bool { support != nil }

    static func isEnabled() -> Bool {
        if let support {
            return support.get() != 0
        }
        guard let value = CFPreferencesCopyAppValue(preferenceKey, kCFPreferencesAnyApplication) else {
            return true
        }
        return (value as? NSNumber)?.boolValue ?? true
    }

    /// 返回 true 表示这次确实改了系统设置。
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard isEnabled() != enabled else { return false }

        CFPreferencesSetValue(
            preferenceKey,
            enabled ? kCFBooleanTrue : kCFBooleanFalse,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        support?.set(enabled ? 1 : 0)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("SwipeScrollDirectionDidChangeNotification"),
            object: nil,
            userInfo: nil,
            options: .deliverImmediately
        )

        if support == nil {
            fputs("警告: 没能调用系统的滚动设置接口，偏好已写入，但可能要重新登录后才生效。\n", stderr)
        } else if isEnabled() != enabled {
            fputs("警告: 系统没有接受自然滚动的新状态。\n", stderr)
        }
        return true
    }

    private static func loadSupport() -> (set: SetFunction, get: GetFunction)? {
        let path = "/System/Library/PrivateFrameworks/PreferencePanesSupport.framework/PreferencePanesSupport"
        guard let handle = dlopen(path, RTLD_NOW),
              let setSymbol = dlsym(handle, "setSwipeScrollDirection"),
              let getSymbol = dlsym(handle, "swipeScrollDirection") else {
            return nil
        }
        return (
            unsafeBitCast(setSymbol, to: SetFunction.self),
            unsafeBitCast(getSymbol, to: GetFunction.self)
        )
    }
}
