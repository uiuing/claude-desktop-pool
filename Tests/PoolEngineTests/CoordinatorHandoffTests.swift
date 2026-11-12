import Foundation
import XCTest
import PoolCore
@testable import PoolEngine

final class CoordinatorHandoffTests: XCTestCase {
    private let call = BridgeToolCall(id: "fixture-read", name: "read_file", input: .object(["path": .string("note.txt")]))
    private var usage: BridgeEvent { .usage(.init(inputTokens: 20, outputTokens: 5)) }
    private var limit: BridgeFailure {
        .quotaLimited([.init(id: "five_hour", usedPercent: 100, observedAt: Date(), resetsAt: Date().addingTimeInterval(3600))])
    }
    private func accounts() -> [PoolAccount] {
        [.init(id: UUID(uuidString: "0a1b2c3d-1111-4aaa-8bbb-000000000001")!, email: "a•••@gmail.com", plan: "Pro", state: .ready, createdAt: Date(timeIntervalSince1970: 1)),
         .init(id: UUID(uuidString: "0a1b2c3d-1111-4aaa-8bbb-000000000002")!, email: "b•••@gmail.com", plan: "Pro", state: .ready, createdAt: Date(timeIntervalSince1970: 2))]
    }
    private func request() -> BridgeRequest {
        .init(model: "claude-sonnet", messages: [.init(role: "user", content: .string("Read the synthetic note."))],
              tools: [.init(name: "read_file", inputSchema: .object(["type": .string("object")]))])
    }
    private func results(calls: [BridgeToolCall]? = nil, returned: [BridgeToolCall]? = nil) -> BridgeRequest {
        let issued = calls ?? [call], returned = returned ?? issued
        var request = request()
        request.messages += [.init(role: "assistant", content: .array(issued.map { .object([
            "type": .string("tool_use"), "id": .string($0.id), "name": .string($0.name), "input": $0.input
        ]) })), .init(role: "user", content: .array(returned.map { .object([
            "type": .string("tool_result"), "tool_use_id": .string($0.id), "content": .string("The synthetic note is complete.")
        ]) }))]
        return request
    }
    private func collect(_ coordinator: PoolCoordinator, _ request: BridgeRequest, id: String = "fixture-session") async throws -> [BridgeEvent] {
        let stream = try await coordinator.events(for: request, conversationID: id)
        var events: [BridgeEvent] = []
        for try await event in stream { if case .usage = event { continue }; events.append(event) }
        return events
    }

    /// Moving a conversation writes its whole context on the new account. One still small on an account
    /// nearly used up moves at its next turn to one with clearly more left; one that has grown stays,
    /// as moving it would write far more, until its account's limit hands it on.
    func testASmallConversationLeavesANearlyUsedUpAccountAndALargeOneStays() async throws {
        let date = Date()
        func quota(_ used: Double) -> [QuotaWindow] { [.init(id: "five_hour", usedPercent: used, observedAt: date, resetsAt: date.addingTimeInterval(3600))] }
        var accounts = accounts()
        accounts[0].windows = quota(20); accounts[1].windows = quota(45)
        let small = HandoffWorker(steps: [.reply([.text("Synthetic reply."), .finished(.endTurn)])], cacheRead: 9_000)
        let large = HandoffWorker(steps: [.reply([.text("Synthetic reply."), .finished(.endTurn)]),
                                          .reply([.text("Synthetic follow-up."), .finished(.endTurn)])], cacheRead: 300_000)
        let moved = HandoffWorker(steps: [.reply([.text("Synthetic follow-up."), .finished(.endTurn)])], cacheRead: 9_000)
        let factory = HandoffFactory(queues: [accounts[0].id: [small, large], accounts[1].id: [moved]])
        let coordinator = PoolCoordinator(accounts: accounts, now: { date }, factory: { account, _ in try await factory.make(account.id) })
        _ = try await collect(coordinator, request(), id: "desktop-small#main")
        _ = try await collect(coordinator, request(), id: "desktop-large#main")
        accounts[0].windows = quota(88); accounts[1].windows = quota(30)
        await coordinator.updateAccounts(accounts)
        var next = request()
        next.messages += [.init(role: "assistant", content: .string("Synthetic reply.")), .init(role: "user", content: .string("Go on."))]
        _ = try await collect(coordinator, next, id: "desktop-small#main")
        _ = try await collect(coordinator, next, id: "desktop-large#main")
        let order = await factory.order
        XCTAssertEqual(order, [accounts[0].id, accounts[0].id, accounts[1].id], "Only the small conversation moved")
        let largeTurns = await large.regularRequests.count
        XCTAssertEqual(largeTurns, 2, "The large conversation went on in its own run")
        XCTAssertNil(PoolRouting.moveWhileSmall(accounts, model: "sonnet", currentID: accounts[0].id, contextTokens: nil))
        XCTAssertNil(PoolRouting.moveWhileSmall(accounts, model: "sonnet", currentID: accounts[0].id, contextTokens: 300_000))
        XCTAssertEqual(PoolRouting.moveWhileSmall(accounts, model: "sonnet", currentID: accounts[0].id, contextTokens: 9_000)?.id, accounts[1].id)
        accounts[1].windows = quota(60)
        XCTAssertNil(PoolRouting.moveWhileSmall(accounts, model: "sonnet", currentID: accounts[0].id, contextTokens: 9_000),
                     "Not for an account with only a little more left")
        _ = await coordinator.shutdown()
    }

    // MARK: What a turn costs, and what a move costs

