# Knowledge

An iOS 27 SwiftUI app that turns study notes into source-grounded concepts, individual facts, and explained connections using Sign in with ChatGPT. Open `Knowledge.xcodeproj` in Xcode 27, select the shared `Knowledge` scheme, and run on an iPhone or iPad simulator or device. The library and legacy items remain stored on the device through account switches and sign-out.

## Importing knowledge

Create a subject, such as **AP Psychology**, then choose **Import notes**. V1 accepts searchable PDFs, TXT/Markdown files, and pasted text (up to 25 MB and 300,000 text characters). PDFKit extracts selectable text locally; unreadable or locked PDFs and pages needing OCR produce actionable errors. Imported bytes are copied into Application Support, and passage IDs retain page and section references.

Extraction uses strict Structured Outputs in bounded passage chunks. Concepts and facts carry checked source quotations. Connections reference validated supporting facts and inherit their evidence, avoiding conflicting copies of the same citations. A second pass reconciles compatible repeated concepts, proposes merges with existing concepts in the same subject, and suggests explained connections using supplied facts. Ambiguous internal matches remain separate. Competing theories and qualifications retain their status; source material cannot change the extraction instructions.

The progress screen distinguishes the current batch from completed, validated batches. It shows the source section, elapsed time, ChatGPT request activity, provisional counts, and recently received concept names while the response streams. It then shows evidence validation and checkpoint saving. Previews never count as completed work. A quiet response produces a waiting notice; the app does not invent a percentage for model generation. New imports use at most 24 primary passages and approximately 4,000 source characters per batch. An older draft retains its original boundaries if any batch has already been saved; drafts with no completed work adopt the smaller batches.

If source facts and coverage validate but connection references fail, one targeted repair request can correct only those references using the returned concepts and facts. It retains the original relationship wording. Repaired suggestions remain unchecked with a review flag, and unsupported suggestions remain visible as review notes. Fabricated source quotations and invalid facts cannot enter this repair path. Reconciliation uses schemas constrained to supplied concept and fact IDs within the enum budget; ordinary validation still checks every reference and passage.

When the model marks a passage extracted without actually citing it, the importer marks it uncertain and makes one focused extraction request for the uncited passages. Valid additions are combined with the original facts. Anything that still cannot be validated stays visible with its full source text in the review's passage coverage section; it is never reported as successfully extracted.

Coverage records are reconciled to the source's actual passage IDs and citations, so repeated or omitted bookkeeping rows do not discard otherwise valid content. Conflicting dispositions remain uncertain. Extraction schemas constrain evidence IDs to supplied passages and coverage IDs to the current batch. This preparation does not relax checks on quotation text, fact references, or concept references.

Missing optional merge proposals keep the original source concepts and facts separate, with an import note. Repeated proposals are left unapplied and flagged for review. Unknown merge targets and merge cycles are still rejected.

The editable review shows selected counts, supporting passages, original wording for edits, proposed merges, inferred connections, and excluded or uncertain passages. Source-derived entries are selected by default; inferred connections and review flags require user selection. Selecting a connection includes its supporting concepts and facts. Excluding a concept excludes dependent entries. Saving adds the selected records in one transaction, preserves existing concept names and explanations during merges, and is idempotent for the same draft. A matching quotation establishes provenance, not scientific correctness: the user still reviews the material.

Completed chunks and reconciliation progress are checkpointed in SwiftData. Pausing, backgrounding, or changing the ChatGPT connection stops processing and preserves the draft. Resume explicitly with the selected account and model; completed requests are reused. Model choices come from the active account's catalog, default to its first visible model, and persist per registration. Account settings remain the place to grant plan permission and manage usage.

Concepts, facts, and connections have stable UUIDs. Connections can be browsed from either endpoint, supporting shared functions such as several concepts contributing to attention. Question generation, scheduling, OCR/images, Office files, cloud sync, and a visual graph are future features.

## ChatGPT sign-in

The app uses OpenAI’s dynamic registration flow for local, personal, and open-source apps. It needs no API key, client secret, or pre-issued partner client ID. Identity sign-in and permission to use a ChatGPT plan are separate: declining the optional plan permission still lets the user sign in.

The sign-in screen offers **Continue with ChatGPT** and saved account registrations. Account settings support switching accounts, adding a registration, granting plan permission later, opening ChatGPT usage settings, and signing out. Each registration has a stable label, so accounts with the same email remain distinguishable. The first connection with plan permission shows a dismissible welcome message.

The authentication layer:

