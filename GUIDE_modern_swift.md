# Modern Swift Guide: Migrating from 5.4-era to 6.2

This guide covers the evolution of Swift from pre-concurrency patterns (5.4 and earlier) through Swift 6.2 (September 2025). Use it as a reference when modernizing any Swift codebase.

---

## Table of Contents

1. [Swift 5.5: The Concurrency Revolution](#1-swift-55-the-concurrency-revolution)
2. [Swift 5.6: Type System Refinements](#2-swift-56-type-system-refinements)
3. [Swift 5.7: Ergonomics & Regex](#3-swift-57-ergonomics--regex)
4. [Swift 5.8: Incremental Improvements](#4-swift-58-incremental-improvements)
5. [Swift 5.9: Macros & Parameter Packs](#5-swift-59-macros--parameter-packs)
6. [Swift 5.10: Strict Concurrency Preparation](#6-swift-510-strict-concurrency-preparation)
7. [Swift 6.0: Data-Race Safety by Default](#7-swift-60-data-race-safety-by-default)
8. [Swift 6.1: Refinements](#8-swift-61-refinements)
9. [Swift 6.2: Approachable Concurrency & Performance](#9-swift-62-approachable-concurrency--performance)
10. [Migration Patterns Quick Reference](#10-migration-patterns-quick-reference)
11. [Logging on Apple Platforms](#11-logging-on-apple-platforms)

---

## 1. Swift 5.5: The Concurrency Revolution

Swift 5.5 introduced structured concurrency. This is the most significant change in the language since Swift 1.0.

### 1.1 async/await

Replace completion handlers with async functions.

```swift
// OLD: Completion handler
func fetchUser(id: Int, completion: @escaping (Result<User, Error>) -> Void) {
    URLSession.shared.dataTask(with: url) { data, _, error in
        if let error { completion(.failure(error)); return }
        let user = try? JSONDecoder().decode(User.self, from: data!)
        completion(.success(user!))
    }.resume()
}

// MODERN: async/await
func fetchUser(id: Int) async throws -> User {
    let (data, _) = try await URLSession.shared.data(from: url)
    return try JSONDecoder().decode(User.self, from: data)
}
```

### 1.2 Actors

Actors provide thread-safe access to mutable state. Use them instead of classes with manual locking.

```swift
// OLD: Class with DispatchQueue for synchronization
class BankAccount {
    private let queue = DispatchQueue(label: "account")
    private var _balance: Double = 0

    var balance: Double {
        queue.sync { _balance }
    }

    func deposit(_ amount: Double) {
        queue.async { self._balance += amount }
    }
}

// MODERN: Actor
actor BankAccount {
    private var balance: Double = 0

    func deposit(_ amount: Double) {
        balance += amount
    }

    func getBalance() -> Double {
        balance
    }
}

// Usage requires await
let account = BankAccount()
await account.deposit(100)
let bal = await account.getBalance()
```

### 1.3 Structured Concurrency with Task and TaskGroup

```swift
// OLD: DispatchGroup
func fetchAllUsers(ids: [Int], completion: @escaping ([User]) -> Void) {
    let group = DispatchGroup()
    var users: [User] = []
    let lock = NSLock()

    for id in ids {
        group.enter()
        fetchUser(id: id) { result in
            if case .success(let user) = result {
                lock.lock()
                users.append(user)
                lock.unlock()
            }
            group.leave()
        }
    }

    group.notify(queue: .main) {
        completion(users)
    }
}

// MODERN: TaskGroup
func fetchAllUsers(ids: [Int]) async -> [User] {
    await withTaskGroup(of: User?.self) { group in
        for id in ids {
            group.addTask {
                try? await fetchUser(id: id)
            }
        }

        var users: [User] = []
        for await user in group {
            if let user { users.append(user) }
        }
        return users
    }
}
```

### 1.4 async let for Concurrent Bindings

```swift
// Run two async operations concurrently
async let profile = fetchProfile(userId: id)
async let posts = fetchPosts(userId: id)

// Await both results
let (userProfile, userPosts) = await (profile, posts)
```

### 1.5 @MainActor

Replace `DispatchQueue.main.async` with `@MainActor`.

```swift
// OLD
func updateUI() {
    DispatchQueue.main.async {
        self.label.text = "Updated"
    }
}

// MODERN
@MainActor
func updateUI() {
    label.text = "Updated"
}

// Or inline
await MainActor.run {
    label.text = "Updated"
}
```

### 1.6 Sendable Protocol

Types that cross concurrency boundaries must be `Sendable`.

```swift
// Value types with Sendable members are automatically Sendable
struct Config: Sendable {
    let timeout: Int
    let retryCount: Int
}

// Classes must be final with immutable properties, or use @unchecked
final class ImmutableConfig: Sendable {
    let timeout: Int
    init(timeout: Int) { self.timeout = timeout }
}

// For classes with internal synchronization
final class ThreadSafeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    // ... synchronized access methods
}
```

### 1.7 Continuations: Bridging Callback APIs

```swift
// Wrap a callback-based API in async
func legacyFetch() async -> Data {
    await withCheckedContinuation { continuation in
        LegacyAPI.fetch { data in
            continuation.resume(returning: data)
        }
    }
}

// For throwing APIs
func legacyFetchThrowing() async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        LegacyAPI.fetch { result in
            switch result {
            case .success(let data):
                continuation.resume(returning: data)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }
}
```

---

## 2. Swift 5.6: Type System Refinements

### 2.1 Existential `any`

Swift 5.6 introduced `any` to make existential types explicit.

```swift
// OLD: Implicit existential
func process(item: Codable) { }

// MODERN: Explicit existential
func process(item: any Codable) { }

// This makes it clear you're using type erasure, not generics
```

### 2.2 Type Placeholders

Use `_` when the compiler can infer a type.

```swift
// Let compiler infer the dictionary value type
let dict: [String: _] = ["key": SomeComplexType()]
```

---

## 3. Swift 5.7: Ergonomics & Regex

### 3.1 if let Shorthand

```swift
// OLD
if let value = value {
    print(value)
}

// MODERN: Same-name shorthand
if let value {
    print(value)
}

// Works with guard too
guard let config else { return }
```

### 3.2 Opaque Parameter Types (`some`)

Use `some` in parameters instead of verbose generic constraints.

```swift
// OLD: Generic constraint
func process<T: Collection>(items: T) where T.Element: Equatable { }

// MODERN: Opaque parameter
func process(items: some Collection<some Equatable>) { }

// Simpler example
func draw(shape: some Shape) { }
// Equivalent to: func draw<T: Shape>(shape: T) { }
```

### 3.3 Regex Literals

```swift
// OLD: NSRegularExpression
let pattern = try NSRegularExpression(pattern: "\\d{3}-\\d{4}")
let range = pattern.firstMatch(in: string, range: NSRange(string.startIndex..., in: string))

// MODERN: Regex literal (compile-time checked)
let regex = /\d{3}-\d{4}/
if let match = string.firstMatch(of: regex) {
    print(match.output)
}

// With captures
let phoneRegex = /(?<area>\d{3})-(?<number>\d{4})/
if let match = "555-1234".firstMatch(of: phoneRegex) {
    print(match.area)    // "555"
    print(match.number)  // "1234"
}

// Use #/.../#  in packages (bare slash may not work)
let safeRegex = #/\d+/#
```

### 3.4 Structural Opaque Result Types

```swift
// Return optional opaque type
func maybeShape() -> (some Shape)? {
    condition ? Circle() : nil
}

// Return tuple of opaque types
func shapePair() -> (some Shape, some Shape) {
    (Circle(), Square())
}
```

---

## 4. Swift 5.8: Incremental Improvements

### 4.1 Implicit self in Closures After Unwrap

```swift
// OLD: Required explicit self after guard
guard let self else { return }
self.doSomething()
self.value = 10

// MODERN: Implicit self after unwrap
guard let self else { return }
doSomething()  // No self. needed
value = 10
```

### 4.2 Result Builder Improvements

Better type inference and error messages in result builders like SwiftUI's `@ViewBuilder`.

---

## 5. Swift 5.9: Macros & Parameter Packs

### 5.1 Macros

Macros transform code at compile time. They're type-safe and sandboxed.

```swift
// Expression macro (returns a value)
let log = #stringify(2 + 2)  // Returns ("2 + 2", 4)

// Attached macro (modifies declarations)
@Observable
class Model {
    var name: String = ""
    var age: Int = 0
}
// Expands to property wrappers, willSet/didSet, etc.

// Freestanding declaration macro
#warning("TODO: Implement this")
```

Common built-in macros:
- `@Observable` - Observation framework
- `@Model` - SwiftData
- `#Preview` - SwiftUI previews
- `#expect`, `#require` - Swift Testing

### 5.2 Parameter Packs (Variadic Generics)

Write generic code that works with any number of type parameters.

```swift
// OLD: Had to write overloads for each arity
func zip<A, B>(_ a: A, _ b: B) -> (A, B)
func zip<A, B, C>(_ a: A, _ b: B, _ c: C) -> (A, B, C)
// ... etc

// MODERN: Single function with parameter pack
func zip<each T>(_ value: repeat each T) -> (repeat each T) {
    (repeat each value)
}

// Works with any number of arguments
let pair = zip(1, "hello")           // (Int, String)
let triple = zip(1, "hello", true)   // (Int, String, Bool)
```

### 5.3 `package` Access Modifier

Share code between targets in the same package without making it `public`.

```swift
// Visible to other targets in same package, but not to external packages
package func internalHelper() { }
```

### 5.4 Noncopyable Types (`~Copyable`)

Model unique resources that cannot be duplicated.

```swift
struct FileHandle: ~Copyable {
    private let fd: Int32

    init(path: String) {
        fd = open(path, O_RDONLY)
    }

    deinit {
        close(fd)
    }

    consuming func close() {
        close(fd)
    }
}

// Cannot copy - must transfer ownership
let handle = FileHandle(path: "/tmp/file")
// let copy = handle  // ERROR: Cannot copy
useHandle(handle)     // Ownership transferred
// handle is no longer valid here
```

---

## 6. Swift 5.10: Strict Concurrency Preparation

Swift 5.10 closes gaps in concurrency checking, preparing for Swift 6.

### 6.1 Complete Data Isolation

Enable complete checking to preview Swift 6 behavior:

```swift
// Package.swift
.target(
    name: "MyTarget",
    swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency")
    ]
)
```

Or command line: `-Xswiftc -strict-concurrency=complete`

### 6.2 `nonisolated(unsafe)`

Opt out of isolation checking when you know it's safe.

```swift
// For global state you've manually synchronized
nonisolated(unsafe) var globalCache: [String: Data] = [:]
```

---

## 7. Swift 6.0: Data-Race Safety by Default

Swift 6 enforces concurrency safety as errors, not warnings.

### 7.1 Strict Concurrency is Default

All code must be data-race safe. No more ignoring warnings.

```swift
// This is now an ERROR in Swift 6 language mode
var counter = 0
Task {
    counter += 1  // ERROR: Mutation of captured var 'counter' in concurrently-executing code
}
```

### 7.2 Typed Throws

Specify the exact error type a function throws.

```swift
// OLD: Throws any Error
func parse(_ data: Data) throws -> Document { }

// MODERN: Typed throws
enum ParseError: Error {
    case invalidFormat
    case unexpectedEOF
}

func parse(_ data: Data) throws(ParseError) -> Document {
    guard isValid(data) else { throw .invalidFormat }
    // ...
}

// Caller knows exactly what can be thrown
do {
    let doc = try parse(data)
} catch .invalidFormat {
    // Handle specific error
} catch .unexpectedEOF {
    // Handle specific error
}
// No need for catch-all!
```

Typed throws propagate through generics:

```swift
// The error type propagates
func map<T, E>(_ transform: (Element) throws(E) -> T) throws(E) -> [T]
```

### 7.3 Synchronization Framework: Mutex & Atomics

New low-level primitives for when actors are too heavy.

```swift
import Synchronization

// Mutex protects shared mutable state
let counter = Mutex(0)

// Safe concurrent access
counter.withLock { value in
    value += 1
}

// Atomics for lock-free operations
let flag = Atomic(false)
flag.store(true, ordering: .releasing)
let current = flag.load(ordering: .acquiring)
```

### 7.4 Noncopyable Generics

Noncopyable types now work in generics, Optional, and Result.

```swift
// Optional can hold noncopyable types
var maybeHandle: FileHandle? = FileHandle(path: "/tmp/x")

// Generic functions can accept noncopyable types
func process<T: ~Copyable>(_ value: consuming T) { }
```

### 7.5 `Copyable` is Implicit

Every type conforms to `Copyable` unless marked `~Copyable`.

```swift
// These are equivalent
struct Point { var x, y: Double }
struct Point: Copyable { var x, y: Double }
```

### 7.6 128-bit Integer Types

```swift
let big: Int128 = 170_141_183_460_469_231_731_687_303_715_884_105_727
let unsigned: UInt128 = 340_282_366_920_938_463_463_374_607_431_768_211_455
```

---

## 8. Swift 6.1: Refinements

### 8.1 Concurrency Ergonomics

- Better inference of `@Sendable` for closures
- Improved actor isolation diagnostics
- `nonisolated` works in more contexts

### 8.2 Swift Testing Improvements

```swift
import Testing

@Test func addition() {
    #expect(2 + 2 == 4)
}

@Test("User can log in", .tags(.auth))
func login() async throws {
    let user = try await authenticate(username: "test", password: "pass")
    #expect(user.isAuthenticated)
}
```

---

## 9. Swift 6.2: Approachable Concurrency & Performance

### 9.1 Approachable Concurrency

Makes concurrency easier to adopt correctly.

#### `defaultIsolation` Build Setting

Run code on `@MainActor` by default (per-module):

```swift
// In Package.swift or build settings
// defaultIsolation: MainActor

// Now functions are MainActor by default
func updateUI() {  // Implicitly @MainActor
    label.text = "Hello"
}
```

#### `nonisolated(nonsending)`

Functions run on caller's executor instead of hopping to global executor.

```swift
nonisolated(nonsending) func helper() async {
    // Runs on whatever actor called this
}
```

#### `@concurrent`

Explicitly opt into concurrent execution.

```swift
@concurrent
func heavyComputation() async -> Result {
    // Explicitly runs on global executor
}
```

### 9.2 InlineArray

Fixed-size, stack-allocated arrays for performance.

```swift
// Declare with count and type
var buffer: InlineArray<64, UInt8> = .init(repeating: 0)

// Access via subscript
buffer[0] = 255

// Iterate via indices (doesn't conform to Sequence)
for i in buffer.indices {
    print(buffer[i])
}

// Alternative syntax
var codes: [8 x Int] = [1, 2, 3, 4, 5, 6, 7, 8]
```

Benefits:
- No heap allocation
- No reference counting
- No copy-on-write overhead
- Predictable memory layout

### 9.3 Span and RawSpan

Safe, non-owning views into contiguous memory.

```swift
// Span provides safe access to buffer contents
func process(data: Span<UInt8>) {
    for byte in data {
        // Bounds-checked access
    }
}

// Works with Array, InlineArray, or any contiguous buffer
let array = [1, 2, 3, 4, 5]
process(data: array.span)

// RawSpan for untyped byte access
func parseHeader(bytes: RawSpan) -> Header {
    // Safe, bounds-checked raw memory access
}
```

Key properties:
- Non-owning (no allocation/deallocation)
- Non-escaping (can't outlive source buffer)
- Bounds-checked (safe subscripting)

### 9.4 Subprocess

Modern replacement for `Process`.

```swift
import Subprocess

// Simple execution
let result = try await Subprocess.run(.name("ls"), arguments: ["-la"])
print(result.terminationStatus)

// Capture output as string
let output = try await Subprocess.run(
    .path("/usr/bin/git"),
    arguments: ["status"],
    output: .string
)
print(output.standardOutput)

// With working directory and environment
let result = try await Subprocess.run(
    .name("npm"),
    arguments: ["install"],
    workingDirectory: "/path/to/project",
    environment: ["NODE_ENV": "production"]
)
```

### 9.5 Raw Identifiers

Use reserved words as identifiers.

```swift
let `actor` = "Tom Hanks"
let `class` = "Economy"
let `func` = { print("Hello") }
```

### 9.6 Default Values in String Interpolation

```swift
let name: String? = nil
print("Hello, \(name, default: "World")!")  // "Hello, World!"
```

### 9.7 Swift Testing Enhancements

```swift
// Exit tests - verify code exits correctly
@Test func fatalErrorOnInvalidInput() async {
    await #expect(exitsWith: .failure) {
        fatalError("Invalid input")
    }
}

// Attachments - add context to test results
@Test func imageProcessing() throws {
    let result = process(image)
    #expect(result.isValid)

    // Attach image for debugging if test fails
    Attachment(result.image, named: "processed.png").attach()
}
```

---

## 10. Migration Patterns Quick Reference

### Concurrency

| Old Pattern | Modern Replacement |
|------------|-------------------|
| `completion: @escaping (T) -> Void` | `async -> T` |
| `DispatchQueue.main.async { }` | `await MainActor.run { }` or `@MainActor` |
| `DispatchQueue.global().async { }` | `Task { }` |
| `DispatchQueue.main.asyncAfter(deadline:)` | `try await Task.sleep(for:)` |
| `DispatchGroup` | `withTaskGroup` / `withThrowingTaskGroup` |
| `DispatchSemaphore` | Actor or `AsyncStream` |
| `class` with lock for shared state | `actor` |
| `Timer.scheduledTimer(withTimeInterval:repeats:)` | `for await _ in AsyncTimerSequence` or `Task` + `Task.sleep` |
| `NSLock` / `os_unfair_lock` | `Mutex` (Swift 6+) |
| `@objc` callbacks | `withCheckedContinuation` |

### Process Management

| Old Pattern | Modern Replacement |
|------------|-------------------|
| `Process()` | `Subprocess.run()` |
| `task.standardOutput = Pipe()` | `output: .string` or `output: .data` |
| `task.waitUntilExit()` | `try await Subprocess.run()` |

### Types & Syntax

| Old Pattern | Modern Replacement |
|------------|-------------------|
| `if let x = x { }` | `if let x { }` |
| `func f<T: P>(_ x: T)` | `func f(_ x: some P)` |
| `NSRegularExpression` | `/regex/` literals |
| `Date()` | `Date.now` |
| `URL(fileURLWithPath:)` | `URL(filePath:)` |
| `throws` (untyped) | `throws(SpecificError)` |
| `UnsafeBufferPointer` | `Span` |
| `[Element](repeating:count:)` for fixed size | `InlineArray` |

### Package.swift

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyPackage",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mytool", targets: ["MyTool"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.1.0")
    ],
    targets: [
        .executableTarget(
            name: "MyTool",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
```

---

## 11. Logging on Apple Platforms

### 11.1 Use Native OSLog, Not swift-log

For macOS/iOS/visionOS apps, use Apple's native `os.Logger` instead of third-party logging libraries like swift-log.

**Why native Logger:**
- Apple's recommended approach
- Zero dependencies
- First-class Console.app integration
- Subsystem/category filtering in `log show`
- Automatic log level persistence
- Privacy controls for sensitive data

**When to use swift-log:**
- Server-side Swift (Linux)
- Cross-platform packages

### 11.2 Logger API

```swift
import OSLog

// Create logger with subsystem (typically reverse-DNS) and category
private let logger = Logger(subsystem: "com.example.myapp", category: "Networking")

// Log levels (from least to most severe)
logger.trace("Detailed debugging info")        // Not persisted by default
logger.debug("Debug info")                     // Not persisted by default
logger.info("Informational message")           // Persisted
logger.notice("Notable condition")             // Persisted
logger.warning("Warning condition")            // Persisted
logger.error("Error condition")                // Persisted, highlighted
logger.fault("Critical fault")                 // Persisted, always shown
```

### 11.3 Privacy Controls

OSLog uses string interpolation with privacy specifiers. By default, dynamic values are redacted in production.

```swift
// Public - visible in production logs
logger.info("User tapped: \(buttonName, privacy: .public)")

// Private (default) - redacted in production, visible in debug
logger.info("User ID: \(userId)")  // Shows as <private>

// Explicit private
logger.info("Email: \(email, privacy: .private)")

// Hash - shows hash of value for correlation without revealing data
logger.info("Session: \(sessionId, privacy: .private(mask: .hash))")
```

### 11.4 Formatting

```swift
// Alignment and width
logger.debug("Count: \(count, align: .right(columns: 5))")

// Format specifiers
logger.debug("Progress: \(progress, format: .fixed(precision: 2))%")
logger.debug("Bytes: \(byteCount, format: .byteCount(countStyle: .memory))")
logger.debug("Hex: \(value, format: .hex)")
```

### 11.5 Type Requirements

OSLog interpolation requires types to conform to specific protocols:
- Strings: work directly
- Numbers: work directly
- Custom types: must conform to `CustomStringConvertible`

```swift
enum Status: CustomStringConvertible {
    case active, inactive

    var description: String {
        switch self {
        case .active: "active"
        case .inactive: "inactive"
        }
    }
}

// Now works in OSLog
logger.info("Status: \(status, privacy: .public)")

// For types you can't modify, use String(describing:)
logger.debug("ID: \(String(describing: ObjectIdentifier(object)), privacy: .public)")
```

### 11.6 Self References in @Observable Classes

OSLog string interpolation creates closures. Inside `@Observable` classes with property observers, use explicit `self`:

```swift
@Observable
class State {
    var value: Int = 0 {
        didSet {
            // Must use self.value, not just value
            logger.debug("Value changed: \(self.value, privacy: .public)")
        }
    }
}
```

### 11.7 Viewing Logs

**Console.app:**
- Filter by subsystem: `subsystem:com.example.myapp`
- Filter by category: `category:Networking`
- Filter by level: `type:error`

**Command line:**
```bash
# Stream live logs for your app
log stream --predicate 'subsystem == "com.example.myapp"'

# Show recent logs
log show --predicate 'subsystem == "com.example.myapp"' --last 1h

# Filter by category and level
log show --predicate 'subsystem == "com.example.myapp" AND category == "Networking" AND messageType >= error'

# Include debug/info (not persisted by default)
log show --predicate 'subsystem == "com.example.myapp"' --info --debug
```

### 11.8 Migration from swift-log

| swift-log | OSLog |
|-----------|-------|
| `import Logging` | `import OSLog` |
| `Logger(label: "osom.Network")` | `Logger(subsystem: "com.osom.app", category: "Network")` |
| `logger.info("msg", metadata: ["key": "\(val)"])` | `logger.info("msg: key=\(val, privacy: .public)")` |
| `LoggingSystem.bootstrap(...)` | Not needed |

---

## Sources

- [What's new in Swift 5.5 | Hacking with Swift](https://www.hackingwithswift.com/articles/233/whats-new-in-swift-5-5)
- [What's new in Swift 5.7 | Hacking with Swift](https://www.hackingwithswift.com/articles/249/whats-new-in-swift-5-7)
- [What's new in Swift 5.9 | Hacking with Swift](https://www.hackingwithswift.com/articles/258/whats-new-in-swift-5-9)
- [Swift 5.10 Released | Swift.org](https://www.swift.org/blog/swift-5.10-released/)
- [Announcing Swift 6 | Swift.org](https://www.swift.org/blog/announcing-swift-6/)
- [What's new in Swift 6.0 | Hacking with Swift](https://www.hackingwithswift.com/articles/269/whats-new-in-swift-6)
- [What's new in Swift 6.2 | Hacking with Swift](https://www.hackingwithswift.com/articles/277/whats-new-in-swift-6-2)
- [Adopting strict concurrency in Swift 6 | Apple Developer](https://developer.apple.com/documentation/swift/adoptingswift6)
- [Swift Subprocess | GitHub](https://github.com/swiftlang/swift-subprocess)
- [Approachable Concurrency in Swift 6.2 | SwiftLee](https://www.avanderlee.com/concurrency/approachable-concurrency-in-swift-6-2-a-clear-guide/)
- [Modern Swift Lock: Mutex | SwiftLee](https://www.avanderlee.com/concurrency/modern-swift-lock-mutex-the-synchronization-framework/)
- [Swift 6.2: InlineArray and Span | Medium](https://gayeugur.medium.com/swift-6-2-understanding-array-inlinearray-and-span-performance-memory-safety-advancements-db731398dfdd)
- [Everything you need to know about Swift 5.10 | Donny Wals](https://www.donnywals.com/everything-you-need-to-know-about-swift-5-10/)
- [Logging | Apple Developer Documentation](https://developer.apple.com/documentation/os/logging)
- [OSLog and Unified logging as recommended by Apple | SwiftLee](https://www.avanderlee.com/debugging/oslog-unified-logging/)