    /// A real pool (11-12): a conversation of 430,000 tokens written whole on an account took 16 to 28
    /// percent of its five hours, was measured as what its turns cost, and so left each account with
    /// a tenth or more still there, to be written whole on the next: three accounts in ten minutes.
    /// A turn that wrote the conversation whole is not a turn's cost, and the conversation stays.
    func testATurnThatWroteTheConversationWholeIsNotMeasuredAsATurn() async throws {
        let lines = LoggedLines()
        Diagnostics.install { lines.add($0) }
        defer { Diagnostics.install(nil) }
        let date = Date()
        func quota(_ used: Double) -> [QuotaWindow] { [.init(id: "five_hour", usedPercent: used, observedAt: date, resetsAt: date.addingTimeInterval(3600))] }
        var accounts = accounts()
        accounts[0].windows = quota(20); accounts[1].windows = quota(30)
        let worker = HandoffWorker(steps: [.hold([]), .reply([.text("Synthetic follow-up."), .finished(.endTurn)])], cacheRead: 430_000)
        let other = HandoffWorker(steps: [.reply([.text("Synthetic follow-up."), .finished(.endTurn)])], cacheRead: 9_000)
        let factory = HandoffFactory(queues: [accounts[0].id: [worker], accounts[1].id: [other]])
        let coordinator = PoolCoordinator(accounts: accounts, routingPolicy: .init(reservePercent: 0), now: { date },
                                          factory: { account, _ in try await factory.make(account.id) })
        var told = request()
        told.messages += [.init(role: "assistant", content: .string("Synthetic reply.")), .init(role: "user", content: .string("Go on."))]
        let stream = try await coordinator.events(for: told, conversationID: "desktop-long#main")
        let answering = Task { for try await _ in stream {} }
        try await handoffWait { await worker.holding }
        // the reading after the conversation was written whole: a fifth of the account
        accounts[0].windows = quota(42)
        await coordinator.updateAccounts(accounts)
        await worker.release([.text("Synthetic reply."), .finished(.endTurn)], read: 30_000, written: 400_000)
        try await answering.value
        XCTAssertTrue(lines.all.contains { $0.contains("event=coordinator.turn_cost") && $0.contains("skipped=whole") }, lines.all.joined(separator: "\n"))

        // 15% left: by a fifth a turn it would leave now; its turns read the cache, and it stays
        accounts[0].windows = quota(85)
        await coordinator.updateAccounts(accounts)
        var next = told
        next.messages += [.init(role: "assistant", content: .string("Synthetic reply.")), .init(role: "user", content: .string("And then?"))]
        _ = try await collect(coordinator, next, id: "desktop-long#main")
        let order = await factory.order, turns = await worker.regularRequests.count
        XCTAssertEqual(order, [accounts[0].id], "The conversation keeps its account and its cache")
        XCTAssertEqual(turns, 2)
        XCTAssertFalse(lines.all.contains { $0.contains("reason=lowQuota") })
        _ = await coordinator.shutdown()
    }

    /// The account's readings come a while after the work they count: a turn that begins on a
    /// reading taken before a whole write, or just after it, is not measured, as the readings that
    /// follow count that write. Once a reading taken later is the turn's first, its cost is measured.
    func testATurnBegunOnAReadingOlderThanAWholeWriteIsNotMeasured() async throws {
        let lines = LoggedLines()
        Diagnostics.install { lines.add($0) }
        defer { Diagnostics.install(nil) }
        // readings are valid by the real time: the fixture's clock runs a little behind it
        let clock = HandoffClock(Date().addingTimeInterval(-400))
        func quota(_ used: Double, at offset: TimeInterval) -> [QuotaWindow] {
            [.init(id: "five_hour", usedPercent: used, observedAt: clock.start.addingTimeInterval(offset), resetsAt: clock.start.addingTimeInterval(7200))]
        }
        var accounts = [accounts()[0]]
        accounts[0].windows = quota(20, at: 0)
        let worker = HandoffWorker(steps: [.hold([]), .hold([]), .hold([])])
        let factory = HandoffFactory(queues: [accounts[0].id: [worker]])
        let coordinator = PoolCoordinator(accounts: accounts, routingPolicy: .init(reservePercent: 0), now: { clock.now },
                                          factory: { account, _ in try await factory.make(account.id) })
        var conversation = request()
        conversation.messages += [.init(role: "assistant", content: .string("Synthetic reply.")), .init(role: "user", content: .string("Go on."))]
        /// A turn that ends at `ends`, a reading having come during it.
        func turn(written: Int, reading: (Double, TimeInterval), ends: TimeInterval) async throws {
            let stream = try await coordinator.events(for: conversation, conversationID: "desktop-long#main")
            let answering = Task { for try await _ in stream {} }
            try await handoffWait { await worker.holding }
            clock.set(ends)
            accounts[0].windows = quota(reading.0, at: reading.1)
            await coordinator.updateAccounts(accounts)
            await worker.release([.text("Synthetic reply."), .finished(.endTurn)], read: 400_000, written: written)
            try await answering.value
            conversation.messages += [.init(role: "assistant", content: .string("Synthetic reply.")), .init(role: "user", content: .string("Go on."))]
        }
        // told whole at 10 s; no reading shows it yet
        clock.set(10)
        try await turn(written: 500_000, reading: (20, 5), ends: 20)
        // the next turn begins on the reading of 5 s, and the write is counted in a reading during it
        clock.set(30)
        try await turn(written: 900, reading: (40, 35), ends: 40)
        XCTAssertTrue(lines.all.contains { $0.contains("event=coordinator.turn_cost") && $0.contains("skipped=stale") }, lines.all.joined(separator: "\n"))
        XCTAssertFalse(lines.all.contains { $0.contains("event=coordinator.turn_cost") && $0.contains("cost=20.0") }, "The write was not taken for the turn")
        // a turn that begins on a reading taken well after the write is measured: two percent
        accounts[0].windows = quota(40, at: 100)
        await coordinator.updateAccounts(accounts)
        clock.set(110)
        try await turn(written: 900, reading: (42, 120), ends: 125)
        XCTAssertTrue(lines.all.contains { $0.contains("event=coordinator.turn_cost") && $0.contains("cost=2.0") }, lines.all.joined(separator: "\n"))
        _ = await coordinator.shutdown()
    }

