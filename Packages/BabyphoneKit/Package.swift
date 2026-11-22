// swift-tools-version: 6.0
import PackageDescription

// BabyphoneCore holds every decision the app makes that does not need an Apple
// framework: pairing, wire formats, link supervision, noise detection, storage.
// It builds and tests on Linux, so the logic is checked without a device.
//
// BabyphoneTransport carries those decisions over the real thing: WebRTC peer
// connections and TCP channels on the local network. It needs Apple platforms,
// and its tests run the real stacks on a Mac.

var products: [Product] = [
    .library(name: "BabyphoneCore", targets: ["BabyphoneCore"]),
]
var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0"),
]
var coreDependencies: [Target.Dependency] = [
    .product(name: "GRDB", package: "GRDB.swift"),
]
var targets: [Target] = []

#if os(Linux)
// CryptoKit does not exist on Linux. swift-crypto offers the same API there,
// so it is pulled in only when the package is built on a Linux host.
dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"))
coreDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
#else
// WebRTC ships as a prebuilt framework for Apple platforms only. The version is
// pinned: each release follows a Chrome milestone and may change behaviour.
products.append(.library(name: "BabyphoneTransport", targets: ["BabyphoneTransport"]))
dependencies.append(.package(url: "https://github.com/stasel/WebRTC.git", exact: "158.0.0"))
targets += [
    .target(name: "BabyphoneTransport", dependencies: ["BabyphoneCore", .product(name: "WebRTC", package: "WebRTC")]),
    .testTarget(name: "BabyphoneTransportTests", dependencies: ["BabyphoneTransport", "TestSupport"]),
]
#endif

targets += [
    .target(name: "BabyphoneCore", dependencies: coreDependencies),
    // Waits with a deadline, shared by both test targets.
    .target(name: "TestSupport", dependencies: ["BabyphoneCore"], path: "Tests/TestSupport"),
    .testTarget(name: "BabyphoneCoreTests", dependencies: ["BabyphoneCore", "TestSupport"]),
]

let package = Package(
    name: "BabyphoneKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