- Generates a stable installation host ID and fresh state, nonce, and PKCE values for every authorization attempt.
- Receives the issued client ID on a temporary `http://127.0.0.1:<port>/auth/callback` listener. It retains the registration before token exchange so a later attempt can reuse it.
- Exchanges the code using the issued client ID and verifies ID-token signature, issuer, audience, expiry, and nonce using OpenAI discovery/JWKS and JWTKit 5.
- Stores each registration and its credentials separately in the Keychain, available only while this device is unlocked. Credentials never enter SwiftData or UserDefaults.
- Restores the selected account, serializes refreshes, saves rotating refresh tokens, and attempts remote revocation before clearing the selected account’s local credentials on sign-out.

The plan request client supports model discovery, task-specific instructions, strict JSON schemas, and streaming Responses API requests for concept import. It uses the active account’s refreshed OAuth access token, `GET https://api.openai.com/v1/models`, and `POST https://api.openai.com/v1/responses` with `store: false`, `stream: true`, and array input. It captures returned token counts and handles admission errors, plan eligibility and usage-limit failures, refusals, incomplete/interrupted responses, and cancellation. Account settings link to ChatGPT’s usage settings.

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

Concept-import tests cover native PDF/text preparation, coverage and citation validation, alias reconciliation, shared-function retrieval, checkpoint reuse, ambiguous merges, selection dependencies, transactional rollback, idempotent saving, account cancellation, model preferences, and migration from the original `Item` store. The psychological acceptance fixture is a representative excerpt of the supplied notes; deterministic fixtures test the app's behavior, while live model quality is checked separately.

`ConceptImportLiveProbeTests` is opt-in through `KNOWLEDGE_RUN_LIVE_IMPORT=1` in the test host's environment. It requires an unlocked device with an existing authorized ChatGPT plan connection and makes real requests. For device test-runner issues, a Debug-only launch argument `-knowledge-live-import-probe` exercises the same pipeline directly in the app and writes a count/validation report to `Documents/knowledge-import-probe.json`. Neither probe commits material into the knowledge library. Normal launches and Release builds do not run the diagnostic. `LibraryPreviews.swift` provides isolated library and review previews with no AI requests.

For an explicitly requested repair of an existing import, `-knowledge-resume-import-probe <storedFilename>` resumes only the matching draft through the real coordinator with the account's selected model. It preserves completed batches, records streaming activity and the final outcome in `Documents/knowledge-import-resume-probe.json`, and stops at editable review. It does not press Save or run on normal launches. Streaming and citation regression tests cover provisional progress, truncated responses, evidence derived from facts, and both legacy and compact checkpoints.

**Concept import validation:** 89 automated tests passed on the iOS 27 iPad simulator, including the original-store migration. The signed physical-device build succeeded. The direct live probe completed two Structured Outputs requests through the iPhone's saved ChatGPT connection using the first visible model, GPT-6 Astra: 11 concepts, 13 facts, 6 connections, and coverage for all 15 passages in the psychology excerpt. The probe verified the REM alias, parallel processing, four separately classified dream theories, and the sleep-cycle quantity; schema, references, and evidence validation passed. Library/review previews were checked in light/dark appearance and at the largest Dynamic Type size. Xcode's physical XCTest runner hung before connecting, so the direct in-app probe provided live inference validation.

**Full-document and progress validation (October 6, 2026):** 107 automated tests passed in 13 suites after adding live stream previews, compact/legacy checkpoint compatibility, connection reference repair, uncited passage extraction, citation-based coverage preparation, and safe fallbacks for missing merge proposals. The signed iPhone build succeeded without compiler warnings. The actual uploaded psychology PDF resumed through the saved GPT-5.6 Luna connection and reached editable review: 147 concepts, 182 facts, 145 connections, and coverage dispositions for all 202 passages. The live run exercised the targeted coverage and connection repair paths and preserved the REM/paradoxical-sleep alias, parallel processing, theory classifications, and the sleep-cycle quantity. It stopped at review without saving the material into the library. Progress previews were checked in light/dark appearance and with accessibility text sizes, and live progress was observed on the phone.

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
- [OpenAI streaming responses](https://developers.openai.com/api/docs/guides/streaming-responses)
- [ChatGPT usage settings](https://chatgpt.com/settings/usage)
- [Apple authentication sessions](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
- [Apple local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

The ChatGPT logo asset comes from [OpenAI’s approved sign-in assets](https://developers.openai.com/assets/siwc/sign-in-buttons/chatgpt-logo-black.svg). The integration configuration follows the local/open-source flow; paid or remotely hosted distribution requires the applicable OpenAI access approval.