    /// The reserve is what a conversation leaves behind when it moves, and a long conversation costs
    /// far more to move than it leaves: with a tenth kept back, one of 80,000 tokens leaves an account
    /// at 8% and one of 400,000 stays, reading its cache, until 2%.
    func testALongConversationStaysBelowTheReserveAndAShortOneLeaves() async throws {
        let date = Date()
        func quota(_ used: Double) -> [QuotaWindow] { [.init(id: "five_hour", usedPercent: used, observedAt: date, resetsAt: date.addingTimeInterval(3600))] }
        var accounts = accounts()
        accounts[0].windows = quota(20); accounts[1].windows = quota(45)
        let reply: [BridgeEvent] = [.text("Synthetic reply."), .finished(.endTurn)]
        let short = HandoffWorker(steps: [.reply(reply)], cacheRead: 80_000)
        let long = HandoffWorker(steps: [.reply(reply), .reply(reply)], cacheRead: 400_000)
        let moved = HandoffWorker(steps: [.reply(reply)], cacheRead: 9_000), later = HandoffWorker(steps: [.reply(reply)], cacheRead: 9_000)
        let factory = HandoffFactory(queues: [accounts[0].id: [short, long], accounts[1].id: [moved, later]])
        let coordinator = PoolCoordinator(accounts: accounts, routingPolicy: .init(reservePercent: 10), now: { date },
                                          factory: { account, _ in try await factory.make(account.id) })
        _ = try await collect(coordinator, request(), id: "desktop-short#main")
        _ = try await collect(coordinator, request(), id: "desktop-long#main")
        accounts[0].windows = quota(92)
        await coordinator.updateAccounts(accounts)
        var next = request()
        next.messages += [.init(role: "assistant", content: .string("Synthetic reply.")), .init(role: "user", content: .string("Go on."))]
        _ = try await collect(coordinator, next, id: "desktop-short#main")
        _ = try await collect(coordinator, next, id: "desktop-long#main")
        var order = await factory.order
        XCTAssertEqual(order, [accounts[0].id, accounts[0].id, accounts[1].id], "Only the short conversation left at 8%")
        accounts[0].windows = quota(98)
        await coordinator.updateAccounts(accounts)
        next.messages += [.init(role: "assistant", content: .string("Synthetic reply.")), .init(role: "user", content: .string("And then?"))]
        _ = try await collect(coordinator, next, id: "desktop-long#main")
        order = await factory.order
        XCTAssertEqual(order.count, 4, "At 2% the long conversation leaves too")
        XCTAssertEqual(order.last, accounts[1].id)
        _ = await coordinator.shutdown()
    }

