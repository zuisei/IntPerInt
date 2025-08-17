import XCTest
@testable import IntPerInt

final class PersistenceAndStreamingTests: XCTestCase {
    func testConversationPersistence() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("conv_test_\(UUID().uuidString).json")
        let store = ConversationStore(fileURL: tmp)

        let convs = [Conversation(title: "Hello", messages: [ChatMessage(content: "Hi", isUser: true)], updatedAt: Date(), modelName: "test.gguf")]
        await store.save(convs)

        let loaded = await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "Hello")
        XCTAssertEqual(loaded.first?.messages.first?.content, "Hi")
    }

    func testMockEngineStreamingCancel() async throws {
        actor Collector { var text = ""; func add(_ s: String) { text += s }; func count() -> Int { text.count } }
        actor Once { var done = false; func trySet() -> Bool { if done { return false }; done = true; return true } }
        let collector = Collector()
        let once = Once()

    var engine: LLMEngine = LlamaCppEngine()
    try engine.load(modelPath: URL(fileURLWithPath: "/tmp/mock.gguf"))

        let exp = expectation(description: "streaming")
        let start = Date()

        let task = Task {
            _ = try await engine.generate(prompt: "a b c d e f", systemPrompt: nil, params: GenerationParams(), onToken: { token in
                Task {
                    await collector.add(token)
                    let c = await collector.count()
                    if c > 4 {
                        if await once.trySet() { exp.fulfill() }
                    }
                }
            }, isCancelled: { Task.isCancelled })
        }

    await fulfillment(of: [exp], timeout: 2.0)
    task.cancel()
    // Ensure the task is awaited to completion to satisfy XCTest's structured concurrency rules
    _ = try? await task.value
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0)
    }
}
