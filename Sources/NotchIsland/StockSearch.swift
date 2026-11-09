import Foundation
import Combine

/// Settings search for stocks: debounced, cancels the previous request, and
/// only the latest query's answer may update the list (late answers to older
/// queries are dropped). Searching happens only while the user types in
/// Settings.
@MainActor
final class StockSearchModel: ObservableObject {
    enum Phase: Equatable { case idle, searching, results, empty, failed(ProviderError) }

    @Published private(set) var query = ""
    @Published private(set) var results: [SymbolMatch] = []
    @Published private(set) var phase: Phase = .idle
    /// Exchange name to show, or nil for all.
    @Published var exchangeFilter: String?

    private let debounce: Duration
    private let search: @MainActor (String) async throws -> [SymbolMatch]
    private var task: Task<Void, Never>?
    private var generation = 0

    init(debounce: Duration = .milliseconds(350), search: @escaping @MainActor (String) async throws -> [SymbolMatch]) {
        self.debounce = debounce
        self.search = search
    }

    /// Exchanges present in the results, in result order.
    var exchanges: [String] {
        var seen = Set<String>()
        return results.map(\.exchangeName).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var filtered: [SymbolMatch] {
        guard let exchangeFilter else { return results }
        return results.filter { $0.exchangeName == exchangeFilter }
    }

    func update(query newQuery: String) {
        query = newQuery
        generation += 1
        let token = generation
        task?.cancel()
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { results = []; phase = .idle; exchangeFilter = nil; return }
        phase = .searching
        task = Task { [weak self, debounce, search] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let outcome: Result<[SymbolMatch], ProviderError>
            do { outcome = .success(try await search(trimmed)) } catch { outcome = .failure(ProviderError(error)) }
            guard let self, self.generation == token else { return } // a newer query owns the list
            switch outcome {
            case .success(let matches):
                self.results = matches
                self.phase = matches.isEmpty ? .empty : .results
                if let filter = self.exchangeFilter, !self.exchanges.contains(filter) { self.exchangeFilter = nil }
            case .failure(.cancelled):
                break
            case .failure(let error):
                self.results = []
                self.phase = .failed(error)
            }
        }
    }

    func clear() { update(query: "") }

    /// Tests: wait for the in-flight search.
    func waitForIdle() async { await task?.value }
}
