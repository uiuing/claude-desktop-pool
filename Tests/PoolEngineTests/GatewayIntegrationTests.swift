import XCTest
import PoolCore
import PoolGateway
@testable import PoolEngine

final class GatewayIntegrationTests: XCTestCase {
    private let token = String(repeating: "t", count: 48)
    private let call = BridgeToolCall(id: "tool-call-1", name: "read_file", input: .object(["path": .string("note.txt")]))

    func testNativeRequestsWithoutExplicitIDKeepToolResultsOnTheOriginalWorker() async throws {
        let account = makeAccount("Account A", offset: 0)
        let worker = ScriptedWorker(steps: [.reply([.toolUse(call), .finished(.toolUse)]), .reply([.text("Read complete."), .finished(.endTurn)])])
        let factory = WorkerFactory(workers: [account.id: worker])
        let coordinator = makeCoordinator(accounts: [account], factory: factory)
        let initial = try route(firstRequest())
        let first = try await collect(coordinator, route: initial)
        XCTAssertEqual(first, [.toolUse(call), .finished(.toolUse)])

        let continuation = try route(resultRequest())
        XCTAssertNotEqual(initial.id, continuation.id)
        let second = try await collect(coordinator, route: continuation)
        XCTAssertEqual(second, [.text("Read complete."), .finished(.endTurn)])
        let count = await factory.creationCount
        let requests = await worker.requestCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(requests, 2)
    }

    func testPauseDrainsPendingToolResultsAndRefusesANewConversation() async throws {
        let account = makeAccount("Account A", offset: 0)
        let worker = ScriptedWorker(steps: [.reply([.toolUse(call), .finished(.toolUse)]), .reply([.text("Finished."), .finished(.endTurn)])])
        let factory = WorkerFactory(workers: [account.id: worker])
        let coordinator = makeCoordinator(accounts: [account], factory: factory)
        _ = try await collect(coordinator, route: route(firstRequest()))
        await coordinator.setPaused(true)
        let result = try await collect(coordinator, route: route(resultRequest()))
        XCTAssertEqual(result, [.text("Finished."), .finished(.endTurn)])
        do {
            _ = try await collect(coordinator, route: route(firstRequest("Start another task.")))
            XCTFail("A paused pool admitted a new conversation.")
        } catch {
            XCTAssertEqual(error as? BridgeFailure, .paused)
        }
        let count = await factory.creationCount
        XCTAssertEqual(count, 1)
    }

    func testAccountLimitBeforeVisibleOutputCanUseAnotherAccount() async throws {
        let a = makeAccount("Account A", offset: 0), b = makeAccount("Account B", offset: 1)
        let limited = ScriptedWorker(steps: [.failure([], .rateLimited(Date().addingTimeInterval(3600)))])
        let available = ScriptedWorker(steps: [.reply([.text("Available."), .finished(.endTurn)])])
        let factory = WorkerFactory(workers: [a.id: limited, b.id: available])
        let coordinator = makeCoordinator(accounts: [a, b], factory: factory)
        let events = try await collect(coordinator, route: route(firstRequest()))
        XCTAssertEqual(events, [.text("Available."), .finished(.endTurn)])
        let order = await factory.accountOrder
        XCTAssertEqual(order, [a.id, b.id])
    }

    func testPartialAnswerFailureNeverRotatesOrReplays() async throws {
        let a = makeAccount("Account A", offset: 0), b = makeAccount("Account B", offset: 1)
        let source = ScriptedWorker(steps: [.failure([.text("Already visible.")], .rateLimited(nil))])
        let unused = ScriptedWorker(steps: [.reply([.text("Must not appear."), .finished(.endTurn)])])
        let factory = WorkerFactory(workers: [a.id: source, b.id: unused])
        let recorder = RouteRecorder()
        let coordinator = makeCoordinator(accounts: [a, b], factory: factory, recorder: recorder)
        let routed = try route(firstRequest())
        let stream = try await coordinator.events(for: routed.request, conversationID: routed.id)
        var visible: [BridgeEvent] = []
        do {
            for try await event in stream { visible.append(event) }
            XCTFail("A partial answer's failure was hidden.")
        } catch {
            XCTAssertEqual(error as? BridgeFailure, .rateLimited(nil))
        }
        XCTAssertEqual(visible, [.text("Already visible.")])
        let order = await factory.accountOrder
        XCTAssertEqual(order, [a.id])
        // An unconfirmed limit is never saved as a state that stops the account for good.
        XCTAssertNil(recorder.accountStates[a.id])
        XCTAssertEqual(recorder.unconfirmed, [a.id])
    }

    func testRefusalDoesNotTryAnotherIdentity() async throws {
        let a = makeAccount("Account A", offset: 0), b = makeAccount("Account B", offset: 1)
        let source = ScriptedWorker(steps: [.reply([.text("Unable to help with that."), .finished(.refusal)])])
        let unused = ScriptedWorker(steps: [.reply([.text("Must not appear."), .finished(.endTurn)])])
        let factory = WorkerFactory(workers: [a.id: source, b.id: unused])
        let coordinator = makeCoordinator(accounts: [a, b], factory: factory)
        let result = try await collect(coordinator, route: route(firstRequest()))
        XCTAssertEqual(result.last, .finished(.refusal))
        let order = await factory.accountOrder
        XCTAssertEqual(order, [a.id])
    }

