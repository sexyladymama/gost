// swift-tools-version: 5.9
import PackageDescription

// IA embarquée de GHOST : un modèle ouvert (Qwen 2.5 7B Instruct, licence Apache-2.0) exécuté sur ce Mac par llama.cpp.
// Aucune clé, aucun réseau pour raisonner. Le runtime est le binaire officiel publié par ggml-org, épinglé par version ET par somme de contrôle.
let package = Package(
    name: "GhostLocalLLM",
    platforms: [.macOS(.v14)],
    products: [.library(name: "GhostLocalLLM", targets: ["GhostLocalLLM"])],
    dependencies: [.package(path: "../GhostKit")],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12171/llama-b12171-xcframework.zip",
            checksum: "b52872ea2edde279082e1058c776051852ffff060d8ee64b0403ad79445cb26e"),
        .target(name: "GhostLocalLLM", dependencies: ["llama", .product(name: "GhostBrain", package: "GhostKit")]),
        .testTarget(name: "GhostLocalLLMTests", dependencies: [
            "GhostLocalLLM", .product(name: "GhostBrain", package: "GhostKit"), .product(name: "GhostCore", package: "GhostKit"), .product(name: "GhostMind", package: "GhostKit"),
            .product(name: "GhostContext", package: "GhostKit"), .product(name: "GhostPerception", package: "GhostKit")])
    ]
)
