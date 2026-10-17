import Foundation

actor VolumeGate {
    private var inFlight = 0
    private var closed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isClosed: Bool { closed }

    func begin() throws {
        if closed {
            throw POSIXError(.ENXIO)
        }
        inFlight += 1
    }

    func end() {
        inFlight -= 1
        guard closed, inFlight == 0 else { return }
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func closeAndWait() async {
        closed = true
        if inFlight == 0 { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func withPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try begin()
        let result: Result<T, Error>
        do {
            result = .success(try await body())
        } catch {
            result = .failure(error)
        }
        end()
        return try result.get()
    }
}
