// swift-tools-version: 5.9
// The Swift target builds only the bare executable; packaging/build.sh wraps it
// into GcloudBar.app (Info.plist, icon, codesign).
import PackageDescription

let package = Package(
    name: "GcloudBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GcloudBar")
    ]
)
