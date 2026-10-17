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

Saved concepts are automatically organized into a subject-wide topic outline, with at most three topic levels. Organization starts after saving an import and when opening a subject with concepts that have no placement yet. It uses the selected ChatGPT model, or the account's saved/default model. A bounded outline request uses concept summaries and source headings; subsequent requests place up to 25 concepts at a time. Topics are browsing headings and do not change source-grounded concepts, facts, or knowledge connections.

The library shows collapsible topics with descendant concept counts and remembers expanded branches per subject. Search includes aliases and topic paths. Uncertain placements remain visible under Unsorted. Use the Organize menu to organize new concepts, reconsider unlocked placements with Reorganize subject, or collapse the tree. Long-press a topic to rename it. Move a concept from its detail screen, context menu, or leading swipe; manual moves lock its placement until unlocked. Existing topic names and parents remain stable during automatic runs. The entire organization result is validated and saved together; interrupted requests, invalid output, and library changes during a request leave the previous structure intact. Existing stores gain the two organization models through additive migration.

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


## Build

JWTKit and its transitive dependencies are resolved through Swift Package Manager.

```sh
xcodebuild build -project Knowledge.xcodeproj -scheme Knowledge -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

This project has no test target or test harnesses. Follow the no-tests policy in `AGENTS.md`.
