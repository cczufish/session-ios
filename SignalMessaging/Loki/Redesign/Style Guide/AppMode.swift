
public enum AppMode {
    case light, dark
    
    public static var current: AppMode = .light
}

public var isLightMode: Bool {
    return AppMode.current == .light
}

public var isDarkMode: Bool {
    return AppMode.current == .dark
}

@objc public final class LKAppModeUtilities : NSObject {

    @objc public static func isLightMode() -> Bool { return AppMode.current == .light }
    @objc public static func isDarkMode() -> Bool { return AppMode.current == .dark }
}
