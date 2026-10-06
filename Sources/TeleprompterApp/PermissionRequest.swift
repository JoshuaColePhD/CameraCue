import Foundation

/// OS permission callbacks can remain pending when privacy attribution fails.
/// Release setup without allowing a late callback to resume an old operation.
@MainActor enum PermissionRequest {
    static func wait(timeout: Duration = .seconds(30),
                     request: (@escaping @Sendable (Bool) -> Void) -> Void) async -> Bool? {
        let completion = PermissionCompletion()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.install(continuation)
                guard !Task.isCancelled else { completion.resolve(nil); return }
                request { completion.resolve($0) }
                Task {
                    try? await Task.sleep(for: timeout)
                    completion.resolve(nil)
                }
            }
        } onCancel: { completion.resolve(nil) }
    }
}

private final class PermissionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool?, Never>?
    private var finished = false
    private var result: Bool?
    func install(_ value: CheckedContinuation<Bool?, Never>) {
        lock.lock()
        if finished {
            let result = result
            lock.unlock()
            value.resume(returning: result)
        } else {
            continuation = value
            lock.unlock()
        }
    }
    func resolve(_ value: Bool?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; result = value
        let callback = continuation
        continuation = nil
        lock.unlock()
        callback?.resume(returning: value)
    }
}
