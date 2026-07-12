// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacPet",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacPet", targets: ["MacPet"])],
    targets: [
        .executableTarget(name: "MacPet", resources: [.process("Resources")]),
        .testTarget(name: "MacPetTests", dependencies: ["MacPet"])
    ]
)
