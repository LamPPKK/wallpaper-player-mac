// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Wallpaper_Player_User_Documentation",
    products: [.library(name: "Wallpaper_Player_User_Documentation", targets: ["UserDocumentation"])],
    targets: [.target(name: "UserDocumentation")]
)
