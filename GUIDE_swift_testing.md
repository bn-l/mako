# Swift Testing Reference (2025-2026)

Swift Testing is Apple's modern testing framework, introduced at WWDC 2024, included in **Swift 6+ and Xcode 16+**.

## Core Syntax

| XCTest | Swift Testing |
|--------|---------------|
| `class FooTests: XCTestCase` | `@Suite struct FooTests` or `@Suite final class FooTests` |
| `func testSomething()` | `@Test func something()` |
| `XCTAssert*` family (40+ functions) | `#expect()` and `#require()` |
| `setUpWithError()` / `tearDownWithError()` | `init()` / `deinit` |
| `XCTUnwrap(optional)` | `try #require(optional)` |

## Display Names

Human-readable names for tests and suites:

```swift
@Test("Validates email format correctly")
func emailValidation() { ... }

@Suite("Domain Normalizer")
struct DomainNormalizerTests { ... }
```

## Assertions

- **`#expect(condition)`** - Soft assertion, test continues on failure
- **`#require(condition)`** - Hard assertion, throws and aborts test on failure

```swift
@Test func engineWorks() throws {
    let engine = try #require(car.engine)  // unwrap or fail
    #expect(engine.batteryLevel > 0)       // soft check
}
```

## Test Organization

### Suites

Use structs (preferred) or final classes when `deinit` is needed:

```swift
@Suite final class FileSystemTests {
    let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func writeReadRoundtrip() { ... }
}
```

### Tags

Cross-cutting categorization:

```swift
extension Tag {
    @Tag static var e2e: Self
    @Tag static var filesystem: Self
}

@Test(.tags(.e2e, .filesystem))
func migrationWorks() { ... }
```

### Conditional & Control Traits

```swift
// Conditional execution
@Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] != nil))
func onlyOnCI() { ... }

// Disabled with reason
@Test(.disabled("Pending backend fix"))
func brokenEndpoint() { ... }

// Time limits (granularity: 1 minute minimum)
@Test(.timeLimit(.minutes(2)))
func longRunningOperation() async { ... }

// Bug tracking
@Test(.bug("https://github.com/org/repo/issues/123", id: 123, "Crashes on nil input"))
func handlesNilInput() { ... }

@Test(.bug(id: "JIRA-456"))  // ID only
func anotherTest() { ... }
```

### Opt-In Test Suites (Integration/E2E)

Skip expensive tests unless explicitly enabled via environment variable:

```swift
@Suite("Browser Integration", .enabled(if: ProcessInfo.processInfo.environment["INTEGRATION"] != nil))
struct BrowserIntegrationTests {
    @Test func detectsURLFromSafari() async throws { ... }
    @Test func detectsURLFromChrome() async throws { ... }
}
```

```bash
swift test                              # Skips integration tests
INTEGRATION=1 swift test                # Runs all tests
INTEGRATION=1 swift test --filter Browser  # Runs only browser tests
```

## Parameterized Tests

```swift
@Test(arguments: ["foo", "Bar", "baz-qux"])
func handleVariousInputs(input: String) {
    #expect(!input.isEmpty)
}
```

**Paired arguments with `zip`:**

```swift
@Test(arguments: zip(
    ["apple", "AppleWebKit"],
    [.allLowercase, .pascalCase]
))
func detectPattern(input: String, expected: CasePattern) {
    #expect(NameTransformer.detectPattern(input) == expected)
}
```

## Parallelism

Tests run **in parallel by default**. Serialize when needed:

```swift
@Suite(.serialized) struct SequentialTests { ... }
```

## Async Testing

```swift
@Test func asyncOp() async throws {
    let result = try await someAsyncFunction()
    #expect(result.isValid)
}
```

### Confirmation for callbacks

```swift
@Test func callbackFires() async {
    await confirmation("invoked", expectedCount: 1) { confirm in
        sut.onComplete = { confirm() }
        await sut.doWork()
    }
}
```

## Exit Tests (Swift 6.2+)

Test process termination:

```swift
@Test func exitsCleanly() async {
    await #expect(processExitsWith: .exitCode(0)) {
        cleanup()
    }
}
```

**Exit conditions:** `.success`, `.failure`, `.exitCode(N)`, `.signal(SIGABRT)`

## Known Issues

Track expected failures:

```swift
@Test func brokenFeature() {
    withKnownIssue("Pending fix") {
        #expect(feature.works)
    }
}
```

**Intermittent failures** (passes if issue doesn't occur):

```swift
@Test func flakyNetworkCall() async {
    withKnownIssue("Timeout on slow networks", isIntermittent: true) {
        #expect(try await fetchData().count > 0)
    }
}
```

**Match specific errors only:**

```swift
@Test func partiallyBroken() {
    withKnownIssue("Division edge case", when: divisor == 0, matching: { $0 is DivisionError }) {
        #expect(calculator.divide(10, by: divisor) != nil)
    }
}
```

## Custom Traits (Swift 6.1+)

Create reusable setup/teardown logic:

```swift
struct ResetDefaults: TestTrait, TestScoping {
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: () async throws -> Void
    ) async throws {
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
        try await function()
    }
}

extension Trait where Self == ResetDefaults {
    static var resetDefaults: Self { Self() }
}

@Test(.resetDefaults)
func persistenceTest() { ... }
```

**Protocols:** `TestTrait` (for tests), `SuiteTrait` (for suites), `TestScoping` (for before/after hooks)

## Running Tests

```bash
swift test                          # all tests
swift test --filter StateManager    # filter by name
swift test --no-parallel            # sequential
swift test --sanitize=thread        # with TSan
```

## Scope

Swift Testing is for **unit and integration tests only**. For UI automation:
- Use **XCUITest** (`XCTestCase` subclass, not `@Test`)
- Swift Testing and XCUITest can coexist in the same test target

## Resources

- https://developer.apple.com/documentation/testing
- https://github.com/swiftlang/swift-testing
- https://gist.github.com/steipete/84a5952c22e1ff9b6fe274ab079e3a95
