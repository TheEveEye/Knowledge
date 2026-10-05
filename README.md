# Knowledge

An iOS 27 SwiftUI app with local SwiftData items and Sign in with ChatGPT. Open `Knowledge.xcodeproj` in Xcode 27, select the shared `Knowledge` scheme, and run on an iPhone or iPad simulator or device. The existing items remain stored on the device through account switches and sign-out.

## ChatGPT sign-in

The app uses OpenAI’s dynamic registration flow for local, personal, and open-source apps. It needs no API key, client secret, or pre-issued partner client ID. Identity sign-in and permission to use a ChatGPT plan are separate: declining the optional plan permission still lets the user sign in.

The sign-in screen offers **Continue with ChatGPT** and saved account registrations. Account settings support switching accounts, adding a registration, granting plan permission later, opening ChatGPT usage settings, and signing out. Each registration has a stable label, so accounts with the same email remain distinguishable. The first connection with plan permission shows a dismissible welcome message.

The authentication layer:

- Generates a stable installation host ID and fresh state, nonce, and PKCE values for every authorization attempt.
- Receives the issued client ID on a temporary `http://127.0.0.1:<port>/auth/callback` listener. It retains the registration before token exchange so a later attempt can reuse it.
- Exchanges the code using the issued client ID and verifies ID-token signature, issuer, audience, expiry, and nonce using OpenAI discovery/JWKS and JWTKit 5.
- Stores each registration and its credentials separately in the Keychain, available only while this device is unlocked. Credentials never enter SwiftData or UserDefaults.
- Restores the selected account, serializes refreshes, saves rotating refresh tokens, and attempts remote revocation before clearing the selected account’s local credentials on sign-out.

The app currently provides authentication and local items. A reusable plan request client supports model discovery and streaming Responses API requests for future AI features. It uses the active account’s refreshed OAuth access token, `GET https://api.openai.com/v1/models`, and `POST https://api.openai.com/v1/responses` with `store: false`, `stream: true`, and array input. It captures returned token counts and handles admission errors, plan eligibility and usage-limit failures, incomplete/interrupted responses, and cancellation. Account settings link to ChatGPT’s usage settings.

## Native callback adaptation

OpenAI receives the required HTTP loopback redirect URI. After validating that callback, the local listener redirects the embedded `ASWebAuthenticationSession` browser to the app’s private callback scheme with an unpredictable, attempt-specific marker. The authorization code and tokens are not included in that native bridge URL. This bridge dismisses the browser through Apple’s supported custom-scheme callback mechanism; it does not register a custom redirect URI with OpenAI.

The listener binds to IPv4 loopback, limits request sizes and concurrent connections, validates the request host/path and OAuth state, and accepts one callback per attempt. Cancellation, timeout, or backgrounding closes the browser and listener. No broad ATS exception or Bonjour advertisement is configured.

**The native bridge passed a controlled iOS 27 iPhone simulator probe, and login has been confirmed on the physical iPhone.** Apple documents authentication sessions and loopback listeners separately; keep testing this adaptation when updating supported iOS versions. Keep Knowledge in the foreground during sign-in. Automated protocol, listener, token, and state tests do not substitute for a real browser authorization and token exchange.

## Build and test

The shared scheme includes the hosted Swift Testing target `KnowledgeTests`. JWTKit and its transitive dependencies are resolved through Swift Package Manager.

```sh
xcodebuild -resolvePackageDependencies -project Knowledge.xcodeproj -scheme Knowledge
xcodebuild build -project Knowledge.xcodeproj -scheme Knowledge -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Knowledge.xcodeproj -scheme Knowledge -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' CODE_SIGNING_ALLOWED=NO
```

The optional `KnowledgeNativeAuthProbe` scheme runs a controlled, local browser redirect without exchanging tokens or creating a ChatGPT registration. Run it with the app visible and approve the system browser notice:

```sh
xcodebuild test -project Knowledge.xcodeproj -scheme KnowledgeNativeAuthProbe \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' \
  -parallel-testing-enabled NO -only-testing:KnowledgeTests/OAuthBrowserSessionProbeTests
```

The standard scheme skips this interactive probe. Automated protocol, API, Keychain, and session tests passed, as did iPhone/iPad simulator and unsigned iOS device builds. The live OpenAI sign-in page opened on the iPad simulator, cancellation returned cleanly, and the login layout was checked in light/dark appearance and at the largest text size. Login has been confirmed on the paired iPhone. A real plan request also completed on that iPhone using its saved OAuth connection, returning text and input/output token counts. The live service omitted the stream Content-Type header, so the reader validates the actual events and requires `response.completed` to confirm success.

Manual checks on simulator and physical device:

1. Sign in with optional plan permission accepted and declined; verify identity, selected account, and first-plan welcome behavior.
2. Relaunch, switch registrations, add another account, and sign back in to a saved registration after sign-out.
3. Cancel the browser, background the app, lose the network, and retry; verify no stale callback activates an account.
4. Grant plan permission later and open **Manage ChatGPT usage**. Verify sign-out removes credentials and preserves local items.
5. Inspect the sign-in and account views in light/dark appearance, at accessibility text sizes, and with VoiceOver.

## References

- [OpenAI registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [OpenAI accounts and sessions](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
- [OpenAI UI/UX guidelines](https://developers.openai.com/siwc/ui-ux-guidelines)
- [ChatGPT usage settings](https://chatgpt.com/settings/usage)
- [Apple authentication sessions](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
- [Apple local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

The ChatGPT logo asset comes from [OpenAI’s approved sign-in assets](https://developers.openai.com/assets/siwc/sign-in-buttons/chatgpt-logo-black.svg). The integration configuration follows the local/open-source flow; paid or remotely hosted distribution requires the applicable OpenAI access approval.