    func testDisconnectAfterToolEmissionCancelsWithoutStartingAReplacement() async throws {
        let a = makeAccount("Account A", offset: 0), b = makeAccount("Account B", offset: 1)
        let source = ScriptedWorker(steps: [.hold([.toolUse(call)])])
        let unused = ScriptedWorker(steps: [.reply([.text("Must not appear."), .finished(.endTurn)])])
        let factory = WorkerFactory(workers: [a.id: source, b.id: unused])
        let coordinator = makeCoordinator(accounts: [a, b], factory: factory)
        let routed = try route(firstRequest(), explicitID: "disconnect-test")
        let stream = try await coordinator.events(for: routed.request, conversationID: routed.id)
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, .toolUse(call))
        await coordinator.cancel(conversationID: routed.id)
        do {
            _ = try await iterator.next()
            XCTFail("A disconnected pending tool was not cancelled.")
        } catch {
            XCTAssertEqual(error as? BridgeFailure, .cancelled)
        }
        let order = await factory.accountOrder
        let cancellations = await source.cancellationCount
        XCTAssertEqual(order, [a.id])
        XCTAssertEqual(cancellations, 1)
    }

    func testReportedUsageSurvivesGatewayFramingWithoutInventingQuota() async throws {
        let account = makeAccount("Account A", offset: 0)
        let worker = ScriptedWorker(steps: [.reply([.text("Hello."), .finished(.endTurn)])])
        let factory = WorkerFactory(workers: [account.id: worker])
        let coordinator = makeCoordinator(accounts: [account], factory: factory)
        let events = try await collect(coordinator, route: route(firstRequest()), includeUsage: true)
        var encoder = MessageResponseEncoder(model: "claude-sonnet")
        var streamed = Data()
        for event in events { for chunk in try encoder.encode(event) { streamed.append(chunk) } }
        let body = try JSONDecoder().decode(JSONValue.self, from: encoder.completeBody())
        XCTAssertEqual(body["usage"]?["input_tokens"], .number(24))
        XCTAssertEqual(body["usage"]?["output_tokens"], .number(8))
        XCTAssertTrue(String(decoding: streamed, as: UTF8.self).contains("input_tokens"))
        XCTAssertTrue(account.windows.isEmpty)
    }

    // Gateway framing (PoolGateway worker): a reply without measured usage completes with zero
    // counts instead of failing the turn.
    func testMissingUsageCompletesWithZeroCountsInsteadOfFailing() throws {
        var encoder = MessageResponseEncoder(model: "claude-sonnet")
        XCTAssertFalse(try encoder.encode(.text("Unmeasured answer.")).isEmpty)
        _ = try encoder.encode(.finished(.endTurn))
        let body = try JSONDecoder().decode(JSONValue.self, from: encoder.completeBody())
        XCTAssertEqual(body["usage"]?["input_tokens"], .number(0))
        XCTAssertEqual(body["usage"]?["output_tokens"], .number(0))
        XCTAssertEqual(body["content"]?.arrayValue?.first?["text"], .string("Unmeasured answer."))
    }

    func testNewTurnMovesAnIdleConversationAwayFromConfirmedExhaustion() async throws {
        var a = makeAccount("Account A", offset: 0)
        let b = makeAccount("Account B", offset: 1)
        let source = ScriptedWorker(steps: [.reply([.text("First answer."), .finished(.endTurn)]),
            .reply([.text("Exhausted account must not receive this."), .finished(.endTurn)])])
        let destination = ScriptedWorker(steps: [.reply([.text("Continued on an available account."), .finished(.endTurn)])])
        let factory = WorkerFactory(workers: [a.id: source, b.id: destination])
        let coordinator = makeCoordinator(accounts: [a, b], factory: factory)
        _ = try await collect(coordinator, route: route(firstRequest(), explicitID: "quota-continuity"))
        a.windows = [.init(id: "five_hour", usedPercent: 100, observedAt: Date(), resetsAt: Date().addingTimeInterval(3600))]
        await coordinator.updateAccounts([a, b])
        var next = firstRequest()
        next.messages += [.init(role: "assistant", content: .array([.object(["type": .string("text"), "text": .string("First answer.")])])),
                          .init(role: "user", content: .string("Continue the same task."))]
        let events = try await collect(coordinator, route: route(next, explicitID: "quota-continuity"))
        XCTAssertEqual(events, [.text("Continued on an available account."), .finished(.endTurn)])
        let order = await factory.accountOrder
        XCTAssertEqual(order, [a.id, b.id])
    }

    func testRejectedToolContinuationDoesNotLoseThePendingCall() async throws {
        let account = makeAccount("Account A", offset: 0)
        let worker = ScriptedWorker(steps: [.reply([.toolUse(call), .finished(.toolUse)]),
            .reply([.text("Accepted the corrected result."), .finished(.endTurn)])])
        let factory = WorkerFactory(workers: [account.id: worker])
        let coordinator = makeCoordinator(accounts: [account], factory: factory)
        _ = try await collect(coordinator, route: route(firstRequest()))
        var duplicate = resultRequest()
        let result = duplicate.messages.removeLast()
        duplicate.messages.append(.init(role: "user", content: .array((result.content.arrayValue ?? []) + (result.content.arrayValue ?? []))))
        do {
            _ = try await collect(coordinator, route: route(duplicate))
            XCTFail("A duplicate tool result was accepted.")
        } catch {
            guard case .invalidRequest = error as? BridgeFailure else { return XCTFail("Expected an invalid request.") }
        }
        let accepted = try await collect(coordinator, route: route(resultRequest()))
        XCTAssertEqual(accepted, [.text("Accepted the corrected result."), .finished(.endTurn)])
        let count = await factory.creationCount
        XCTAssertEqual(count, 1)
    }

    func testLowQuotaRotatesOnlyAtNextUserTurnAndRecordsTheReason() async throws {
        var current = makeAccount("Account A", offset: 0)
        var backup = makeAccount("Account B", offset: 1)
        let original = ScriptedWorker(steps: [.reply([.text("First answer."), .finished(.endTurn)])])
        let replacement = ScriptedWorker(steps: [.reply([.text("Continued on the backup."), .finished(.endTurn)])])
        let factory = WorkerFactory(workers: [current.id: original, backup.id: replacement])
        let recorder = RouteRecorder()
        let coordinator = makeCoordinator(accounts: [current], factory: factory, recorder: recorder)
        _ = try await collect(coordinator, route: route(firstRequest(), explicitID: "low-quota"))
        current.windows = [observedWeek(95)]
        backup.windows = [observedWeek(30)]
        await coordinator.updateAccounts([current, backup])
        let before = await factory.creationCount
        XCTAssertEqual(before, 1)
        let events = try await collect(coordinator, route: route(nextRequest(), explicitID: "low-quota"))
        XCTAssertEqual(events, [.text("Continued on the backup."), .finished(.endTurn)])
        XCTAssertTrue(recorder.records.contains { $0.reason == .lowQuota && $0.accountID == current.id })
        let order = await factory.accountOrder
        XCTAssertEqual(order, [current.id, backup.id])
    }

    func testOrderedProactiveRotationSkipsAnEarlierLowBackup() async throws {
        var current = makeAccount("Account A", offset: 0)
        var low = makeAccount("Account B", offset: 1)
        var healthy = makeAccount("Account C", offset: 2)
        low.email = "c•••@gmail.com"; healthy.email = "d•••@gmail.com"
        let original = ScriptedWorker(steps: [.reply([.text("First answer."), .finished(.endTurn)])])
        let wrong = ScriptedWorker(steps: [.reply([.text("The low backup must not be chosen."), .finished(.endTurn)])])
        let replacement = ScriptedWorker(steps: [.reply([.text("Chosen by eligible order."), .finished(.endTurn)])])
        let factory = WorkerFactory(workers: [current.id: original, low.id: wrong, healthy.id: replacement])
        let policy = RoutingPolicy(strategy: .ordered, accountOrder: [low.id, healthy.id, current.id])
        let recorder = RouteRecorder()
        let coordinator = makeCoordinator(accounts: [current], factory: factory, policy: policy, recorder: recorder)
        _ = try await collect(coordinator, route: route(firstRequest(), explicitID: "ordered-quota"))
        current.windows = [observedWeek(95)]; low.windows = [observedWeek(98)]; healthy.windows = [observedWeek(30)]
        await coordinator.updateAccounts([current, low, healthy])
        let events = try await collect(coordinator, route: route(nextRequest(), explicitID: "ordered-quota"))
        XCTAssertEqual(events, [.text("Chosen by eligible order."), .finished(.endTurn)])
        let order = await factory.accountOrder
        XCTAssertEqual(order, [current.id, healthy.id])
        XCTAssertTrue(recorder.records.contains { $0.reason == .accountOrder && $0.accountID == healthy.id })
    }

    func testLowQuotaDoesNotPreemptAPendingTool() async throws {
        var current = makeAccount("Account A", offset: 0)
        var backup = makeAccount("Account B", offset: 1)
        let original = ScriptedWorker(steps: [.reply([.toolUse(call), .finished(.toolUse)]),
            .reply([.text("The original tool finished."), .finished(.endTurn)])])
        let unused = ScriptedWorker(steps: [.reply([.text("Must not appear."), .finished(.endTurn)])])
        let factory = WorkerFactory(workers: [current.id: original, backup.id: unused])
        let recorder = RouteRecorder()
        let coordinator = makeCoordinator(accounts: [current], factory: factory, recorder: recorder)
        _ = try await collect(coordinator, route: route(firstRequest(), explicitID: "pending-quota"))
        current.windows = [observedWeek(95)]; backup.windows = [observedWeek(10)]
        await coordinator.updateAccounts([current, backup])
        let events = try await collect(coordinator, route: route(resultRequest(), explicitID: "pending-quota"))
        XCTAssertEqual(events, [.text("The original tool finished."), .finished(.endTurn)])
        let order = await factory.accountOrder
        XCTAssertEqual(order, [current.id])
        XCTAssertTrue(recorder.records.contains { $0.reason == .toolContinuation && $0.accountID == current.id })
        XCTAssertFalse(recorder.records.contains { $0.reason == .lowQuota })
    }

    func testLowQuotaKeepsSessionWhenNoBackupHasConfirmedReserve() async throws {
        var current = makeAccount("Account A", offset: 0)
        var backup = makeAccount("Account B", offset: 1)
        let original = ScriptedWorker(steps: [.reply([.text("First answer."), .finished(.endTurn)]),
            .reply([.text("Stayed with the current account."), .finished(.endTurn)])])
        let unused = ScriptedWorker(steps: [.reply([.text("Must not appear."), .finished(.endTurn)])])
        let factory = WorkerFactory(workers: [current.id: original, backup.id: unused])
        let recorder = RouteRecorder()
        let coordinator = makeCoordinator(accounts: [current], factory: factory, recorder: recorder)
        _ = try await collect(coordinator, route: route(firstRequest(), explicitID: "no-better-quota"))
        current.windows = [observedWeek(95)]; backup.windows = [observedWeek(98)]
        await coordinator.updateAccounts([current, backup])
        let events = try await collect(coordinator, route: route(nextRequest(), explicitID: "no-better-quota"))
        XCTAssertEqual(events, [.text("Stayed with the current account."), .finished(.endTurn)])
        XCTAssertTrue(recorder.records.contains { $0.reason == .sessionAffinity && $0.accountID == current.id })
        let order = await factory.accountOrder
        XCTAssertEqual(order, [current.id])
    }

    func testPlanChangeDropsOldWorkerQuotaAndUsesANewWorkerForTheNextTurn() async throws {
        var account = makeAccount("Account A", offset: 0)
        account.plan = "Pro"
        let old = ScriptedWorker(steps: [.reply([.text("First answer."), .finished(.endTurn)])], observe: true)
        let replacement = ScriptedWorker(steps: [.reply([.text("Using the new plan."), .finished(.endTurn)])])
        let factory = WorkerFactory(queues: [account.id: [old, replacement]])
        let recorder = RouteRecorder()
        let barrier = expectation(description: "Old worker observation processed")
        let coordinator = PoolCoordinator(accounts: [account], factory: { account, _ in try await factory.make(account.id) },
            onUpdate: { update in
                recorder.record(update)
                if case .terminal(_, let data) = update, data == Data("scope-barrier".utf8) { barrier.fulfill() }
            })
        _ = try await collect(coordinator, route: route(firstRequest(), explicitID: "plan-change"))
        account.plan = "Ultra"; account.windows = []
        await coordinator.updateAccounts([account])
        await old.emit(.quota([.init(id: "five_hour", usedPercent: 95, observedAt: Date(), resetsAt: Date().addingTimeInterval(3600))]))
        await old.emit(.terminal(Data("scope-barrier".utf8)))
        await fulfillment(of: [barrier], timeout: 30)
        XCTAssertTrue(recorder.quotaUpdates.isEmpty)
        let events = try await collect(coordinator, route: route(nextRequest(), explicitID: "plan-change"))
        XCTAssertEqual(events, [.text("Using the new plan."), .finished(.endTurn)])
        let order = await factory.accountOrder
        XCTAssertEqual(order, [account.id, account.id])
        _ = await coordinator.shutdown()
    }

    func testConfirmedAccountFailureCanSelectAnotherAccountBeforeOutput() async throws {
        for state in [AccountState.signedOut, .subscriptionRequired] {
            let a = makeAccount("Account A", offset: 0), b = makeAccount("Account B", offset: 1)
            let source = ScriptedWorker(steps: [.failure([], .accountUnavailable(state))])
            let backup = ScriptedWorker(steps: [.reply([.text("Available account answered."), .finished(.endTurn)])])
            let factory = WorkerFactory(workers: [a.id: source, b.id: backup])
            let recorder = RouteRecorder()
            let coordinator = makeCoordinator(accounts: [a, b], factory: factory, recorder: recorder)
            let result = try await collect(coordinator, route: route(firstRequest()))
            XCTAssertEqual(result, [.text("Available account answered."), .finished(.endTurn)])
            XCTAssertEqual(recorder.accountStates[a.id], state)
            let order = await factory.accountOrder
            XCTAssertEqual(order, [a.id, b.id])
            _ = await coordinator.shutdown()
        }
    }

    func testFactoryAuthenticationFailureDoesNotLaunchOrKeepAnInvalidWorker() async throws {
        let a = makeAccount("Account A", offset: 0), b = makeAccount("Account B", offset: 1)
        let backup = ScriptedWorker(steps: [.reply([.text("Signed-in account answered."), .finished(.endTurn)])])
        let factory = WorkerFactory(workers: [b.id: backup], failures: [a.id: .accountUnavailable(.signedOut)])
        let coordinator = makeCoordinator(accounts: [a, b], factory: factory)
        let result = try await collect(coordinator, route: route(firstRequest()))
        XCTAssertEqual(result, [.text("Signed-in account answered."), .finished(.endTurn)])
        let sessions = await coordinator.sessions()
        XCTAssertEqual(sessions.map(\.accountID), [b.id])
        _ = await coordinator.shutdown()
    }

    func testDelayedFactoryFailureDoesNotDisableTheReplacementPlan() async throws {
        var account = makeAccount("Account A", offset: 0); account.plan = "Pro"
        let waiting = expectation(description: "Old plan worker admission is pending")
        let gate = AsyncStream<Void>.makeStream(), recorder = RouteRecorder()
        let replacement = ScriptedWorker(steps: [.reply([.text("New plan answered."), .finished(.endTurn)])])
        let coordinator = PoolCoordinator(accounts: [account], factory: { snapshot, _ in
            if snapshot.plan == "Pro" {
                waiting.fulfill()
                for await _ in gate.stream { break }
                throw BridgeFailure.accountUnavailable(.signedOut)
            }
            return replacement
        }, onUpdate: { recorder.record($0) })
        let request = try route(firstRequest())
        let pending = Task { try await self.collect(coordinator, route: request) }
        await fulfillment(of: [waiting], timeout: 30)
        account.plan = "Ultra"; account.windows = []
        await coordinator.updateAccounts([account])
        gate.continuation.yield(()); gate.continuation.finish()
        do {
            _ = try await pending.value
            XCTFail("The old scope must not create a worker after the plan changes.")
        } catch { XCTAssertEqual(error as? BridgeFailure, .unavailable) }
        XCTAssertNil(recorder.accountStates[account.id])
        let result = try await collect(coordinator, route: route(firstRequest()))
        XCTAssertEqual(result, [.text("New plan answered."), .finished(.endTurn)])
        _ = await coordinator.shutdown()
    }

    func testProvenModelScopeFailureDoesNotDisableTheWholeAccount() async throws {
        let a = makeAccount("Account A", offset: 0), b = makeAccount("Account B", offset: 1)
        let source = ScriptedWorker(steps: [.failure([], .modelUnavailable)])
        let backup = ScriptedWorker(steps: [.reply([.text("The model is available here."), .finished(.endTurn)])])
        let factory = WorkerFactory(workers: [a.id: source, b.id: backup])
        let recorder = RouteRecorder()
        let coordinator = makeCoordinator(accounts: [a, b], factory: factory, recorder: recorder)
        let result = try await collect(coordinator, route: route(firstRequest()))
        XCTAssertEqual(result, [.text("The model is available here."), .finished(.endTurn)])
        XCTAssertNil(recorder.accountStates[a.id])
        XCTAssertTrue(recorder.records.contains { $0.reason == .modelUnavailable && $0.accountID == a.id })
        _ = await coordinator.shutdown()
    }

    func testUnclassifiedModelErrorDoesNotTriggerIdentityRotation() async throws {
        let a = makeAccount("Account A", offset: 0), b = makeAccount("Account B", offset: 1)
        let error = BridgeFailure.unsupported("The selected model is unavailable.")
        let source = ScriptedWorker(steps: [.failure([], error)])
        let unused = ScriptedWorker(steps: [.reply([.text("Must not appear."), .finished(.endTurn)])])
        let factory = WorkerFactory(workers: [a.id: source, b.id: unused])
        let coordinator = makeCoordinator(accounts: [a, b], factory: factory)
        do {
            _ = try await collect(coordinator, route: route(firstRequest()))
            XCTFail("An unclassified model error was retried on another identity.")
        } catch { XCTAssertEqual(error as? BridgeFailure, .unsupported("The selected model is unavailable.")) }
        let order = await factory.accountOrder
        XCTAssertEqual(order, [a.id])
        _ = await coordinator.shutdown()
    }

    func testModelOnlyQuotaLimitKeepsTheSameAccountAvailableForOtherModels() async throws {
        let a = makeAccount("Account A", offset: 0), b = makeAccount("Account B", offset: 1)
        let limit = QuotaWindow(id: "seven_day_opus", usedPercent: 100, observedAt: Date(),
                                resetsAt: Date().addingTimeInterval(3600))
        let limitedOpus = ScriptedWorker(steps: [.failure([], .quotaLimited([limit]))])
        let sonnet = ScriptedWorker(steps: [.reply([.text("Sonnet still works on this account."), .finished(.endTurn)])])
        let backup = ScriptedWorker(steps: [.reply([.text("Opus continued on the backup."), .finished(.endTurn)])])
        let laterBackup = ScriptedWorker(steps: [.reply([.text("Opus remains on an eligible account."), .finished(.endTurn)])])
        let factory = WorkerFactory(queues: [a.id: [limitedOpus, sonnet], b.id: [backup, laterBackup]])
        let recorder = RouteRecorder()
        let coordinator = makeCoordinator(accounts: [a, b], factory: factory, recorder: recorder)
        var opusRequest = firstRequest(); opusRequest.model = "claude-opus"
        let first = try await collect(coordinator, route: route(opusRequest, explicitID: "opus-limit"))
        XCTAssertEqual(first, [.text("Opus continued on the backup."), .finished(.endTurn)])
        let otherModel = try await collect(coordinator, route: route(firstRequest("Use Sonnet."), explicitID: "sonnet-available"))
        XCTAssertEqual(otherModel, [.text("Sonnet still works on this account."), .finished(.endTurn)])
        let subsequent = try await collect(coordinator, route: route(opusRequest, explicitID: "opus-later"))
        XCTAssertEqual(subsequent, [.text("Opus remains on an eligible account."), .finished(.endTurn)])
        let order = await factory.accountOrder
        XCTAssertEqual(order, [a.id, b.id, a.id, b.id])
        XCTAssertNil(recorder.cooldowns[a.id])
        // stored as a refusal held until the window's reset
        XCTAssertEqual(recorder.quotaUpdates.flatMap { $0 }.first { $0.id == limit.id }?.refusedUntil, limit.resetsAt)
        _ = await coordinator.shutdown()
    }

    /// The Fable limit (`seven_day_overage_included`) used up stops Fable on that account for a week, not the account.
    func testAFableRefusalHoldsOnlyFableOnThatAccountUntilItsReset() async throws {
        let a = makeAccount("Account A", offset: 0), b = makeAccount("Account B", offset: 1)
        let reset = Date().addingTimeInterval(86400)
        let limit = QuotaWindow(id: "seven_day_overage_included", usedPercent: 100, observedAt: Date(), resetsAt: reset)
        let source = ScriptedWorker(steps: [.failure([], .quotaLimited([limit]))])
        let sonnet = ScriptedWorker(steps: [.reply([.text("Sonnet still works on this account."), .finished(.endTurn)])])
        let backup = ScriptedWorker(steps: [.reply([.text("Fable continued on the backup."), .finished(.endTurn)])])
        let laterBackup = ScriptedWorker(steps: [.reply([.text("Fable stays on the backup."), .finished(.endTurn)])])
        let factory = WorkerFactory(queues: [a.id: [source, sonnet], b.id: [backup, laterBackup]])
        let recorder = RouteRecorder()
        let coordinator = makeCoordinator(accounts: [a, b], factory: factory, recorder: recorder)
        var fableRequest = firstRequest(); fableRequest.model = "claude-fable-5"
        let first = try await collect(coordinator, route: route(fableRequest, explicitID: "fable-limit"))
        XCTAssertEqual(first, [.text("Fable continued on the backup."), .finished(.endTurn)])
        XCTAssertNil(recorder.cooldowns[a.id], "A model-scoped refusal sets no account cooldown")
        let held = recorder.quotaUpdates.flatMap { $0 }.first { $0.id == "seven_day_overage_included" }
        XCTAssertEqual(held?.refusedUntil, reset)
        let other = try await collect(coordinator, route: route(firstRequest("Use Sonnet."), explicitID: "sonnet-available"))
        XCTAssertEqual(other, [.text("Sonnet still works on this account."), .finished(.endTurn)])
        let later = try await collect(coordinator, route: route(fableRequest, explicitID: "fable-later"))
        XCTAssertEqual(later, [.text("Fable stays on the backup."), .finished(.endTurn)])
        let order = await factory.accountOrder
        XCTAssertEqual(order, [a.id, b.id, a.id, b.id])
        _ = await coordinator.shutdown()
    }

    /// A limit Pool cannot place (`overage`) that refused a request still holds the account until its
    /// reset and hands the request on, though a mere reading of it never would.
    func testARefusalAtAnUnplacedLimitHoldsTheAccountAndHandsOff() async throws {
        let a = makeAccount("Account A", offset: 0), b = makeAccount("Account B", offset: 1)
        let reset = Date().addingTimeInterval(3600)
        let limit = QuotaWindow(id: "overage", usedPercent: 100, observedAt: Date(), resetsAt: reset)
        XCTAssertEqual(limit.scope, .other)
        let source = ScriptedWorker(steps: [.failure([], .quotaLimited([limit]))])
        let backup = ScriptedWorker(steps: [.reply([.text("Continued on the backup."), .finished(.endTurn)])])
        let laterBackup = ScriptedWorker(steps: [.reply([.text("Still on the backup."), .finished(.endTurn)])])
        let factory = WorkerFactory(queues: [a.id: [source], b.id: [backup, laterBackup]])
        let recorder = RouteRecorder()
        let coordinator = makeCoordinator(accounts: [a, b], factory: factory, recorder: recorder)
        let first = try await collect(coordinator, route: route(firstRequest(), explicitID: "unplaced-limit"))
        XCTAssertEqual(first, [.text("Continued on the backup."), .finished(.endTurn)])
        XCTAssertEqual(recorder.cooldowns[a.id], reset)
        let later = try await collect(coordinator, route: route(firstRequest("Again."), explicitID: "unplaced-later"))
        XCTAssertEqual(later, [.text("Still on the backup."), .finished(.endTurn)])
        let order = await factory.accountOrder
        XCTAssertEqual(order, [a.id, b.id, b.id])
        _ = await coordinator.shutdown()
    }

    func testCombinedQuotaEvidenceUsesOnlyGlobalWindowsForAccountCooldown() async throws {
        let a = makeAccount("Account A", offset: 0), b = makeAccount("Account B", offset: 1)
        let observed = Date(), globalReset = Date().addingTimeInterval(3600), modelReset = Date().addingTimeInterval(7200)
        let global = QuotaWindow(id: "five_hour", usedPercent: 100, observedAt: observed, resetsAt: globalReset)
        let opus = QuotaWindow(id: "seven_day_opus", usedPercent: 100, observedAt: observed, resetsAt: modelReset)
        let source = ScriptedWorker(steps: [.failure([], .quotaLimited([global, opus]))])
        let backup = ScriptedWorker(steps: [.reply([.text("Backup answered."), .finished(.endTurn)])])
        let factory = WorkerFactory(workers: [a.id: source, b.id: backup])
        let recorder = RouteRecorder()
        let coordinator = makeCoordinator(accounts: [a, b], factory: factory, recorder: recorder)
        var request = firstRequest(); request.model = "claude-opus"
        _ = try await collect(coordinator, route: route(request))
        XCTAssertEqual(recorder.cooldowns[a.id], globalReset)
        XCTAssertNotEqual(recorder.cooldowns[a.id], modelReset)
        _ = await coordinator.shutdown()
    }

    func testDelayedOldQuotaCannotReplaceNewerRoutingEvidence() async throws {
        let a = makeAccount("Account A", offset: 0)
        var b = makeAccount("Account B", offset: 1)
        b.windows = [observedWeek(50)]
        let source = ScriptedWorker(steps: [.reply([.text("First answer."), .finished(.endTurn)])], observe: true)
        let wrong = ScriptedWorker(steps: [.reply([.text("Old quota selected the wrong account."), .finished(.endTurn)])])
        let backup = ScriptedWorker(steps: [.reply([.text("Newer quota selected this account."), .finished(.endTurn)])])
        let factory = WorkerFactory(queues: [a.id: [source, wrong], b.id: [backup]])
        let recorder = RouteRecorder()
        let barrier = expectation(description: "Quota observations processed in order")
        let coordinator = PoolCoordinator(accounts: [a], factory: { account, _ in try await factory.make(account.id) },
            onUpdate: { update in
                recorder.record(update)
                if case .terminal(_, let data) = update, data == Data("quota-order-barrier".utf8) { barrier.fulfill() }
            })
        _ = try await collect(coordinator, route: route(firstRequest(), explicitID: "quota-source"))
        await coordinator.updateAccounts([a, b])
        let measuredAt = Date(), reset = Date().addingTimeInterval(3600)
        await source.emit(.quota([.init(id: "seven_day", usedPercent: 85, observedAt: measuredAt, resetsAt: reset)]))
        await source.emit(.quota([.init(id: "seven_day", usedPercent: 15, observedAt: measuredAt.addingTimeInterval(-60), resetsAt: reset)]))
        await source.emit(.terminal(Data("quota-order-barrier".utf8)))
        await fulfillment(of: [barrier], timeout: 30)
        XCTAssertEqual(recorder.quotaUpdates.last?.first?.usedPercent, 85)
        let reply = try await collect(coordinator, route: route(firstRequest("A separate task."), explicitID: "quota-order-selection"))
        XCTAssertEqual(reply, [.text("Newer quota selected this account."), .finished(.endTurn)])
        let order = await factory.accountOrder
        XCTAssertEqual(order, [a.id, b.id])
        _ = await coordinator.shutdown()
    }

    private func makeAccount(_ name: String, offset: TimeInterval) -> PoolAccount {
        .init(email: name == "Account A" ? "a•••@gmail.com" : "b•••@gmail.com", state: .ready,
              createdAt: Date(timeIntervalSince1970: 1_800_000_000 + offset))
    }
    private func makeCoordinator(accounts: [PoolAccount], factory: WorkerFactory, policy: RoutingPolicy = .init(),
                                 recorder: RouteRecorder? = nil) -> PoolCoordinator {
        PoolCoordinator(accounts: accounts, routingPolicy: policy, factory: { account, _ in try await factory.make(account.id) },
                        onUpdate: { recorder?.record($0) })
    }
    private func observedWeek(_ used: Double) -> QuotaWindow {
        .init(id: "seven_day", usedPercent: used, observedAt: Date(), resetsAt: Date().addingTimeInterval(3600))
    }
    private func nextRequest() -> BridgeRequest {
        var next = firstRequest()
        next.messages += [.init(role: "assistant", content: .array([.object(["type": .string("text"), "text": .string("First answer.")])])),
                          .init(role: "user", content: .string("Continue the same task."))]
        return next
    }
    private func firstRequest(_ text: String = "Please inspect note.txt.") -> BridgeRequest {
        .init(model: "claude-sonnet", messages: [.init(role: "user", content: .string(text))], tools: [
            .init(name: "read_file", description: "Read a local file", inputSchema: .object(["type": .string("object")]))
        ])
    }
    private func resultRequest() -> BridgeRequest {
        var request = firstRequest()
        request.messages += [
            .init(role: "assistant", content: .array([.object(["type": .string("tool_use"), "id": .string(call.id),
                "name": .string(call.name), "input": call.input])])),
            .init(role: "user", content: .array([.object(["type": .string("tool_result"), "tool_use_id": .string(call.id),
                "content": .string("A short synthetic note.")])]))
        ]
        return request
    }
    private func route(_ request: BridgeRequest, explicitID: String? = nil) throws -> RoutedRequest {
        let router = try GatewayRouter(port: 18473, token: token)
        var headers = ["host": "127.0.0.1:18473", "authorization": "Bearer \(token)", "content-type": "application/json"]
        if let explicitID { headers["x-claude-pool-session-id"] = explicitID }
        let result = try router.route(.init(method: "POST", path: "/v1/messages", headers: headers, body: JSONEncoder().encode(request)))
        guard case .messages(let decoded, let id, _) = result else { throw BridgeFailure.transport }
        return RoutedRequest(request: decoded, id: id)
    }
    private func collect(_ coordinator: PoolCoordinator, route: RoutedRequest, includeUsage: Bool = false) async throws -> [BridgeEvent] {
        let stream = try await coordinator.events(for: route.request, conversationID: route.id)
        var output: [BridgeEvent] = []
        for try await event in stream {
            if case .usage = event, !includeUsage { continue }
            output.append(event)
        }
        return output
    }
}

