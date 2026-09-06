import XCTest
@testable import OpenSuperWhisper

private actor PageGate {
    var requests: [String: CheckedContinuation<[Recording], Error>] = [:]
    func fetch(_ query: String) async throws -> [Recording] {
        try await withCheckedThrowingContinuation { requests[query] = $0 }
    }
    func hasRequest(_ query: String) -> Bool { requests[query] != nil }
    func finish(_ query: String, result: Result<[Recording], Error>) {
        requests.removeValue(forKey: query)?.resume(with: result)
    }
}

@MainActor
final class RecordingSearchTests: XCTestCase {
    private func waitFor(_ query: String, gate: PageGate) async throws {
        for _ in 0..<100 {
            if await gate.hasRequest(query) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Missing fetch")
    }
    private func waitForIdle(_ vm: ContentViewModel) async throws {
        for _ in 0..<100 where vm.isLoadingMore {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(vm.isLoadingMore)
    }
    func testNewSearchRunsWhilePreviousRequestIsPending() async throws {
        let gate = PageGate()
        let vm = ContentViewModel(fetchPage: { query, _, _ in try await gate.fetch(query) })
        vm.loadInitialData()
        try await waitFor("", gate: gate)
        vm.search(query: "new")
        try await waitFor("new", gate: gate)
        let id = UUID()
        let row = Recording(id: id, timestamp: Date(), fileName: Recording.fileName(for: id),
                            transcription: "new result", duration: 1, status: .completed, progress: 1)
        await gate.finish("new", result: .success([row]))
        try await waitForIdle(vm)
        await gate.finish("", result: .success([]))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(vm.recordings.map(\.id), [id])
    }
    func testFetchFailureClearsLoadingAndAllowsRetry() async throws {
        let gate = PageGate()
        let vm = ContentViewModel(fetchPage: { query, _, _ in try await gate.fetch(query) })
        vm.loadInitialData()
        try await waitFor("", gate: gate)
        await gate.finish("", result: .failure(TranscriptionError.processingFailed))
        try await waitForIdle(vm)
        XCTAssertNotNil(vm.loadingError)
        vm.loadMore()
        try await waitFor("", gate: gate)
        await gate.finish("", result: .success([]))
        try await waitForIdle(vm)
        XCTAssertNil(vm.loadingError)
    }
}
