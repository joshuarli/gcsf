import Synchronization

final class OnceReply<Value>: @unchecked Sendable {
    private let fired = Mutex(false)

    func send(_ value: Value, _ body: (Value) -> Void) {
        let first = fired.withLock { fired in
            if fired { return false }
            fired = true
            return true
        }
        if first {
            body(value)
        }
    }
}
