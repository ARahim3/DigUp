// swift-tools-version: 6.2
import PackageDescription

// Linux (x86_64 first): only the `digup` CLI and its engine are portable.
// The menubar app (AppKit/SwiftUI/Sparkle) stays macOS-only and is appended below.
var products: [Product] = [
    .executable(name: "digup", targets: ["digup"]),
    .library(name: "DigUpKit", targets: ["DigUpKit"]),
]
var dependencies: [Package.Dependency] = []

#if os(Linux)
let digUpKitDeps: [Target.Dependency] = ["CSQLite"]
#else
let digUpKitDeps: [Target.Dependency] = []
#endif

var targets: [Target] = [
    // The engine: crawler, extractors, index store, the embedder interface and worker client, search. No UI.
    .target(name: "DigUpKit", dependencies: digUpKitDeps),
    // llama.cpp (scripts/build-llama.sh builds it into Vendor/llama) and EmbeddingGemma 2 on it.
    .systemLibrary(name: "CLlama", path: "Sources/CLlama"),
    .target(
        name: "LlamaRuntime",
        dependencies: ["CLlama", "DigUpKit"],
        linkerSettings: [
            .unsafeFlags(["-L\(Context.packageDirectory)/Vendor/llama/lib"]),
            // Moved out of Sources/CLlama/module.modulemap (modulemaps have no
            // conditionals, and `link framework` breaks Linux linking).
            .linkedFramework("Accelerate", .when(platforms: [.macOS])),
            .linkedFramework("Metal", .when(platforms: [.macOS])),
            .linkedFramework("MetalKit", .when(platforms: [.macOS])),
        ]
    ),
    // Developer CLI: estimate / index / search / status / eval. Doubles as the eval harness, and the app runs it as
    // its indexing helper and its query encoder.
    .executableTarget(name: "digup", dependencies: ["DigUpKit", "LlamaRuntime"]),
    .testTarget(name: "DigUpKitTests", dependencies: ["DigUpKit"]),
    .testTarget(name: "LlamaRuntimeTests", dependencies: ["LlamaRuntime"]),
]

#if os(macOS)
products.append(.executable(name: "DigUpApp", targets: ["DigUpApp"]))
// In-app updates (the app only). build.sh embeds the framework in Contents/Frameworks and signs it.
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"))
targets += [
    // The menubar + hotkey app. build.sh wraps it into build.noindex/DigUp.app. (The product can't be called
    // "DigUp": on a case-insensitive disk it would collide with the `digup` CLI binary.)
    .executableTarget(
        name: "DigUpApp",
        dependencies: ["DigUpKit", .product(name: "Sparkle", package: "Sparkle")],
        swiftSettings: [.defaultIsolation(MainActor.self)],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
    ),
]
#else
// Linux SQLite headers (macOS gets them from the SDK). Needs libsqlite3-dev (apt) / sqlite (Arch).
targets.append(.systemLibrary(name: "CSQLite", path: "Sources/CSQLite", pkgConfig: "sqlite3",
                              providers: [.apt(["libsqlite3-dev"])]))
#endif

let package = Package(
    name: "DigUp",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
