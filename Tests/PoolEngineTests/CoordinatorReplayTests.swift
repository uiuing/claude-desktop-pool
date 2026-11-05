import Foundation
import XCTest
import PoolCore
@testable import PoolEngine

/// Claude Code's own behaviour after a failed or interrupted turn, as the bridge serves it: a tool
/// result is never refused because the run that made the call is gone; it goes on in a new run told the
/// whole conversation.
final class CoordinatorReplayTests: XCTestCase {
    private let call = BridgeToolCall(id: "toolu_fixture_01", name: "Read", input: .object(["file_path": .string("/fixture/notes.txt")]))
    private let tools = [BridgeTool(name: "Read", inputSchema: .object(["type": .string("object")]))]

    private func account() -> PoolAccount {
        .init(id: UUID(uuidString: "0a1b2c3d-2222-4aaa-8bbb-000000000001")!, email: "a•••@gmail.com", plan: "Max", state: .ready,
              createdAt: Date(timeIntervalSince1970: 1))
    }
    private func first() -> BridgeRequest {
        .init(model: "claude-sonnet", messages: [.init(role: "user", content: .string("Summarise the synthetic notes."))], tools: tools)
    }
    private func withResult(_ request: BridgeRequest, call: BridgeToolCall? = nil) -> BridgeRequest {
        let call = call ?? self.call
        var next = request
        next.messages += [.init(role: "assistant", content: .array([.object(["type": .string("text"), "text": .string("Reading it.")]),
                                                                    .object(["type": .string("tool_use"), "id": .string(call.id),
                                                                             "name": .string(call.name), "input": call.input])])),
                          .init(role: "user", content: .array([.object(["type": .string("tool_result"), "tool_use_id": .string(call.id),
                                                                        "content": .string("Synthetic notes: three items.")])]))]
        return next
    }
    private func pool(_ factory: ReplayFactory, capacity: Int = 4, duplicateWait: TimeInterval = 0.1, parkedMost: Int = 16,
                      clock: ReplayClock = ReplayClock()) -> PoolCoordinator {
        PoolCoordinator(accounts: [account()], maximumWorkers: capacity, roomWait: 0, parkedMost: parkedMost, duplicateWait: duplicateWait,
                        now: { clock.now }, factory: { _, _ in try await factory.make() })
    }
    private func collect(_ pool: PoolCoordinator, _ request: BridgeRequest, id: String = "claude-code-session") async throws -> [BridgeEvent] {
        var events: [BridgeEvent] = []
        for try await event in try await pool.events(for: request, conversationID: id) {
            if case .usage = event { continue }
            events.append(event)
        }
        return events
    }

    func testStreamErrorThenImmediateRetryWithTheSameResultIsReplayedNotRefused() async throws {
        let original = ReplayWorker(steps: [.reply([.text("Reading it."), .toolUse(call), .finished(.toolUse)]), .failure([], .transport)])
        let retry = ReplayWorker(steps: [.hold([])])
        let factory = ReplayFactory([original, retry])
        let pool = pool(factory)
        _ = try await collect(pool, first())
        let next = withResult(first())
        // The streamed reply to the result fails (a stream error), and the run that made the call stops.
        do { _ = try await collect(pool, next); XCTFail("The stream error was hidden.") }
        catch { XCTAssertEqual(error as? BridgeFailure, .transport) }
        // Claude Code retries at once, without streaming, with the same tool_result.
        var again = next; again.stream = false
        let stream = try await pool.events(for: again, conversationID: "claude-code-session")
        try await replayWait { await retry.replays.count == 1 }
        await retry.release([.text("Three items."), .finished(.endTurn)])
        var events: [BridgeEvent] = []
        for try await event in stream { if case .usage = event { continue }; events.append(event) }
        XCTAssertEqual(events, [.text("Three items."), .finished(.endTurn)])
        let replays = await retry.replays, regular = await retry.regular, cancels = await retry.cancels, closes = await original.closes
        XCTAssertEqual(replays, [again]); XCTAssertTrue(regular.isEmpty); XCTAssertEqual(cancels, 0)
        XCTAssertEqual(closes, 1, "The stopped run is ended normally, not left holding room.")
        _ = await pool.shutdown()
    }

