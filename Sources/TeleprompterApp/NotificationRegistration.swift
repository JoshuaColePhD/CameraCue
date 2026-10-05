import Foundation

/// NotificationCenter supports removal from any thread. Keeping the immutable
/// token here avoids actor-isolated teardown trampolines on older Swift runtimes.
/// Delivery handlers use weak owners and hop to the owner's actor themselves.
final class NotificationRegistration: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol
    init(center: NotificationCenter = .default, name: Notification.Name,
         handler: @escaping @Sendable (Notification) -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: .main, using: handler)
    }
    deinit { center.removeObserver(token) }
}
