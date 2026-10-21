# Knowledge

An iOS 27 SwiftUI app that turns study notes into source-grounded concepts, individual facts, and explained connections using Sign in with ChatGPT. Open `Knowledge.xcodeproj` in Xcode 27, select the shared `Knowledge` scheme, and run on an iPhone or iPad simulator or device. The library remains stored on the device through account switches and sign-out.

This app is unreleased and supports only its current data schema and import checkpoint format. There are no upgrade paths for previous development builds; recreate local development data when the format changes.

## Importing knowledge

Create a subject, such as **AP Psychology**, then choose **Import notes**. V1 accepts searchable PDFs, TXT/Markdown files, and pasted text (up to 25 MB and 300,000 text characters). PDFKit extracts selectable text locally; unreadable or locked PDFs and pages needing OCR produce actionable errors. Imported bytes are copied into Application Support, and passage IDs retain page and section references.

Extraction uses strict Structured Outputs in bounded passage chunks. Concepts and facts carry checked source quotations. Connections reference validated supporting facts and inherit their evidence, avoiding conflicting copies of the same citations. A second pass reconciles compatible repeated concepts, proposes merges with existing concepts in the same subject, and suggests explained connections using supplied facts. Ambiguous internal matches remain separate. Competing theories and qualifications retain their status; source material cannot change the extraction instructions.

The progress screen has a compact header with a readable document title, a plain-language stage, and one progress indicator. A document overview appears immediately from the prepared source, before any model response. It uses recognized headings in document order, or up to six page ranges or numbered parts when headings are unavailable. The first six sections are visible; further sections expand on demand. Each section shows whether it is waiting, being read or checked, checked, paused, or needs attention or review. Status reflects all batches responsible for that section's passages, excluding overlapping context passages. Up to three distinct concept names appear under each section as complete streamed entries arrive; provisional examples are identified as still being checked, and rejected previews are removed. Cards stay in place with no automatic scrolling, definitions, or facts. Connection previews replace the document overview during discovery and remain available while topics are organized. The completed topic overview leads into grouped review. These waiting-screen previews do not add model requests.

Imported concepts are organized before other unsorted library material. Indeterminate progress sits beside the stage text, including during topic organization; measured progress bars reflect completed work within the current stage. The information button opens Import details for the original title, model, elapsed time, and individual batch activity. Running concept, fact, and connection totals stay out of the progress header; selected totals appear during review. Review opens with collapsed topic groups, example concepts, and review flags, with definitions, facts, editing, and source evidence inside each concept. Connections are also collapsed initially. At accessibility text sizes the summary scrolls with the content. Errors remain visible with access to details. Imports use at most 24 primary passages and approximately 4,000 source characters per batch.

If source facts and coverage validate but connection references fail, one targeted repair request can correct only those references using the returned concepts and facts. It retains the original relationship wording. Repaired suggestions remain unchecked with a review flag, and unsupported suggestions remain visible as review notes. Fabricated source quotations and invalid facts cannot enter this repair path. Reconciliation uses schemas constrained to supplied concept and fact IDs within the enum budget; ordinary validation still checks every reference and passage.

When the model marks a passage extracted without actually citing it, the importer marks it uncertain and makes one focused extraction request for the uncited passages. Valid additions are combined with the original facts. Anything that still cannot be validated stays visible with its full source text in the review's passage coverage section; it is never reported as successfully extracted.

Coverage records are reconciled to the source's actual passage IDs and citations, so repeated or omitted bookkeeping rows do not discard otherwise valid content. Conflicting dispositions remain uncertain. Extraction schemas constrain evidence IDs to supplied passages and coverage IDs to the current batch. This preparation does not relax checks on quotation text, fact references, or concept references.

Missing optional merge proposals keep the original source concepts and facts separate, with an import note. Repeated proposals are left unapplied and flagged for review. Unknown merge targets and merge cycles are still rejected.

During connection discovery, the waiting screen shows up to three ideas currently being explored and connection previews from completed reconciliation batches. Suggestions are labeled separately from source-derived connections, and entries with review flags, flagged supporting facts, missing endpoints, or identical displayed endpoints are omitted from this preview. Up to six cards appear initially, with the rest available through a disclosure group. Progress restores these previews from checkpointed results after reopening. There are no extra model requests, speculative streamed connections, or automatic scrolling.

The editable review shows selected counts, supporting passages, original wording for edits, proposed merges, inferred connections, and excluded or uncertain passages. Source-derived entries are selected by default; inferred connections and review flags require user selection. Selecting a connection includes its supporting concepts and facts. Excluding a concept excludes dependent entries. Saving integrates the selected records and supported updates with the latest subject in one transaction and is idempotent for the same draft. Changes to protected wording or organization require a specific choice before any part of the import is committed. A matching quotation establishes provenance, not scientific correctness: the user still reviews the material.

Extraction and reconciliation share a source-fidelity policy: faithful claims are accepted even when the notes are simplified or omit mechanisms, limitations, qualifications, or supporting studies. Review flags are reserved for ambiguous interpretation or identity, unsupported additions or strengthened wording, contradictions in supplied material, and invalid or missing evidence. Existing uncertainty, conditions, quantities, and theory status must be preserved. These stages do not fact-check source claims against outside knowledge or invent missing qualifications.