    func testCancellingTheFirstRequestNeverStopsARetryAdmittedMeanwhile() async throws {
        let original = ReplayWorker(steps: [.hold([.text("Partial")])])
        let retry = ReplayWorker(steps: [.hold([])])
        let factory = ReplayFactory([original, retry])
        let pool = pool(factory)
        let firstStream = try await pool.events(for: first(), conversationID: "claude-code-session")
        let firstTask = Task { for try await _ in firstStream {} }
        try await replayWait { await original.regular.count == 1 }
        // The resend arrives while the first is still answered: past the short wait it gets a run of its own.
        let secondStream = try await pool.events(for: first(), conversationID: "claude-code-session")
        let secondTask = Task { var events: [BridgeEvent] = []; for try await event in secondStream { events.append(event) }; return events }
        try await replayWait { await retry.regular.count == 1 }
        // The first response is dropped: only its own request is cancelled.
        firstTask.cancel()
        _ = try? await firstTask.value
        try await replayWait { await original.cancels >= 1 }
        await retry.release([.text("Whole answer."), .finished(.endTurn)])
        let events = try await secondTask.value
        XCTAssertTrue(events.contains(.finished(.endTurn)))
        let retryCancels = await retry.cancels
        XCTAssertEqual(retryCancels, 0)
        _ = await pool.shutdown()
    }

    func testDuplicateOfResultsBeingAnsweredGoesOnInARunOfItsOwn() async throws {
        let original = ReplayWorker(steps: [.reply([.text("Reading it."), .toolUse(call), .finished(.toolUse)]), .hold([])])
        let duplicate = ReplayWorker(steps: [.reply([.text("Answered on its own."), .finished(.endTurn)])])
        let factory = ReplayFactory([original, duplicate])
        let pool = pool(factory)
        _ = try await collect(pool, first())
        let next = withResult(first())
        let stream = try await pool.events(for: next, conversationID: "claude-code-session")
        let answering = Task { var events: [BridgeEvent] = []; for try await event in stream { if case .usage = event { continue }; events.append(event) }; return events }
        try await replayWait { await original.regular.count == 2 }
        // The run takes one set of results; the second request is told the whole conversation.
        let second = try await collect(pool, next)
        XCTAssertEqual(second, [.text("Answered on its own."), .finished(.endTurn)])
        await original.release([.text("Answered in the run."), .finished(.endTurn)])
        let firstEvents = try await answering.value
        XCTAssertEqual(firstEvents, [.text("Answered in the run."), .finished(.endTurn)])
        let replays = await duplicate.replays
        XCTAssertEqual(replays, [next])
        _ = await pool.shutdown()
    }

