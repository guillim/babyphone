// swift-tools-version: 6.0
import PackageDescription

// BabyphoneCore holds every decision the app makes that does not need an Apple
// framework: pairing, wire formats, link supervision, noise detection, storage.
// It builds and tests on Linux, so the logic is checked without a device.

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0"),
]
var coreDependencies: [Target.Dependency] = [
    .product(name: "GRDB", package: "GRDB.swift"),
]

#if os(Linux)
// CryptoKit does not exist on Linux. swift-crypto offers the same API there,
// so it is pulled in only when the package is built on a Linux host.
dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"))
coreDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
#endif

let package = Package(
    name: "BabyphoneKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "BabyphoneCore", targets: ["BabyphoneCore"]),
    ],
    dependencies: dependencies,
    targets: [
        .target(name: "BabyphoneCore", dependencies: coreDependencies),
        .testTarget(name: "BabyphoneCoreTests", dependencies: ["BabyphoneCore"]),
    ]
)