private struct RoutedRequest { var request: BridgeRequest; var id: String }

private final class RouteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RouteDecision] = []
    private var quotaStorage: [[QuotaWindow]] = []
    private var stateStorage: [UUID: AccountState] = [:]
    private var cooldownStorage: [UUID: Date] = [:]
    private var unconfirmedStorage: [UUID] = []
    var unconfirmed: [UUID] { lock.lock(); defer { lock.unlock() }; return unconfirmedStorage }
    var records: [RouteDecision] { lock.lock(); defer { lock.unlock() }; return storage }
    var quotaUpdates: [[QuotaWindow]] { lock.lock(); defer { lock.unlock() }; return quotaStorage }
    var accountStates: [UUID: AccountState] { lock.lock(); defer { lock.unlock() }; return stateStorage }
    var cooldowns: [UUID: Date] { lock.lock(); defer { lock.unlock() }; return cooldownStorage }
    func record(_ update: EngineUpdate) {
        lock.lock(); defer { lock.unlock() }
        switch update {
        case .route(let decision): storage.append(decision)
        case .quota(_, let windows): quotaStorage.append(windows)
        case .accountState(let scope, let state, let cooldown):
            stateStorage[scope.accountID] = state; cooldownStorage[scope.accountID] = cooldown
        case .limitUnconfirmed(let scope): unconfirmedStorage.append(scope.accountID)
        default: break
        }
    }
}