    /// A side request of a Desktop conversation (a title, asked with
    /// other tools under the same client session) goes to the account its conversation is on, while a new
    /// conversation still goes where routing puts it. One conversation uses one account.
    func testSideRequestGoesToItsConversationsAccount() async throws {
        // Routing reads quota at the real time, so the readings are taken now.
        let date = Date()
        func quota(_ used: Double) -> [QuotaWindow] { [.init(id: "five_hour", usedPercent: used, observedAt: date, resetsAt: date.addingTimeInterval(3600))] }
        var accounts = accounts()
        accounts[0].windows = quota(20); accounts[1].windows = quota(40)
        let reply = { HandoffWorker(steps: [.reply([.text("Synthetic reply."), .finished(.endTurn)])]) }
        let factory = HandoffFactory(queues: [accounts[0].id: [reply(), reply()], accounts[1].id: [reply()]])
        let coordinator = PoolCoordinator(accounts: accounts, now: { date }, factory: { account, _ in try await factory.make(account.id) })
        _ = try await collect(coordinator, request(), id: "desktop-1#main")
        // The other account now has more left: a new conversation goes there, the title of the first does not.
        accounts[0].windows = quota(50); accounts[1].windows = quota(30)
        await coordinator.updateAccounts(accounts)
        let title = BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .string("Title this synthetic conversation."))])
        _ = try await collect(coordinator, title, id: "desktop-1#title")
        _ = try await collect(coordinator, request(), id: "desktop-2#main")
        let order = await factory.order
        XCTAssertEqual(order, [accounts[0].id, accounts[0].id, accounts[1].id])
        // The title's run ends with the client's exit after its reply has streamed: wait for that.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await coordinator.sessions().contains(where: \.isOneOff), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let sessions = await coordinator.sessions()
        let tags = Dictionary(grouping: sessions, by: { $0.conversation ?? "" }).mapValues { Set($0.map(\.accountID)) }
        XCTAssertEqual(tags.count, 2, "Runs are grouped by their Desktop conversation")
        XCTAssertEqual(tags[Diagnostics.tag("desktop-1")], [accounts[0].id])
        XCTAssertEqual(tags[Diagnostics.tag("desktop-2")], [accounts[1].id])
        XCTAssertEqual(PoolCoordinator.conversationTag("privacy:\(UUID().uuidString)@\(Diagnostics.tag("desktop-1"))"), Diagnostics.tag("desktop-1"))
        XCTAssertNil(PoolCoordinator.conversationTag("request:\(UUID().uuidString)"))
        // The title is a one-off ask (no tools, no earlier reply): its run ended once it answered.
        XCTAssertEqual(sessions.count, 2)
        XCTAssertFalse(sessions.contains { $0.isOneOff })
        XCTAssertTrue(PoolCoordinator.isOneOff(title))
        XCTAssertFalse(PoolCoordinator.isOneOff(request()), "A request offering tools is a conversation")
        _ = await coordinator.shutdown()
    }

    /// A conversation running tasks side by side (Claude Code's sub-agents arrive under the
    /// conversation's tag, each a session of its own): a new task goes where the pool has room, not
    /// onto the account its sibling is busy on, so one account never carries the whole batch and runs
    /// out with all of it at once. A title of the conversation still keeps to an account the conversation is on.
    func testParallelTasksOfOneConversationSpreadAndItsTitleStays() async throws {
        let date = Date()
        func quota(_ used: Double) -> [QuotaWindow] { [.init(id: "five_hour", usedPercent: used, observedAt: date, resetsAt: date.addingTimeInterval(3600))] }
        var accounts = accounts()
        accounts[0].windows = quota(30); accounts[1].windows = quota(30)
        let busy = HandoffWorker(steps: [.hold([])])
        let task = HandoffWorker(steps: [.reply([.text("Synthetic task done."), .finished(.endTurn)])])
        let title = { HandoffWorker(steps: [.reply([.text("Synthetic title"), .finished(.endTurn)])]) }
        let factory = HandoffFactory(queues: [accounts[0].id: [busy, title()], accounts[1].id: [task, title()]])
        let routes = PlacementLog()
        let coordinator = PoolCoordinator(accounts: accounts, now: { date }, factory: { account, _ in try await factory.make(account.id) },
                                          onUpdate: { if case .route(let decision) = $0 { routes.add(decision) } })
        let first = Task { try await self.collect(coordinator, self.request(), id: "desktop-1#agent-a") }
        try await handoffWait { await busy.regularRequests.count == 1 }
        let second = try await collect(coordinator, request(), id: "desktop-1#agent-b")
        XCTAssertEqual(second, [.text("Synthetic task done."), .finished(.endTurn)])
        let ask = BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .string("Title this synthetic conversation."))])
        _ = try await collect(coordinator, ask, id: "desktop-1#title")
        let order = await factory.order
        XCTAssertEqual(Array(order.prefix(2)), [accounts[0].id, accounts[1].id], "The second task does not join its busy sibling")
        XCTAssertEqual(order.count, 3, "The title is served on an account the conversation is on")
        // each placement says why it went where it went: the side-by-side task as parallel work,
        // the title as staying on the conversation's account
        let reasons = routes.all.filter { $0.sessionID != nil }.map(\.reason)
        XCTAssertEqual(Array(reasons.prefix(3)), [.headroom, .parallelWork, .sessionAffinity])
        first.cancel()
        _ = await coordinator.shutdown()
    }

    /// Runs started at the same moment see each other: one still being started counts on the account
    /// it is going to, so a burst of new work (sixteen sub-agents in a second, 11-10) does not all pick
    /// the account that looked best before any of them was bound.
    func testRunsBeingStartedCountWhereTheyAreGoing() async throws {
        let date = Date()
        func quota(_ used: Double) -> [QuotaWindow] { [.init(id: "five_hour", usedPercent: used, observedAt: date, resetsAt: date.addingTimeInterval(3600))] }
        var accounts = accounts()
        accounts[0].windows = quota(30); accounts[1].windows = quota(30)
        let gate = HandoffGate()
        let factory = GatedFactory(gate: gate, first: accounts[0].id)
        let coordinator = PoolCoordinator(accounts: accounts, now: { date }, factory: { account, _ in try await factory.make(account.id) })
        let first = Task { try await self.collect(coordinator, self.request(), id: "desktop-1#main") }
        try await handoffWait { await factory.order.count == 1 }
        let second = Task { try await self.collect(coordinator, self.request(), id: "desktop-2#main") }
        try await handoffWait { await factory.order.count == 2 }
        await gate.release()
        _ = try await first.value; _ = try await second.value
        let order = await factory.order
        XCTAssertEqual(order, [accounts[0].id, accounts[1].id], "The second sees the first being started")
        _ = await coordinator.shutdown()
    }

    /// Pool's warmAccounts: an account that served a conversation of the model within the hour holds
    /// Claude Code's own opening in its cache, whatever the client's instructions, and a new conversation
    /// of that model leans toward it by what a first turn was measured to read. Another model's is not
    /// warm there, and an account with clearly more left still comes first.
    func testANewConversationLeansTowardAnAccountWarmWithItsModel() async throws {
        let date = Date()
        func quota(_ used: Double) -> [QuotaWindow] { [.init(id: "five_hour", usedPercent: used, observedAt: date, resetsAt: date.addingTimeInterval(3600))] }
        var accounts = accounts()
        accounts[0].windows = quota(20); accounts[1].windows = quota(40)
        let reply = { HandoffWorker(steps: [.reply([.text("Synthetic reply."), .finished(.endTurn)])]) }
        let measured = HandoffWorker(steps: [.reply([.text("Synthetic reply."), .finished(.endTurn)])], cacheRead: 60_000)
        let factory = HandoffFactory(queues: [accounts[0].id: [measured, reply()], accounts[1].id: [reply(), reply()]])
        let coordinator = PoolCoordinator(accounts: accounts, idleMost: 0, now: { date }, factory: { account, _ in try await factory.make(account.id) })
        _ = try await collect(coordinator, request(), id: "desktop-1#main")
        try await handoffWait { await coordinator.sessions().isEmpty }
        // The other account now has a little more left; the new conversation has instructions of its own.
        accounts[0].windows = quota(30); accounts[1].windows = quota(25)
        await coordinator.updateAccounts(accounts)
        var second = request(); second.system = .string("Other synthetic project instructions.")
        second.messages[0].content = .string("Read the second synthetic note.")
        _ = try await collect(coordinator, second, id: "desktop-2#main")
        try await handoffWait { await coordinator.sessions().isEmpty }
        var opus = request(); opus.model = "claude-opus"; opus.messages[0].content = .string("Read the third synthetic note.")
        _ = try await collect(coordinator, opus, id: "desktop-3#main")
        try await handoffWait { await coordinator.sessions().isEmpty }
        accounts[0].windows = quota(80)
        await coordinator.updateAccounts(accounts)
        var fourth = request(); fourth.messages[0].content = .string("Read the fourth synthetic note.")
        _ = try await collect(coordinator, fourth, id: "desktop-4#main")
        let order = await factory.order
        XCTAssertEqual(order, [accounts[0].id, accounts[0].id, accounts[1].id, accounts[1].id])
        _ = await coordinator.shutdown()
    }

    /// The accounts warm with a model, and what a new conversation of it read first, outlive a restart of the app.
    func testAWarmAccountOutlivesARestartOfTheApp() async throws {
        let date = Date()
        func quota(_ used: Double) -> [QuotaWindow] { [.init(id: "five_hour", usedPercent: used, observedAt: date, resetsAt: date.addingTimeInterval(3600))] }
        var accounts = accounts()
        accounts[0].windows = quota(20); accounts[1].windows = quota(40)
        let reply = { HandoffWorker(steps: [.reply([.text("Synthetic reply."), .finished(.endTurn)])]) }
        let measured = HandoffWorker(steps: [.reply([.text("Synthetic reply."), .finished(.endTurn)])], cacheRead: 60_000)
        let before0 = HandoffFactory(queues: [accounts[0].id: [measured], accounts[1].id: []])
        let before = PoolCoordinator(accounts: accounts, idleMost: 0, now: { date }, factory: { account, _ in try await before0.make(account.id) })
        _ = try await collect(before, request(), id: "desktop-1#main")
        try await handoffWait { await before.sessions().isEmpty }
        _ = await before.shutdown()
        let remembered = await before.rememberedAccounts()
        let saved = try XCTUnwrap(remembered)

        accounts[0].windows = quota(30); accounts[1].windows = quota(25)
        let after0 = HandoffFactory(queues: [accounts[0].id: [reply()], accounts[1].id: [reply()]])
        let after = PoolCoordinator(accounts: accounts, idleMost: 0, now: { date }, factory: { account, _ in try await after0.make(account.id) })
        await after.restoreRememberedAccounts(saved)
        var second = request(); second.messages[0].content = .string("Read the second synthetic note.")
        _ = try await collect(after, second, id: "desktop-2#main")
        let order = await after0.order
        XCTAssertEqual(order, [accounts[0].id])
        _ = await after.shutdown()
    }

    /// Pool's recentAccounts: a conversation whose run has ended goes back to the account it was on,
    /// whose cache holds it, while a new conversation goes where routing puts it.
    func testAConversationWhoseRunEndedGoesBackToItsAccount() async throws {
        let date = Date()
        func quota(_ used: Double) -> [QuotaWindow] { [.init(id: "five_hour", usedPercent: used, observedAt: date, resetsAt: date.addingTimeInterval(3600))] }
        var accounts = accounts()
        accounts[0].windows = quota(20); accounts[1].windows = quota(40)
        let reply = { HandoffWorker(steps: [.reply([.text("Synthetic reply."), .finished(.endTurn)])]) }
        let factory = HandoffFactory(queues: [accounts[0].id: [reply(), reply()], accounts[1].id: [reply()]])
        // idleMost 0: each run ends just after its reply, and its worker keeps no session to shelve
        let coordinator = PoolCoordinator(accounts: accounts, idleMost: 0, now: { date }, factory: { account, _ in try await factory.make(account.id) })
        _ = try await collect(coordinator, request(), id: "desktop-1#main")
        try await handoffWait { await coordinator.sessions().isEmpty }
        accounts[0].windows = quota(50); accounts[1].windows = quota(30)
        await coordinator.updateAccounts(accounts)
        var edited = request(); edited.messages[0].content = .string("Read the edited synthetic note.")
        _ = try await collect(coordinator, edited, id: "desktop-1#main")
        _ = try await collect(coordinator, request(), id: "desktop-2#main")
        let order = await factory.order
        XCTAssertEqual(order, [accounts[0].id, accounts[0].id, accounts[1].id])
        _ = await coordinator.shutdown()
    }

    func testAllCompletedResultsCanHandoffOnProvenFailureWithoutReplayingTools() async throws {
        let failures: [BridgeFailure] = [limit, .accountUnavailable(.signedOut), .modelUnavailable,
                                        .rateLimited(Date().addingTimeInterval(3600))]
        for failure in failures {
            let accounts = accounts()
            let first = HandoffWorker(steps: [.reply([.toolUse(call), .finished(.toolUse)]), .failure([], failure)])
            let backup = HandoffWorker(steps: [.reply([.text("Continued from the completed result."), .finished(.endTurn)])])
            let againA = HandoffWorker(steps: [.reply([.text("Told the whole conversation."), .finished(.endTurn)])])
            let againB = HandoffWorker(steps: [.reply([.text("Told the whole conversation."), .finished(.endTurn)])])
            let factory = HandoffFactory(queues: [accounts[0].id: [first, againA], accounts[1].id: [backup, againB]])
            let coordinator = PoolCoordinator(accounts: accounts, factory: { account, _ in try await factory.make(account.id) })
            _ = try await collect(coordinator, request())
            let next = results()
            let answer = try await collect(coordinator, next)
            XCTAssertEqual(answer, [.text("Continued from the completed result."), .finished(.endTurn)])
            let replayed = await backup.replays, regular = await backup.regularRequests, oldRequests = await first.regularRequests
            XCTAssertEqual(replayed, [next], "A replacement receives completed history through the internal verified method.")
            XCTAssertTrue(regular.isEmpty, "A fresh public tool_result must not be accepted by ordinary worker admission.")
            XCTAssertEqual(oldRequests.count, 2)
            let order = await factory.order, closes = await first.closeCount
            XCTAssertEqual(order, accounts.map(\.id)); XCTAssertEqual(closes, 1)
            // The same results sent again were answered already: the request is a
            // conversation of its own, told it whole in a new run. Nothing is refused and no tool runs again.
            let resent = try await collect(coordinator, next)
            XCTAssertEqual(resent, [.text("Told the whole conversation."), .finished(.endTurn)])
            let replayCount = await backup.replays.count
            let againReplays = await againA.replays + againB.replays
            let againRegular = await againA.regularRequests + againB.regularRequests
            XCTAssertEqual(replayCount, 1)
            XCTAssertEqual(againReplays, [next]); XCTAssertTrue(againRegular.isEmpty)
            _ = await coordinator.shutdown()
        }
    }

    /// A conversation that cannot be typed into Claude Code fails the same way on every new run.
    /// The client asks again after a 502, so the second such failure in a row is a 400 the person
    /// sees, not one more replay of the whole conversation; a turn that goes through starts over.
    func testATypingFailureTwiceInARowIsShownInsteadOfAskedAgain() async throws {
        let accounts = accounts()
        func failing() -> HandoffWorker { HandoffWorker(steps: [.failure([], .compatibility)]) }
        let factory = HandoffFactory(queues: [
            accounts[0].id: [failing(), failing(), HandoffWorker(steps: [.reply([.text("Typed."), .finished(.endTurn)])]), failing()],
            accounts[1].id: [failing(), failing(), HandoffWorker(steps: [.reply([.text("Typed."), .finished(.endTurn)])]), failing()]
        ])
        let coordinator = PoolCoordinator(accounts: accounts, factory: { account, _ in try await factory.make(account.id) })
        do { _ = try await collect(coordinator, request()); XCTFail("The first typing failure was answered.") }
        catch { XCTAssertEqual(error as? BridgeFailure, .compatibility) }
        do { _ = try await collect(coordinator, request()); XCTFail("The second typing failure was answered.") }
        catch { guard case BridgeFailure.unsupported = error else { return XCTFail("Expected a failure the client shows, got \(error).") } }
        let typed = try await collect(coordinator, request())
        XCTAssertEqual(typed.first, .text("Typed."))
        do { _ = try await collect(coordinator, request()); XCTFail("A later typing failure was answered.") }
        catch { XCTAssertEqual(error as? BridgeFailure, .compatibility) }
        _ = await coordinator.shutdown()
    }

    /// Claude refused one run at the 5-hour limit, as Claude Code writes it (`usage_limit_reached`, 429,
    /// `rateLimitType: five_hour`): the account's other run still waiting on its reply hears of it and
    /// ends that reply, instead of waiting on an account that will not answer before its reset. The
    /// account is told on as limited, never as the ready it was a moment before.
    func testALimitOnOneRunReachesTheAccountsOtherWaitingRuns() async throws {
        var accounts = accounts(); accounts[1].state = .disabled
        let waiting = HandoffWorker(steps: [.hold([])])
        let refused = HandoffWorker(steps: [.failure([], limit)])
        let factory = HandoffFactory(queues: [accounts[0].id: [waiting, refused]])
        let updates = HandoffUpdates()
        let coordinator = PoolCoordinator(accounts: accounts, factory: { account, _ in try await factory.make(account.id) },
                                          onUpdate: { updates.record($0) })
        let other = Task { try await self.collect(coordinator, self.request(), id: "fixture-waiting") }
        try await handoffWait { await waiting.regularRequests.count == 1 }
        // with no other account to move to, each ends at the limit: the account's own, or the pool's
        // with when its first account is back, never as a moment's "no account"
        func movedOnOrLimited(_ error: Error) -> Bool {
            if case BridgeFailure.quotaLimited = error { return true }
            if case BridgeFailure.poolLimited(let back?) = error { return back > Date() }
            return false
        }
        do { _ = try await collect(coordinator, request(), id: "fixture-refused"); XCTFail("Expected the limit.") }
        catch { XCTAssertTrue(movedOnOrLimited(error), "\(error)") }
        do { _ = try await other.value; XCTFail("The waiting run's reply should end.") }
        catch { XCTAssertTrue(movedOnOrLimited(error), "\(error)") }
        let told = await waiting.limitedCalls
        XCTAssertEqual(told.count, 1)
        XCTAssertFalse(updates.accountStates.isEmpty)
        XCTAssertTrue(updates.accountStates.allSatisfy { $0 == .limited }, "\(updates.accountStates)")
        _ = await coordinator.shutdown()
    }

    func testFailureBeforeResultAcceptanceDoesNotHandoff() async throws {
        let accounts = accounts()
        let first = HandoffWorker(steps: [.reply([.toolUse(call), .finished(.toolUse)]), .reject(limit)])
        let backup = HandoffWorker(steps: [])
        let factory = HandoffFactory(queues: [accounts[0].id: [first], accounts[1].id: [backup]])
        let coordinator = PoolCoordinator(accounts: accounts, factory: { account, _ in try await factory.make(account.id) })
        _ = try await collect(coordinator, request())
        do { _ = try await collect(coordinator, results()); XCTFail("A rejected result admission was replayed.") }
        catch { guard case BridgeFailure.quotaLimited = error else { return XCTFail("Expected quota failure.") } }
        let order = await factory.order
        XCTAssertEqual(order, [accounts[0].id])
        _ = await coordinator.requestSessionExit(first.id)
    }

    func testOutstandingParallelCallPreventsHandoffAfterPartialResults() async throws {
        let accounts = accounts(), secondCall = BridgeToolCall(id: "fixture-second", name: "read_file", input: .object(["path": .string("second.txt")]))
        let first = HandoffWorker(steps: [.reply([.toolUse(call), .toolUse(secondCall), .finished(.toolUse)]), .failure([], limit)])
        let factory = HandoffFactory(queues: [accounts[0].id: [first]])
        let coordinator = PoolCoordinator(accounts: accounts, factory: { account, _ in try await factory.make(account.id) })
        _ = try await collect(coordinator, request())
        do { _ = try await collect(coordinator, results(calls: [call, secondCall], returned: [call])); XCTFail("A pending parallel tool was abandoned.") }
        catch { guard case BridgeFailure.quotaLimited = error else { return XCTFail("Expected quota failure.") } }
        let order = await factory.order
        XCTAssertEqual(order, [accounts[0].id])
        _ = await coordinator.requestSessionExit(first.id)
    }

    func testValidatedToolContinuationCanChangeCatalogAndARewrittenConversationGoesOnInARunOfItsOwn() async throws {
        let account = accounts()[0]
        let worker = HandoffWorker(steps: [.reply([.toolUse(call), .finished(.toolUse)]), .reply([.text("Catalog updated."), .finished(.endTurn)])])
        let forSystem = HandoffWorker(steps: [.reply([.text("Told with the new system."), .finished(.endTurn)])])
        let forHistory = HandoffWorker(steps: [.reply([.text("Told the rewritten conversation."), .finished(.endTurn)])])
        let factory = HandoffFactory(queues: [account.id: [worker, forSystem, forHistory]])
        let coordinator = PoolCoordinator(accounts: [account], factory: { account, _ in try await factory.make(account.id) })
        _ = try await collect(coordinator, request())
        var changed = results()
        changed.tools = [.init(name: "write_file", description: "Newly available client tool", inputSchema: .object(["type": .string("object")]))]
        var wrongSystem = changed; wrongSystem.system = .string("A different system.")
        var wrongHistory = changed; wrongHistory.messages[0].content = .string("A different conversation.")
        var duplicate = changed
        duplicate.messages[2].content = .array((duplicate.messages[2].content.arrayValue ?? []) + (duplicate.messages[2].content.arrayValue ?? []))
        do { _ = try await collect(coordinator, duplicate); XCTFail("A result supplied twice was accepted.") }
        catch { guard case BridgeFailure.invalidRequest = error else { return XCTFail("Expected a malformed-request rejection.") } }
        // Another session's rewrite of the conversation answers the same calls: its results go on in a run of
        // their own, told the conversation as the request has it. The run that made the calls
        // goes on waiting for its own client's results.
        let systemAnswer = try await collect(coordinator, wrongSystem, id: "fixture-other-system")
        XCTAssertEqual(systemAnswer, [.text("Told with the new system."), .finished(.endTurn)])
        let historyAnswer = try await collect(coordinator, wrongHistory, id: "fixture-other-history")
        XCTAssertEqual(historyAnswer, [.text("Told the rewritten conversation."), .finished(.endTurn)])
        let systemReplays = await forSystem.replays, historyReplays = await forHistory.replays
        XCTAssertEqual(systemReplays, [wrongSystem]); XCTAssertEqual(historyReplays, [wrongHistory])
        let answer = try await collect(coordinator, changed)
        XCTAssertEqual(answer, [.text("Catalog updated."), .finished(.endTurn)])
        let accepted = await worker.regularRequests
        XCTAssertEqual(accepted.count, 2); XCTAssertEqual(accepted.last?.tools, changed.tools)
        _ = await coordinator.shutdown()
    }

    func testOrdinaryTurnCatalogChangeStillRequiresFreshWorker() async throws {
        let account = accounts()[0]
        let first = HandoffWorker(steps: [.reply([.text("First answer."), .finished(.endTurn)])])
        let second = HandoffWorker(steps: [.reply([.text("New catalog."), .finished(.endTurn)])])
        let factory = HandoffFactory(queues: [account.id: [first, second]])
        let coordinator = PoolCoordinator(accounts: [account], factory: { account, _ in try await factory.make(account.id) })
        _ = try await collect(coordinator, request())
        var next = request()
        next.messages += [.init(role: "assistant", content: .array([.object(["type": .string("text"), "text": .string("First answer.")])])),
                          .init(role: "user", content: .string("Use another client tool."))]
        next.tools = [.init(name: "write_file", inputSchema: .object(["type": .string("object")]))]
        _ = try await collect(coordinator, next)
        let order = await factory.order
        XCTAssertEqual(order, [account.id, account.id])
        _ = await coordinator.shutdown()
    }

    /// Thinking shown before the account's limit is not the answer: the reply still moves to another
    /// account, which answers in full, and both are told in the order they came.
    func testALimitAfterThinkingBeforeAnyWordsStillMovesToAnotherAccount() async throws {
        let accounts = accounts()
        let first = HandoffWorker(steps: [.failure([.thinking("Weighing the note"), .thinkingSignature("c2lnLXN5bnRoZXRpYw==")], limit)])
        let backup = HandoffWorker(steps: [.reply([.thinking("Reading it"), .text("The note is complete."), .finished(.endTurn)])])
        let factory = HandoffFactory(queues: [accounts[0].id: [first], accounts[1].id: [backup]])
        let coordinator = PoolCoordinator(accounts: accounts, factory: { account, _ in try await factory.make(account.id) })
        let answer = try await collect(coordinator, request())
        XCTAssertEqual(answer, [.thinking("Weighing the note"), .thinkingSignature("c2lnLXN5bnRoZXRpYw=="), .thinking("Reading it"),
                                .text("The note is complete."), .finished(.endTurn)])
        let order = await factory.order, closes = await first.closeCount
        XCTAssertEqual(order, accounts.map(\.id)); XCTAssertEqual(closes, 1)
        _ = await coordinator.shutdown()
    }

    func testNewOutputTransportAndPolicyRefusalNeverHandoffAfterResults() async throws {
        let newCall = BridgeToolCall(id: "fixture-new-call", name: "read_file", input: .object([:]))
        let failures: [(HandoffWorker.Step, [BridgeEvent])] = [
            (.failure([.text("New visible answer.")], limit), [.text("New visible answer.")]),
            (.failure([.toolUse(newCall)], limit), [.toolUse(newCall)]),
            (.failure([], .transport), []),
            (.failure([], .unsupported("The request was refused.")), [])
        ]
        for (step, expected) in failures {
            let accounts = accounts(), first = HandoffWorker(steps: [.reply([.toolUse(call), .finished(.toolUse)]), step])
            let factory = HandoffFactory(queues: [accounts[0].id: [first]])
            let coordinator = PoolCoordinator(accounts: accounts, factory: { account, _ in try await factory.make(account.id) })
            _ = try await collect(coordinator, request())
            let stream = try await coordinator.events(for: results(), conversationID: "fixture-session")
            var seen: [BridgeEvent] = []
            do { for try await event in stream { if case .usage = event { continue }; seen.append(event) }; XCTFail("Failure was hidden.") }
            catch {}
            XCTAssertEqual(seen, expected)
            let order = await factory.order
            XCTAssertEqual(order, [accounts[0].id])
            _ = await coordinator.requestSessionExit(first.id)
        }
    }

    func testCancelWinsOverAQuotaErrorAfterCompletedResults() async throws {
        let accounts = accounts()
        let first = HandoffWorker(steps: [.reply([.toolUse(call), .finished(.toolUse)]), .hold([usage])], cancelError: limit)
        let factory = HandoffFactory(queues: [accounts[0].id: [first]])
        let coordinator = PoolCoordinator(accounts: accounts, factory: { account, _ in try await factory.make(account.id) })
        _ = try await collect(coordinator, request())
        let stream = try await coordinator.events(for: results(), conversationID: "fixture-session")
        var iterator = stream.makeAsyncIterator()
        let accepted = try await iterator.next(); XCTAssertEqual(accepted, usage)
        await coordinator.cancel(conversationID: "fixture-session")
        do { _ = try await iterator.next(); XCTFail("A cancelled result continuation was retried.") }
        catch { XCTAssertEqual(error as? BridgeFailure, .cancelled) }
        let order = await factory.order
        XCTAssertEqual(order, [accounts[0].id])
        _ = await coordinator.requestSessionExit(first.id)
    }

    func testCancelDuringReplacementCreationPreventsReplay() async throws {
        let accounts = accounts(), waiting = expectation(description: "Replacement creation began")
        let first = HandoffWorker(steps: [.reply([.toolUse(call), .finished(.toolUse)]), .failure([], limit)])
        let replacement = HandoffWorker(steps: [.reply([.text("Must never run."), .finished(.endTurn)])]), gate = HandoffGate()
        let firstID = accounts[0].id
        let coordinator = PoolCoordinator(accounts: accounts, factory: { account, _ in
            if account.id == firstID { return first }
            waiting.fulfill(); await gate.wait(); return replacement
        })
        _ = try await collect(coordinator, request())
        let task = Task { try await self.collect(coordinator, self.results()) }
        await fulfillment(of: [waiting], timeout: 30)
        await coordinator.cancel(conversationID: "fixture-session")
        await gate.release()
        do { _ = try await task.value; XCTFail("A cancelled request reached its replacement.") }
        catch { XCTAssertEqual(error as? BridgeFailure, .cancelled) }
        let replays = await replacement.replays, closes = await replacement.closeCount
        XCTAssertTrue(replays.isEmpty); XCTAssertEqual(closes, 1)
        _ = await coordinator.shutdown()
    }

    func testResultsNoRunWaitsForAreToldAsHistoryToANewRun() async throws {
        let account = accounts()[0], worker = HandoffWorker(steps: [.reply([.text("Continued."), .finished(.endTurn)])])
        let factory = HandoffFactory(queues: [account.id: [worker]])
        let coordinator = PoolCoordinator(accounts: [account], factory: { account, _ in try await factory.make(account.id) })
        // No run made these calls (the app restarted, the run was let go): the conversation is told whole,
        // its completed calls and results as history, never as a call to make again.
        let answer = try await collect(coordinator, results())
        XCTAssertEqual(answer, [.text("Continued."), .finished(.endTurn)])
        let replays = await worker.replays, regular = await worker.regularRequests
        XCTAssertEqual(replays, [results()]); XCTAssertTrue(regular.isEmpty)
        _ = await coordinator.shutdown()
    }
}

