// swift-tools-version: 5.9
//
// GhostKit — logique indépendante de l'interface de GHOST.
// Ce package ne dépend d'aucune bibliothèque externe et ne contient
// aucun code SwiftUI/AppKit : il est compilable et testable seul
// (`swift test`), y compris hors de Xcode.

import PackageDescription

let package = Package(
    name: "GhostKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GhostKit", targets: ["GhostKit"])
    ],
    targets: [
        .target(name: "GhostKit"),
        .testTarget(name: "GhostKitTests", dependencies: ["GhostKit"])
    ]
)
