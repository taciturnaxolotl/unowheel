import Foundation

/// FIFO of pending continuations for one kind of GATT callback. Each wait
/// carries its own timeout, which resumes the continuation directly so a
/// silent board can never strand a caller.
@MainActor
final class Waiters<T: Sendable> {
    private var items: [(id: Int, continuation: CheckedContinuation<T, Error>)] = []
    private var nextID = 0

    var isEmpty: Bool { items.isEmpty }

    func wait(timeout: Double, what: String, start: () -> Void) async throws -> T {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            items.append((id, continuation))
            start()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.fail(id: id, BoardError.timeout(what))
            }
        }
    }

    @discardableResult
    func resumeFirst(_ result: Result<T, Error>) -> Bool {
        guard !items.isEmpty else { return false }
        items.removeFirst().continuation.resume(with: result)
        return true
    }

    func failAll(_ error: Error) {
        let pending = items
        items.removeAll()
        pending.forEach { $0.continuation.resume(throwing: error) }
    }

    private func fail(id: Int, _ error: Error) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index).continuation.resume(throwing: error)
    }
}

@MainActor
final class WaiterTable<T: Sendable> {
    private var tables: [String: Waiters<T>] = [:]

    subscript(key: String) -> Waiters<T> {
        if let existing = tables[key] { return existing }
        let created = Waiters<T>()
        tables[key] = created
        return created
    }

    func failAll(_ error: Error) {
        tables.values.forEach { $0.failAll(error) }
    }
}
