# Info.plist keys you'll need

Add these in Xcode → target → Info tab (or edit Info.plist directly):

## Location permission (required)

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>PugetRoute uses your location to plan trips from where you are.</string>
```

## Plaintext HTTP to local OTP (dev only — remove before shipping)

If you point `RoutingClient.baseURL` at an `http://…` address (e.g. your Mac's LAN IP while developing), iOS will block it unless you allow it:

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSExceptionDomains</key>
  <dict>
    <key>192.168.1.42</key>   <!-- change to your OTP host -->
    <dict>
      <key>NSTemporaryExceptionAllowsInsecureHTTPLoads</key>
      <true/>
    </dict>
  </dict>
</dict>
```

**Do not ship with a blanket `NSAllowsArbitraryLoads = true`.** Put TLS (Caddy + Let's Encrypt) in front of OTP for production; see `otp-setup/README.md`.