    func testRewindWhileCallsArePendingStartsTheEditedTurnInANewRun() async throws {
        let clock = ReplayClock()
        let original = ReplayWorker(steps: [.reply([.toolUse(call), .finished(.toolUse)])])
        let edited = ReplayWorker(steps: [.reply([.text("Edited answer."), .finished(.endTurn)])])
        let factory = ReplayFactory([original, edited])
        let pool = pool(factory, clock: clock)
        _ = try await collect(pool, first())
        // The person rewound and edited their message: the client goes on without the call's result.
        let rewound = BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .string("Summarise only the first note."))], tools: tools)
        let answer = try await collect(pool, rewound)
        XCTAssertEqual(answer, [.text("Edited answer."), .finished(.endTurn)])
        let received = await edited.regular
        XCTAssertEqual(received, [rewound])
        // The abandoned run waits parkLongest more, then is let go normally.
        let kept = await original.closes
        XCTAssertEqual(kept, 0)
        clock.advance(301)
        await pool.retireIdle()
        let closes = await original.closes
        XCTAssertEqual(closes, 1)
        _ = await pool.shutdown()
    }

    func testParkedRunsBeyondTheCapAreLetGoOldestFirst() async throws {
        let clock = ReplayClock()
        let calls = (0..<3).map { BridgeToolCall(id: "toolu_fixture_cap_\($0)", name: "Read", input: .object([:])) }
        let workers = calls.map { ReplayWorker(steps: [.reply([.toolUse($0), .finished(.toolUse)])]) }
        let factory = ReplayFactory(workers)
        let pool = pool(factory, parkedMost: 1, clock: clock)
        for index in 0..<3 {
            var request = first(); request.messages[0].content = .string("Synthetic subagent \(index).")
            _ = try await collect(pool, request, id: "subagent-\(index)")
            clock.advance(1)
        }
        clock.advance(300)
        await pool.retireIdle()
        let closes = [await workers[0].closes, await workers[1].closes, await workers[2].closes]
        XCTAssertEqual(closes, [1, 1, 0])
        _ = await pool.shutdown()
    }

    func testLongHistoryIsAcceptedAndANormalizedNextTurnStaysInItsRun() async throws {
        var messages: [BridgeMessage] = []
        for index in 0..<2999 {
            messages.append(.init(role: index.isMultiple(of: 2) ? "user" : "assistant", content: .string("Synthetic turn \(index).")))
        }
        let long = BridgeRequest(model: "claude-sonnet", messages: messages)
        XCTAssertEqual(long.messages.count, 2999)
        let worker = ReplayWorker(steps: [.reply([.text("First part.\n\nSecond part."), .finished(.endTurn)]),
                                          .reply([.text("Next."), .finished(.endTurn)])])
        let factory = ReplayFactory([worker])
        let pool = pool(factory)
        _ = try await collect(pool, long)
        // The client sends it back with whitespace changed, the reply split in two with a thinking block,
        // and two new user messages: still the same conversation (its messages are compared by content, not formatting).
        var next = long
        next.messages[10].content = .string("  Synthetic   turn 10. ")
        next.messages += [.init(role: "assistant", content: .array([.object(["type": .string("thinking"), "thinking": .string("Synthetic.")]),
                                                                    .object(["type": .string("text"), "text": .string("First part.")])])),
                          .init(role: "assistant", content: .array([.object(["type": .string("text"), "text": .string("Second part.")])])),
                          .init(role: "user", content: .string("A note.")), .init(role: "user", content: .string("And a question."))]
        XCTAssertEqual(next.messages.count, 3003)
        let answer = try await collect(pool, next)
        XCTAssertEqual(answer, [.text("Next."), .finished(.endTurn)])
        let count = await factory.count, received = await worker.regular
        XCTAssertEqual(count, 1)
        XCTAssertEqual(received.last?.messages.last?.content.arrayValue?.compactMap { $0["text"]?.stringValue }, ["A note.", "And a question."])
        _ = await pool.shutdown()
    }

    func testARewrittenLastTurnStaysInItsRunAndAnEarlierEditDoesNot() {
        let was: [BridgeMessage] = [.init(role: "user", content: .string("Hello")), .init(role: "assistant", content: .string("Hi there.")),
                                    .init(role: "user", content: .string("[Context: synthetic] Tell me more.")),
                                    .init(role: "assistant", content: .string("More words. [notice]"))]
        var cut = was
        cut[2].content = .string("Tell me more."); cut[3].content = .string("More words.")
        XCTAssertTrue(ConversationWords.rewrote(cut, was: was))
        var earlier = cut; earlier[0].content = .string("Goodbye")
        XCTAssertFalse(ConversationWords.rewrote(earlier, was: was))
        var replaced = was; replaced[2].content = .string("Something else entirely.")
        XCTAssertFalse(ConversationWords.rewrote(replaced, was: was))
    }

    /// The client keeps the reply its own way (its text before the call, worded as it has it): the run that
    /// made the call still takes the result, as only what the run was told is compared.
    func testToolResultsStayInTheirRunWhateverTheClientKeptOfTheReply() async throws {
        let original = ReplayWorker(steps: [.reply([.toolUse(call), .text("Reading the synthetic file."), .finished(.toolUse)]),
                                            .reply([.text("Three items."), .finished(.endTurn)])])
        let factory = ReplayFactory([original])
        let pool = pool(factory)
        _ = try await collect(pool, first())
        let answer = try await collect(pool, withResult(first()))
        XCTAssertEqual(answer, [.text("Three items."), .finished(.endTurn)])
        let regular = await original.regular.count, replays = await original.replays.count, made = await factory.count
        XCTAssertEqual(regular, 2); XCTAssertEqual(replays, 0); XCTAssertEqual(made, 1)
        _ = await pool.shutdown()
    }

    /// Earlier messages the client rewrote are not the run's conversation: the results go on in a run of
    /// their own. The conversation's own run that made the call is ended normally, since the new run
    /// carries the conversation now (Pool's own design).
    func testToolResultsAfterAnEarlierMessageChangedGoOnInARunOfTheirOwn() async throws {
        let original = ReplayWorker(steps: [.reply([.text("Reading it."), .toolUse(call), .finished(.toolUse)])])
        let fresh = ReplayWorker(steps: [.reply([.text("Three items."), .finished(.endTurn)])])
        let factory = ReplayFactory([original, fresh])
        let pool = pool(factory)
        _ = try await collect(pool, first())
        var next = withResult(first())
        next.messages[0].content = .string("Summarise the synthetic notes, compacted.")
        let answer = try await collect(pool, next)
        XCTAssertEqual(answer, [.text("Three items."), .finished(.endTurn)])
        let replays = await fresh.replays.count, closes = await original.closes
        XCTAssertEqual(replays, 1)
        try await replayWait { await original.closes == 1 }
        _ = closes
        _ = await pool.shutdown()
    }

    /// A new conversation that finds the room full waits for a run
    /// to come free instead of being answered busy at once.
    func testANewConversationWaitsForRoomInsteadOfBusy() async throws {
        let busy = ReplayWorker(steps: [.hold([])])
        let next = ReplayWorker(steps: [.reply([.text("Second."), .finished(.endTurn)])])
        let factory = ReplayFactory([busy, next])
        let pool = PoolCoordinator(accounts: [account()], maximumWorkers: 1, roomWait: 5, duplicateWait: 0.1,
                                   factory: { _, _ in try await factory.make() })
        let held = try await pool.events(for: first(), conversationID: "room-first")
        try await replayWait { await busy.regular.count == 1 }
        var other = self.first(); other.messages[0].content = .string("Another synthetic conversation.")
        let second = Task { try await self.collect(pool, other, id: "room-second") }
        try await Task.sleep(nanoseconds: 300_000_000)
        let waiting = await factory.count
        XCTAssertEqual(waiting, 1, "The second conversation waited for room.")
        await busy.release([.text("First."), .finished(.endTurn)])
        for try await _ in held {}
        let answer = try await second.value
        XCTAssertEqual(answer, [.text("Second."), .finished(.endTurn)])
        _ = await pool.shutdown()
    }

    /// A run released for a rewritten conversation is kept for its own client's results (#2933), but it
    /// does not make a new conversation wait parkLongest for room.
    func testAReleasedRunGivesItsRoomAtOnceWhenRoomIsNeeded() async throws {
        let original = ReplayWorker(steps: [.reply([.text("Reading it."), .toolUse(call), .finished(.toolUse)])])
        let fresh = ReplayWorker(steps: [.hold([])])
        let another = ReplayWorker(steps: [.reply([.text("Another."), .finished(.endTurn)])])
        let factory = ReplayFactory([original, fresh, another])
        let pool = pool(factory, capacity: 2)
        _ = try await collect(pool, first())
        var next = withResult(first())
        next.messages[0].content = .string("Summarise the synthetic notes, compacted.")
        // the replayed results' run stays busy, so only the released run can make room; the results come
        // from another client session, so the run is released, not ended as its own conversation's is
        let replayed = try await pool.events(for: next, conversationID: "another-client-session")
        try await replayWait { await fresh.replays.count == 1 }
        let kept = await original.closes
        XCTAssertEqual(kept, 0, "Nothing needed its room yet.")
        var other = first(); other.messages[0].content = .string("Another synthetic conversation.")
        let answer = try await collect(pool, other, id: "room-other")
        XCTAssertEqual(answer, [.text("Another."), .finished(.endTurn)])
        let closes = await original.closes
        XCTAssertEqual(closes, 1, "The clock never moved: the released run gave its room up.")
        await fresh.release([.text("Three items."), .finished(.endTurn)])
        for try await _ in replayed {}
        _ = await pool.shutdown()
    }

    /// A run that has not been released keeps its room: its client is still running the call.
    func testARunWaitingOnItsCallsKeepsItsRoom() async throws {
        let original = ReplayWorker(steps: [.reply([.text("Reading it."), .toolUse(call), .finished(.toolUse)])])
        let pool = pool(ReplayFactory([original]), capacity: 1)
        _ = try await collect(pool, first())
        var other = first(); other.messages[0].content = .string("Another synthetic conversation.")
        do { _ = try await collect(pool, other, id: "room-other"); XCTFail("It took a waiting run's room.") }
        catch { XCTAssertEqual(error as? BridgeFailure, .busy) }
        let closes = await original.closes
        XCTAssertEqual(closes, 0)
        _ = await pool.shutdown()
    }

    /// A client that only took earlier images out keeps its conversation.
    func testOnlyImagesTakenOutIsTheSameConversation() {
        let image = JSONValue.object(["type": .string("image"), "source": .object(["type": .string("base64"), "media_type": .string("image/png"),
                                                                                  "data": .string("c3ludGhldGlj")])])
        let was: [BridgeMessage] = [.init(role: "user", content: .array([.object(["type": .string("text"), "text": .string("Look at this.")]), image]))]
        let kept: [BridgeMessage] = [.init(role: "user", content: .array([.object(["type": .string("text"), "text": .string("Look at this.")])])),
                                     .init(role: "assistant", content: .string("A chart.")), .init(role: "user", content: .string("Thanks."))]
        XCTAssertTrue(ConversationWords.lostMedia(was: was, now: kept))
        var edited = kept; edited[0].content = .string("Look at that.")
        XCTAssertFalse(ConversationWords.lostMedia(was: was, now: edited))
        XCTAssertFalse(ConversationWords.lostMedia(was: was, now: was), "Nothing was taken out.")
    }

    /// Claude Code takes its one-off reminders back out of the history, so a user message can arrive
    /// with fewer texts than the run heard: the run heard them, so the conversation goes on in it.
    /// A user's own words taken out do not.
    func testRemindersTakenOutIsTheSameConversation() {
        func text(_ s: String) -> JSONValue { .object(["type": .string("text"), "text": .string(s)]) }
        let use = JSONValue.object(["type": .string("tool_use"), "id": .string("toolu_fixture1"), "name": .string("Read"),
                                    "input": .object(["file_path": .string("/tmp/note.txt")])])
        let result = JSONValue.object(["type": .string("tool_result"), "tool_use_id": .string("toolu_fixture1"), "content": .string("Synthetic note.")])
        let reminder = "<system-reminder>\nThe user sent a new message while you were working:\nKeep going.\n</system-reminder>"
        let was: [BridgeMessage] = [
            .init(role: "user", content: .array([text("<system-reminder>\nSynthetic instructions.\n</system-reminder>"),
                                                 text("<system-reminder>\nSynthetic context.\n</system-reminder>"), text("Read the note.")])),
            .init(role: "assistant", content: .array([use])),
            .init(role: "user", content: .array([result, text(reminder)]))]
        var now = was
        now[0].content = .array([text("<system-reminder>\nSynthetic instructions.\n</system-reminder>"), text("Read the note.")])
        now[2].content = .array([result])
        now += [.init(role: "assistant", content: .string("Done.")), .init(role: "user", content: .string("Thanks."))]
        XCTAssertFalse(ConversationWords.follows(now, history: was))
        XCTAssertTrue(ConversationWords.lostNotices(was: was, now: now))
        var said = now; said[0].content = .array([text("<system-reminder>\nSynthetic instructions.\n</system-reminder>")])
        XCTAssertFalse(ConversationWords.lostNotices(was: was, now: said), "The user's own words were taken out.")
        var edited = now; edited[2].content = .array([.object(["type": .string("tool_result"), "tool_use_id": .string("toolu_fixture1"),
                                                               "content": .string("Another note.")])])
        XCTAssertFalse(ConversationWords.lostNotices(was: was, now: edited))
        XCTAssertFalse(ConversationWords.lostNotices(was: was, now: was), "Nothing was taken out.")
    }

    /// A run let go while it waits for its conversation's
    /// next turn keeps its session, and that turn goes on from it in a new run, told only the turn since.
    func testAnIdleRunLetGoKeepsItsSessionForTheNextTurn() async throws {
        let original = ReplayWorker(steps: [.reply([.text("Three items."), .finished(.endTurn)])], keeps: true)
        let resumed = ReplayWorker(steps: [.reply([.text("The second is longest."), .finished(.endTurn)])], keeps: true)
        let factory = ReplayFactory([original, resumed])
        let pool = PoolCoordinator(accounts: [account()], maximumWorkers: 4, idleMost: 0, roomWait: 0, duplicateWait: 0.1,
                                   factory: { _, _ in try await factory.make() })
        _ = try await collect(pool, first())
        // past idleMost the run is let go with its session kept, just after its reply ends
        try await replayWait { await original.shelves == 1 }
        var next = first()
        next.messages += [.init(role: "assistant", content: .array([.object(["type": .string("text"), "text": .string("Three items.")])])),
                          .init(role: "user", content: .string("Which is longest?"))]
        let answer = try await collect(pool, next)
        XCTAssertEqual(answer, [.text("The second is longest."), .finished(.endTurn)])
        let from = await resumed.resumedFrom, told = await resumed.regular, replays = await resumed.replays.count
        XCTAssertEqual(from, "fixture-session-\(original.id.uuidString.prefix(8))")
        XCTAssertEqual(told, [next]); XCTAssertEqual(replays, 0)
        _ = await pool.shutdown()
    }

    /// Pool's idleKeep: a run waiting for its next turn keeps its process five minutes, then is shelved
    /// for the rest of the hour, and the next turn still goes on from its session.
    func testAnIdleRunIsShelvedAfterFiveMinutes() async throws {
        let original = ReplayWorker(steps: [.reply([.text("Three items."), .finished(.endTurn)])], keeps: true)
        let resumed = ReplayWorker(steps: [.reply([.text("The second is longest."), .finished(.endTurn)])], keeps: true)
        let factory = ReplayFactory([original, resumed])
        let clock = IdleClock()
        let pool = PoolCoordinator(accounts: [account()], maximumWorkers: 4, roomWait: 0, duplicateWait: 0.1,
                                   now: { clock.now }, factory: { _, _ in try await factory.make() })
        _ = try await collect(pool, first())
        clock.advance(299); await pool.retireIdle()
        let kept = await original.shelves
        XCTAssertEqual(kept, 0)
        clock.advance(2); await pool.retireIdle()
        let shelved = await original.shelves, closes = await original.closes
        XCTAssertEqual(shelved, 1); XCTAssertEqual(closes, 0)
        let sessions = await pool.sessions()
        XCTAssertTrue(sessions.isEmpty)
        var next = first()
        next.messages += [.init(role: "assistant", content: .array([.object(["type": .string("text"), "text": .string("Three items.")])])),
                          .init(role: "user", content: .string("Which is longest?"))]
        _ = try await collect(pool, next)
        let from = await resumed.resumedFrom
        XCTAssertEqual(from, "fixture-session-\(original.id.uuidString.prefix(8))")
        _ = await pool.shutdown()
    }

    /// A conversation whose earlier messages changed does not take the shelved session.
    func testAShelvedSessionIsNotTakenByAnEditedConversation() async throws {
        let original = ReplayWorker(steps: [.reply([.text("Three items."), .finished(.endTurn)])], keeps: true)
        let fresh = ReplayWorker(steps: [.reply([.text("Two items."), .finished(.endTurn)])], keeps: true)
        let factory = ReplayFactory([original, fresh])
        let pool = PoolCoordinator(accounts: [account()], maximumWorkers: 4, idleMost: 0, roomWait: 0, duplicateWait: 0.1,
                                   factory: { _, _ in try await factory.make() })
        _ = try await collect(pool, first())
        try await replayWait { await original.shelves == 1 }
        var next = first()
        next.messages[0].content = .string("Summarise the edited notes.")
        next.messages += [.init(role: "assistant", content: .string("Three items.")), .init(role: "user", content: .string("And now?"))]
        _ = try await collect(pool, next)
        let from = await fresh.resumedFrom
        XCTAssertNil(from)
        _ = await pool.shutdown()
        try await replayWait { await original.discards == 1 }
    }
}

