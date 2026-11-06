// swift-tools-version: 5.9
//
// GhostKit — logique indépendante de l'interface de GHOST.
//
// - `GhostKit`        : états de GHOST et point d'extension du moteur (Mission 001).
// - `GhostPerception` : moteur de perception — sources, normalisation,
//                       compréhension, stockage, confiance (Mission 002).
// - `GhostContext`    : mémoire contextuelle locale (Mission 003).
// - `GhostBrain`      : cerveau décisionnel — objectifs, décisions, missions, plans (Mission 004).
//
// ZIPFoundation est épinglé pour XLSX. Vision/Mind utilisent les frameworks macOS.
// La logique et ses tests sont exécutables avec `swift test`, hors de Xcode.

import PackageDescription

let package = Package(
    name: "GhostKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GhostKit", targets: ["GhostKit"]),
        .library(name: "GhostPerception", targets: ["GhostPerception"]),
        .library(name: "GhostContext", targets: ["GhostContext"]),
        .library(name: "GhostBrain", targets: ["GhostBrain"]),
        .library(name: "GhostAutonomy", targets: ["GhostAutonomy"]),
        .library(name: "GhostVision", targets: ["GhostVision"]),
        .library(name: "GhostMind", targets: ["GhostMind"])
    ],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "GhostKit"),
        .target(name: "GhostPerception", dependencies: ["GhostKit"]),
        .testTarget(name: "GhostKitTests", dependencies: ["GhostKit"]),
        .testTarget(name: "GhostPerceptionTests", dependencies: ["GhostPerception"]),
        .target(name: "GhostContext", dependencies: ["GhostPerception", "CSQLite"]),
        .testTarget(name: "GhostContextTests", dependencies: ["GhostContext"]),
        .target(name: "GhostBrain", dependencies: ["GhostPerception", "GhostContext"]),
        .testTarget(name: "GhostBrainTests", dependencies: ["GhostBrain", "GhostPerception", "GhostContext"]),
        .target(name: "GhostAutonomy", dependencies: ["GhostBrain", "GhostPerception", .product(name: "ZIPFoundation", package: "ZIPFoundation")]),
        .testTarget(name: "GhostAutonomyTests", dependencies: ["GhostAutonomy", "GhostContext"]),
        .target(name: "GhostVision", dependencies: ["GhostPerception"]),
        .testTarget(name: "GhostVisionTests", dependencies: ["GhostVision", "GhostPerception", "GhostContext", "GhostBrain"]),
        .target(name: "GhostMind", dependencies: ["GhostBrain", "GhostContext", "GhostPerception"]),
        .testTarget(name: "GhostMindTests", dependencies: ["GhostMind", "GhostBrain", "GhostContext", "GhostPerception", "GhostVision"], exclude: ["Fixtures"])
    ]
)
