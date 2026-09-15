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
    name: "Diktat",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Diktat", targets: ["Diktat"])],
    dependencies: [
        .package(path: "Vendor/KeyboardShortcuts")
    ],
    targets: [
        .target(name: "CWhisper", publicHeadersPath: "include", cxxSettings: [
            .unsafeFlags(["-I" + root + "/.build/whisper-source/include", "-I" + root + "/.build/whisper-source/ggml/include"])
        ], linkerSettings: [
            .unsafeFlags(libraries), .linkedFramework("Accelerate"),
            .linkedFramework("Metal"), .linkedFramework("MetalKit"), .linkedFramework("Foundation")
        ]),
        .executableTarget(name: "Diktat", dependencies: ["KeyboardShortcuts", "CWhisper"])
    ],
    cxxLanguageStandard: .cxx17
)