private final class ReplayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_900_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
private actor ReplayFactory {
    private var queue: [ReplayWorker]
    private(set) var count = 0
    init(_ workers: [ReplayWorker]) { queue = workers }
    func make() throws -> any SessionWorker {
        guard !queue.isEmpty else { throw BridgeFailure.unavailable }
        count += 1
        return queue.removeFirst()
    }
}
private actor ReplayWorker: SessionWorker {
    enum Step: Sendable { case reply([BridgeEvent]), failure([BridgeEvent], BridgeFailure), hold([BridgeEvent]) }
    nonisolated let id = UUID()
    private var steps: [Step]
    private var held: AsyncThrowingStream<BridgeEvent, Error>.Continuation?
    private(set) var regular: [BridgeRequest] = []
    private(set) var replays: [BridgeRequest] = []
    private(set) var cancels = 0
    private(set) var closes = 0
    private(set) var shelves = 0
    private(set) var resumedFrom: String?
    private(set) var discards = 0
    private let keeps: Bool
    init(steps: [Step], keeps: Bool = false) { self.steps = steps; self.keeps = keeps }
    func shelve() -> ShelvedSession? {
        guard keeps else { return nil }
        shelves += 1
        return ShelvedSession(session: "fixture-session-\(id.uuidString.prefix(8))", accountID: UUID(uuidString: "0a1b2c3d-2222-4aaa-8bbb-000000000001")!,
                              discard: { [weak self] in Task { await self?.discarded() } })
    }
    private func discarded() { discards += 1 }
    func resume(from saved: ShelvedSession) -> Bool { resumedFrom = saved.session; return keeps }
    func events(for request: BridgeRequest) throws -> AsyncThrowingStream<BridgeEvent, Error> { regular.append(request); return try next() }
    func events(replaying replay: VerifiedToolReplay) throws -> AsyncThrowingStream<BridgeEvent, Error> { replays.append(replay.request); return try next() }
    private func next() throws -> AsyncThrowingStream<BridgeEvent, Error> {
        guard !steps.isEmpty else { throw BridgeFailure.transport }
        let step = steps.removeFirst()
        return AsyncThrowingStream { continuation in
            continuation.yield(.usage(.init(inputTokens: 12, outputTokens: 3)))
            switch step {
            case .reply(let events): events.forEach { continuation.yield($0) }; continuation.finish()
            case .failure(let events, let error): events.forEach { continuation.yield($0) }; continuation.finish(throwing: error)
            case .hold(let events): events.forEach { continuation.yield($0) }; held = continuation
            }
        }
    }
    func release(_ events: [BridgeEvent]) { events.forEach { held?.yield($0) }; held?.finish(); held = nil }
    func observations() -> AsyncStream<WorkerObservation> { AsyncStream { $0.finish() } }
    func sendInput(_ data: Data) {}
    func cancel() { cancels += 1; held?.finish(throwing: BridgeFailure.cancelled); held = nil }
    func close() -> Bool { closes += 1; held?.finish(throwing: BridgeFailure.cancelled); held = nil; return true }
}
private func replayWait(timeout: TimeInterval = 3, _ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
        if Date() > deadline { throw BridgeFailure.transport }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

private final class IdleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}