After reconciliation, ambiguous concepts and concepts with flagged facts receive a bounded AI naming/classification pass. It first supplies cited passages and neighboring context, then permits explicitly unverified general-knowledge suggestions. It cannot rewrite facts, explanations, evidence, connections, merge targets, or inclusion decisions. Note-context suggestions require matching original quotations containing the proposed wording; these checks establish provenance, not correctness or the author's intended meaning. No external lookup is performed and suggestions cannot claim external verification. Ambiguous or unsupported interpretations stay unresolved. Review offers Apply, Undo, and Dismiss while retaining original wording and review flags. Accepted classifications remain browsing suggestions rather than automatic topic assignments. Accepted suggestions and their model, rationale, basis, and source context survive saving; the library displays this provenance and can undo the suggestion while preserving later edits and existing merged concept names. Later reconciliation requests receive the naming provenance so an inferred name is not treated as independent evidence for a merge or connection.

Resolution progress and request usage are checkpointed after each group of up to four concepts. Pause/resume reuses completed groups, and optional suggestion failures retain the original entries with an import note. Drafts without applicable entries make no additional requests.

Completed chunks and reconciliation progress are checkpointed in SwiftData. Pausing, backgrounding, or changing the ChatGPT connection stops processing and preserves the draft. Resume explicitly with the selected account and model; completed requests are reused. Model choices come from the active account's catalog, default to its first visible model, and persist per registration. Account settings remain the place to grant plan permission and manage usage.

The import and review screens use a native confirmation dialog anchored to the back button, with Discard Draft and Keep Draft. Keeping a draft returns to the subject while an active import continues, or preserves review edits before closing. The Pause button explicitly stops processing, and entering the background still pauses active imports. Discarding stops processing and removes the draft and its unshared source copy.

Concepts, facts, and connections have stable UUIDs. Connections can be browsed from either endpoint, supporting shared functions such as several concepts contributing to attention. Question generation, scheduling, OCR/images, Office files, cloud sync, and a visual graph are future features.

Concepts are organized into a subject-wide topic outline during import, after extraction and reconciliation and before review. The import uses its selected ChatGPT model to prepare at most three topic levels from concept summaries and source headings, then place up to 25 concepts at a time. The completed topic plan is checkpointed with the draft, so resuming a completed grouping stage does not repeat it. Topics are browsing headings and do not change source-grounded concepts, facts, or knowledge connections.

The library displays the saved hierarchy immediately; opening a subject does not start model requests. Topic paths are visible during review. Saving commits the selected concepts, facts, connections, topics, and placements together, resolves accepted combinations, and omits new branches used only by deselected concepts. Existing assignments are preserved unless an explicit supported update changes them; locked placements and edited fields require approval. Concepts without a placement and unlocked Unsorted concepts can be grouped during a future import.

The library shows collapsible topics with descendant concept counts and remembers expanded branches per subject. Search includes aliases and topic paths. Uncertain placements remain visible under Unsorted. The subject menu expands or collapses the topic tree and opens History. Long-press a topic to rename it. Move a concept from its detail screen, context menu, or leading swipe; manual moves lock its placement until unlocked.

## Saving overlapping drafts and history

Each new draft keeps an immutable subject base, reused by extraction, reconciliation, organization, and resume. Reconciliation and organization may propose supported updates to existing entries, alongside additions. Original extracted wordings, quotations, selections, rejected suggestions, and passage acknowledgements remain available independently of canonical library wording.

Save shows **Updating your subject…**. If nothing relevant changed since preparation, it applies the prepared changes without another model request. Otherwise compatible additions and independent field changes combine locally. Only affected groups with potential semantic overlap go to the selected model. Topic matching considers contained concepts and parent context, rather than names alone. Equivalent identities are resolved as groups before remapping facts, connections, topics, placements, and contributions. Uncertain matches stay separate; contradictory sourced claims retain their wording, conditions, and attribution. There is no external fact-checking or unrelated library cleanup.

A proposed replacement of edited wording or locked organization opens **Review changes**, with the affected item, the reason, sources, and relevant choices. Related identity combinations appear as one decision. Choices are saved before the import can proceed. The entire import remains uncommitted until consequential decisions are resolved. Supported AI suggestions cannot write directly to the database; references, quotations, topic structure, protected fields, and the exclusion of unselected entries are validated first.

Subject updates use immutable entity versions and revision manifests alongside the materialized SwiftData library. Unchanged versions are reused, and source documents are stored independently. Contribution records retain each import's evidence and original wording. Retired identities keep redirects for historical references and older drafts. Manual changes to wording, topic organization, placement locks, and saved naming suggestions go through the same revision writer. Field ownership is tracked individually.

Import saves and undo operations are serialized per subject. A final subject-revision and draft-version check, materialization, evidence contributions, history record, and saved-job status share one synchronous database save. No model request runs inside that transaction. Immutable merge preparation, model-response application, checkpoint encoding, and commit serialization run off the UI actor. Concurrent subject changes trigger another reconciliation against the latest subject; unchanged decisions are retained. After three continuing changes, the draft keeps progress and offers Retry. Closing the import screen keeps foreground work alive; account changes, cancellation, backgrounding, and request failures leave the draft and saved library intact.

**History** lists imports, manual changes, and undo operations with source titles, dates, brief summaries, before/after details, and evidence on demand. **Undo import** is available for tracked imports. Undo builds an inverse from the changes actually committed, preserves later edits, later source contributions, and dependent entries, and creates a new history entry. It does not restore an old snapshot or delete original source material. Repeated Save and Undo actions are idempotent. Any required undo decision uses the same review flow, with no partially applied changes. Redo, timeline restoration, and undoing manual history entries are outside this implementation.

Subjects receive an initial revision when created, and each draft requires an immutable base revision. Permanent subject deletion remains a separate destructive action.

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
