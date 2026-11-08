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
}

private func handoffWait(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<200 { if await condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
    XCTFail("Timed out waiting.")
}
