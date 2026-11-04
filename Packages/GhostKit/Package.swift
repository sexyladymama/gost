// swift-tools-version: 5.9
//
// GhostKit — logique indépendante de l'interface de GHOST.
//
// - `GhostKit`        : états de GHOST et point d'extension du moteur (Mission 001).
// - `GhostPerception` : moteur de perception — sources, normalisation,
//                       compréhension, stockage, confiance (Mission 002).
//
// Aucune dépendance externe. Aucun code SwiftUI/AppKit : tout est
// compilable et testable avec `swift test`, y compris hors de Xcode.

import PackageDescription

let package = Package(
    name: "GhostKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GhostKit", targets: ["GhostKit"]),
        .library(name: "GhostPerception", targets: ["GhostPerception"]),
        .library(name: "GhostContext", targets: ["GhostContext"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "GhostKit"),
        .target(name: "GhostPerception", dependencies: ["GhostKit"]),
        .testTarget(name: "GhostKitTests", dependencies: ["GhostKit"]),
        .testTarget(name: "GhostPerceptionTests", dependencies: ["GhostPerception"]),
        .target(name: "GhostContext", dependencies: ["GhostPerception", "CSQLite"]),
        .testTarget(name: "GhostContextTests", dependencies: ["GhostContext"])
    ]
)
