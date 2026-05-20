# iOS app

## Generate the Xcode project

[XcodeGen](https://github.com/yonaskolb/XcodeGen) turns `project.yml` into a real `.xcodeproj`. Nothing Swift-side is hand-managed — edit `project.yml` and re-run.

```bash
brew install xcodegen
cd ios
xcodegen generate
open PugetRoute.xcodeproj
```

Re-run `xcodegen generate` any time you add, remove, or rename Swift files, or edit `project.yml`.

## Before you build

1. Open `project.yml` and set `DEVELOPMENT_TEAM` to your Apple Developer team ID (10-char string, visible in Xcode → Settings → Accounts). Or leave it blank and set it once in Xcode's "Signing & Capabilities" tab — but you'll have to redo it after every `xcodegen generate`.
2. Open `PugetRoute/RoutingClient.swift` and set `baseURL` to wherever OTP is reachable:
   - Simulator + OTP running on the same Mac: `http://localhost:8080` ✅ already configured
   - Real device on same Wi-Fi: `http://<your-mac-lan-ip>:8080` — and add that host to `NSExceptionDomains` in `project.yml`
   - Production: `https://otp.yourdomain.com` — then you can drop the ATS exception entirely.

## Project structure

```
ios/
├── project.yml                 # XcodeGen spec (the source of truth)
└── PugetRoute/
    ├── Info.plist              # generated & managed by XcodeGen from project.yml
    ├── PugetRouteApp.swift     # @main entry
    ├── ContentView.swift       # search bar, mode picker, itinerary carousel
    ├── MapView.swift           # MKMapView wrapper w/ colored polylines
    ├── RoutingClient.swift     # OTP GraphQL client
    ├── Models.swift            # Itinerary/Leg/Place decodables
    ├── LocationManager.swift   # CoreLocation wrapper
    └── PolylineDecoder.swift   # Google-polyline → [CLLocationCoordinate2D]
```

`PugetRoute.xcodeproj/` (and `.xcworkspace/` if you add it later) should be gitignored — they're derived.

## Suggested `.gitignore`

```
# Xcode
*.xcodeproj
xcuserdata/
DerivedData/
*.xcworkspace/xcuserdata/

# Swift Package Manager
.build/
.swiftpm/

# macOS
.DS_Store
```

## Testing

No unit tests yet. When you're ready:
1. Add a `PugetRouteTests` target to `project.yml`.
2. Start with tests for `PolylineDecoder` (pure function, easy) and a mocked `RoutingClient` using `URLProtocol` stubs.