private actor HandoffFactory {
    private var queues: [UUID: [HandoffWorker]]
    private(set) var order: [UUID] = []
    init(queues: [UUID: [HandoffWorker]]) { self.queues = queues }
    func make(_ id: UUID) throws -> any SessionWorker {
        order.append(id)
        guard var queue = queues[id], !queue.isEmpty else { throw BridgeFailure.unavailable }
        let first = queue.removeFirst(); queues[id] = queue; return first
    }
}
private actor GatedFactory {
    private let gate: HandoffGate
    private let first: UUID
    private(set) var order: [UUID] = []
    init(gate: HandoffGate, first: UUID) { self.gate = gate; self.first = first }
    func make(_ id: UUID) async throws -> any SessionWorker {
        order.append(id)
        if order.count == 1 { await gate.wait() }
        return HandoffWorker(steps: [.reply([.text("Synthetic reply."), .finished(.endTurn)])])
    }
}
private actor HandoffGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private actor HandoffWorker: SessionWorker {
    enum Step: Sendable { case reply([BridgeEvent]), failure([BridgeEvent], BridgeFailure), hold([BridgeEvent]), reject(BridgeFailure) }
    nonisolated let id = UUID()
    private var steps: [Step]
    private let cancelError: BridgeFailure
    private var held: AsyncThrowingStream<BridgeEvent, Error>.Continuation?
    private(set) var regularRequests: [BridgeRequest] = []
    private(set) var replays: [BridgeRequest] = []
    private(set) var closeCount = 0
    private let cacheRead: Int?
    init(steps: [Step], cancelError: BridgeFailure = .cancelled, cacheRead: Int? = nil) {
        self.steps = steps; self.cancelError = cancelError; self.cacheRead = cacheRead
    }
    /// Ends a held reply with its usage and `events`.
    func release(_ events: [BridgeEvent], read: Int, written: Int) {
        held?.yield(.usage(.init(inputTokens: 20, outputTokens: 5, cacheReadInputTokens: read, cacheCreationInputTokens: written)))
        events.forEach { held?.yield($0) }; held?.finish(); held = nil
    }
    var holding: Bool { held != nil }
    func events(for request: BridgeRequest) throws -> AsyncThrowingStream<BridgeEvent, Error> {
        regularRequests.append(request); return try next()
    }
    func events(replaying replay: VerifiedToolReplay) throws -> AsyncThrowingStream<BridgeEvent, Error> {
        replays.append(replay.request); return try next()
    }
    private func next() throws -> AsyncThrowingStream<BridgeEvent, Error> {
        guard !steps.isEmpty else { throw BridgeFailure.transport }
        let step = steps.removeFirst()
        if case .reject(let error) = step { throw error }
        return AsyncThrowingStream { continuation in
            switch step {
            case .reply(let events):
                continuation.yield(.usage(.init(inputTokens: 20, outputTokens: 5, cacheReadInputTokens: cacheRead)))
                events.forEach { continuation.yield($0) }; continuation.finish()
            case .failure(let events, let failure): events.forEach { continuation.yield($0) }; continuation.finish(throwing: failure)
            case .hold(let events): events.forEach { continuation.yield($0) }; held = continuation
            case .reject: break
            }
        }
    }
    func observations() -> AsyncStream<WorkerObservation> { AsyncStream { $0.finish() } }
    func sendInput(_ data: Data) {}
    func cancel() { held?.finish(throwing: cancelError); held = nil }
    func close() -> Bool { closeCount += 1; held?.finish(throwing: .cancelled as BridgeFailure); held = nil; return true }
    private(set) var limitedCalls: [BridgeFailure] = []
    func accountLimited(_ failure: BridgeFailure, until: Date) {
        limitedCalls.append(failure); held?.finish(throwing: failure); held = nil
    }
}
private final class HandoffClock: @unchecked Sendable {
    let start: Date
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    init(_ start: Date) { self.start = start }
    var now: Date { lock.withLock { start.addingTimeInterval(offset) } }
    func set(_ seconds: TimeInterval) { lock.withLock { offset = seconds } }
}
private final class HandoffUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [AccountState] = []
    func record(_ update: EngineUpdate) {
        if case .accountState(_, let state, _) = update { lock.withLock { states.append(state) } }
    }
    var accountStates: [AccountState] { lock.withLock { states } }
}

private func handoffWait(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<200 { if await condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
    XCTFail("Timed out waiting.")
}

private final class PlacementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var decisions: [RouteDecision] = []
    func add(_ decision: RouteDecision) { lock.lock(); decisions.append(decision); lock.unlock() }
    var all: [RouteDecision] { lock.lock(); defer { lock.unlock() }; return decisions }
}
