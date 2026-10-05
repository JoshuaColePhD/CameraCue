import QuartzCore

enum NotchMotion {
    static let openDuration = 0.30
    static let closeDuration = 0.24
    static let revealDelay = 0.06
    static let revealDuration = 0.18
    static let hideDuration = 0.10
    static var curve: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    }
    static func duration(expanded: Bool) -> Double { expanded ? openDuration : closeDuration }
}