private actor WorkerFactory {
    private var queues: [UUID: [ScriptedWorker]]
    private let failures: [UUID: BridgeFailure]
    private(set) var accountOrder: [UUID] = []
    var creationCount: Int { accountOrder.count }
    init(workers: [UUID: ScriptedWorker], failures: [UUID: BridgeFailure] = [:]) {
        queues = workers.mapValues { [$0] }; self.failures = failures
    }
    init(queues: [UUID: [ScriptedWorker]]) { self.queues = queues; failures = [:] }
    func make(_ accountID: UUID) throws -> any SessionWorker {
        accountOrder.append(accountID)
        if let failure = failures[accountID] { throw failure }
        guard var remaining = queues[accountID], !remaining.isEmpty else { throw BridgeFailure.unavailable }
        let worker = remaining.removeFirst(); queues[accountID] = remaining; return worker
    }
}

private actor ScriptedWorker: SessionWorker {
    enum Step: Sendable {
        case reply([BridgeEvent]), failure([BridgeEvent], BridgeFailure), hold([BridgeEvent])
    }
    nonisolated let id = UUID()
    private var steps: [Step]
    private var held: AsyncThrowingStream<BridgeEvent, Error>.Continuation?
    private let observe: Bool
    private var observationSink: AsyncStream<WorkerObservation>.Continuation?
    private(set) var requestCount = 0
    private(set) var cancellationCount = 0
    init(steps: [Step], observe: Bool = false) { self.steps = steps; self.observe = observe }
    func events(for request: BridgeRequest) throws -> AsyncThrowingStream<BridgeEvent, Error> {
        requestCount += 1
        let results = request.messages.last?.content.arrayValue?.compactMap { $0["tool_use_id"]?.stringValue } ?? []
        guard Set(results).count == results.count else { throw BridgeFailure.invalidRequest("Duplicate tool result.") }
        guard !steps.isEmpty else { throw BridgeFailure.transport }
        let step = steps.removeFirst()
        return AsyncThrowingStream { continuation in
            switch step {
            case .reply(let events):
                continuation.yield(.usage(.init(inputTokens: 24, outputTokens: 8)))
                events.forEach { continuation.yield($0) }; continuation.finish()
            case .failure(let events, let error): events.forEach { continuation.yield($0) }; continuation.finish(throwing: error)
            case .hold(let events): events.forEach { continuation.yield($0) }; held = continuation
            }
        }
    }
    func observations() -> AsyncStream<WorkerObservation> {
        AsyncStream { if observe { observationSink = $0 } else { $0.finish() } }
    }
    func emit(_ observation: WorkerObservation) { observationSink?.yield(observation) }
    func sendInput(_ data: Data) {}
    func cancel() {
        cancellationCount += 1
        held?.finish(throwing: BridgeFailure.cancelled); held = nil
    }
    func close() -> Bool {
        held?.finish(throwing: BridgeFailure.cancelled); held = nil; observationSink?.finish(); return true
    }
}
