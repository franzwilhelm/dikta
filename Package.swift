// swift-tools-version: 6.2
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let native = root + "/.build/whisper-native"
let libraries = [
    "/src/libwhisper.a", "/ggml/src/libggml.a", "/ggml/src/libggml-cpu.a",
    "/ggml/src/ggml-metal/libggml-metal.a", "/ggml/src/ggml-blas/libggml-blas.a",
    "/ggml/src/libggml-base.a"
].map { native + $0 }

let package = Package(
    name: "Dikta",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Dikta", targets: ["Diktat"])],
    dependencies: [
        .package(path: "Vendor/KeyboardShortcuts"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .target(name: "CWhisper", publicHeadersPath: "include", cxxSettings: [
            .unsafeFlags(["-I" + root + "/.build/whisper-source/include", "-I" + root + "/.build/whisper-source/ggml/include"])
        ], linkerSettings: [
            .unsafeFlags(libraries), .linkedFramework("Accelerate"),
            .linkedFramework("Metal"), .linkedFramework("MetalKit"), .linkedFramework("Foundation")
        ]),
        .executableTarget(name: "Diktat", dependencies: [
            "KeyboardShortcuts", "CWhisper", .product(name: "Sparkle", package: "Sparkle")
        ], linkerSettings: [
            // Sparkle.framework is copied to Contents/Frameworks by scripts/package-app.sh.
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
        ])
    ],
    cxxLanguageStandard: .cxx17
)
