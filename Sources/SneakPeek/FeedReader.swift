import Foundation
import SneakPeekCore

struct FeedReadResult: Sendable {
    let feed: Feed
    let succeeded: Bool
}

protocol FeedReading: Sendable {
    func read(url: URL, journal: HumanJournal?, previous: Feed, now: Double) async -> FeedReadResult
}

actor LocalFeedReader: FeedReading {
    func read(url: URL, journal: HumanJournal?, previous: Feed, now: Double) -> FeedReadResult {
        Self.readSynchronously(url: url, journal: journal, previous: previous, now: now)
    }

    // The synchronous entry point is reserved for explicitly non-polling stores
    // (deterministic fixtures). Live refreshes run on this actor's executor.
    static func readSynchronously(url: URL, journal: HumanJournal?, previous: Feed, now: Double) -> FeedReadResult {
        do {
            let raw = try JSONDecoder().decode(Feed.self, from: Data(contentsOf: url))
            return FeedReadResult(feed: HumanProjection.project(raw, simulationJournal: journal, now: now), succeeded: true)
        } catch {
            return FeedReadResult(feed: HumanProjection.project(previous, simulationJournal: nil, now: now), succeeded: false)
        }
    }
}
