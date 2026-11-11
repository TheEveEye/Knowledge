# Knowledge for iOS

Knowledge is an iOS 27 SwiftUI client for an account-owned cloud study library. Open `apps/ios/Knowledge.xcodeproj` from the repository root in Xcode 27 and select the shared **Knowledge** scheme. The repository's deployment target is iOS 27.0.

## Accounts and library ownership

A verified Knowledge email/password account is required. Existing registration, email verification, password recovery, session validation, and device-only Keychain storage remain in place. Apple, Google, and other social login methods are deferred. See [email sign-in](../../docs/Email-Sign-In.md).

The permanent Knowledge user UUID owns subjects, source documents, saved concepts/facts/connections, organization, import drafts, history, Recall questions, sessions, answers, memory state, and model preferences. AI connections are separate permissions. Changing a ChatGPT connection does not change Knowledge ownership.

`KnowledgeApp` opens `CloudAuthenticationRootView`. After Knowledge authentication, `CloudLibraryStore` creates an account-scoped cache directory under `Library/Caches/KnowledgeCloud-v1/<origin-hash>/<user-UUID>/` for pending-operation metadata and downloaded source files. Confirmed display snapshots stay in memory; the app does not create or open a SwiftData container. Obsolete account cache database files are removed with the account directory on sign-out. The old shared library is never opened, converted, or uploaded. Existing development content is intentionally abandoned; existing server accounts remain intact.

Library content becomes available only after a successful server refresh. The client refreshes on sign-in, foregrounding, subject navigation, confirmed changes, and SSE invalidation. SSE reconnects trigger authoritative refetches. A connection failure covers library views and library sheets with retry UI, preserving unsent form input underneath. There is no offline library mode or offline mutation queue.

Library setup uses one `/api/v1/library` request for subjects, draft summaries, preferences, and AI connection metadata. Opening a subject uses one `/api/v1/subjects/:subjectID/snapshot` request for its entries, sources, imports, jobs, decisions, and Recall dashboard. The server reads the subject snapshot in a read-only repeatable-read transaction, so the client does not page through entries or issue a separate version-check request. Recall question banks and source files remain on-demand reads. Existing paginated collection endpoints remain available for other clients.

Subject navigation includes import metadata only. An open import review requests its own unsaved draft with `?importID=...` so server refreshes continue to update that editor; other drafts stay unloaded. Saved imports never include their historical draft body, and worker checkpoints are excluded from import responses and subject snapshot SQL projections. Job reads also project display fields instead of loading worker inputs and checkpoints.

Navigation snapshots exclude internal contribution records. A caller with confirmed entries sends `knownRevisionID`; when it matches the server revision, the response returns `entries: null` with fresh metadata. iOS reuses entries only after matching both subject and revision IDs. Healthy navigation reuses snapshots until invalidation; there is no speculative subject prefetch. Foreground/reconnect and explicit refresh still perform authoritative reads.

Recall home fetches its dashboard and session summaries without loading banks. Concept coverage and session presentation request material metadata with `includeQuestions=false`; the question library explicitly requests banks. Material pages use the existing maximum of 100 records. Subject-scoped invalidation avoids refreshing other subjects, and session-only changes do not invalidate library entries or banks. See [performance investigation](../../docs/API-Performance.md) for measurements, contracts, and verification limits.

Background suspension cancels foreground reads and the event stream silently. Only the current foreground connection may report a connection failure; cancelled or superseded work cannot replace a resumed library with an error. Brief inactive transitions retain the existing connection, and an explicit connection retry shows progress in its button.

Changes use asynchronous `/api/v1` commands and appear saved only after server confirmation. Forms retain their starting resource version, so a refresh cannot silently turn stale input into an overwrite. Uncertain mutations retain operation IDs in account-scoped cache metadata; retries reuse the same ID. Raw uploads use a content fingerprint. The metadata stores no request bodies or provider credentials.

Sign-out cancels URLSession requests and event streams, clears displayed account state and session-only chats, and deletes the account cache directory. Closed clients reject late responses. Server jobs continue across app termination and Knowledge sign-out; Pause, Cancel, and provider disconnection are separate controls.

## Native flows

The cloud client reuses the native account sheet, floating subject/import chat, study cards, topic hierarchy, evidence sheets, file preview, import fields, and Recall session presentation. Account-scoped adapters in `Knowledge/Cloud` issue asynchronous server commands; shared presentation views do not execute device-owned import, assessment, or scheduling work. Draft text stays separate from confirmed data, and conflicts retain input for explicit review.

The library uses a navigation split view with subjects, topics, concepts, facts, connections, evidence, source reading, history, and subject settings. Wording and placement changes are versioned server commands. Manual wording is protected from later import proposals. Import and undo conflicts present explicit current/proposed choices.

PDF, TXT, Markdown, and pasted text are uploaded to the server. Canonical extraction runs on the worker; the iOS client does not extract or execute imports locally. Limits are 25 MiB and 300,000 characters. Source passages preserve page references, and original files are downloaded separately through authenticated requests into the account cache.

Import review supports selection dependencies, concept identity merges, naming suggestions with apply/undo, source evidence, coverage warnings, progress, pause/retry, saving, and draft deletion. Import chat has bounded tools for reading source passages and reversible draft selection, naming, and placement changes. It cannot save or delete the draft or change saved library content. Chat conversations remain session-only.

Reopening an import review attaches its account-scoped in-memory editor before awaiting navigation refresh. While connected, review navigation reuses a confirmed subject snapshot with a matching subject version and invalidation epoch; mutations, server invalidations, and reconnects still require fresh server reads. This reuse lasts only for the current account session and does not enable offline access.

Confirmed draft edits schedule their display refresh independently, so a superseded background read cannot turn a successful edit into a cancellation error or prevent the import save from being queued. The Save button retains inline progress from the tap through acknowledgement and display of its queued/running job. Editors ignore snapshots older than their acknowledged draft version, and account/editor cancellation does not appear as a form error.

Subject chat is read-only and streams through Fastify. It retrieves saved entries, active source passages, and Recall banks/progress as needed. Internal source citations open supporting passages within the current subject. Import drafts are outside subject-chat scope.

Recall preparation and verification run on the worker. Practice is resumable from the server, with six native answer controls: text, choice, number, slider, ordering, and matching. Answers are persisted before assessment. Follow-up feedback stays hidden until assessment completes. Reconsideration distinguishes the initial answer from the whole conversation. Reviews, integrated participants, independently verified extra credit, schedules, and session advancement commit together. Undo restores the whole review group when no later target change prevents it. Objective controls use deterministic server grading from their verified keys. The backend computes FSRS memory and proficiency; the client displays its results. An explicit Finish session action releases changed or excluded material without discarding saved answers.

“I don't know” reveals the prepared answer immediately while the deterministic result saves on the server. Session reads preload the remaining prepared questions, accounting for integrated targets and context disclosures without recording exposure. The pinned Next question button presents the preloaded question immediately while the previous result commits on the server. The next answer can be drafted during that save; submission waits for confirmation, with progress inline in Submit. Failed saves retain the preview and draft for an idempotent retry. Confirmation preserves the draft only when its target, question, input, and turn still match; conflicting changes retain it for explicit review. Skips and sessions without a preload use confirmed server advancement. Session commands retain the current presentation rather than entering grading mode. Answer and assessment responses include the current session presentation, removing the follow-up session fetch after each request. Clients fall back to those reads on older servers. Other confirmed commands refresh the session separately from the library dashboard; a retry after a failed session read repeats only the read. Existing displayed material is reused when it can present the server's confirmed questions.

Question answers can be revealed from the bank, with a server-recorded exposure cooldown. Exclusion/restoration and regeneration use server commands. Sources become available after assessment. Reset learning progress preserves library content, prepared banks, and append-only history while clearing current memory and ending sessions.

## AI funding

Account settings retain the ChatGPT connection list and default-model controls for importing, chat, Recall preparation, and assessment. Explicit connection/funding choices apply across those roles; each role retains its own model and reasoning. Changes are saved only after server confirmation. The server captures the selected funding and never switches to API spending after a ChatGPT failure. Blocked jobs offer a separately labeled retry action when you explicitly choose another connection or allowance. Default importing/chat use GPT-6 Luna with model-default reasoning; preparation uses Luna/Medium and assessment Terra/Medium.

Personal self-hosted ChatGPT authorization starts locally and explicitly transfers the resulting renewable grant to the Pi. After confirmed handoff the device relinquishes local refresh ownership. The Pi encrypts credentials and serializes refresh across API and worker. Knowledge credentials remain in their separate device-only Keychain service. Server API access is optional and requires an explicit configured allowance.

API-funded Recall assessment and optional extra-credit verification request Fast mode (`service_tier: "fast"`), which uses premium API pricing. The backend logs the service tier returned by OpenAI so a fallback to Standard is visible. ChatGPT-funded requests, imports, preparation, chat, and explanations keep their existing service tier. Grading model and reasoning settings are unchanged.

Import extraction, Recall preparation, assessment, and scheduling execute on the server. The iOS app retains the native presentation and draft editing code; the former device execution, persistence, and request queue implementations have been removed. Presentation preferences remain local.

## Subject voice chat

The subject chat's empty composer action starts GPT-Live through a waveform button; typed messages retain Send and running text requests retain Stop. While voice is active, the empty composer action ends voice. The existing toolbar and background gestures still close chat. Import chat keeps its original controls. The standalone demo has been removed.

GPT-Live handles duplex audio through a nonpersistent WebKit transport and sends user/assistant transcripts into the native chat message UI. Captions use independent speaker streams and approximate timestamps. Typed and spoken conversation context carries across modes. Starting voice requests microphone permission; ending voice, closing chat, losing the Knowledge connection, backgrounding or signing out stops capture/playback and cancels lookups. Sending a typed message also ends voice. No automatic reconnect creates another billable session.

Voice captures the selected chat funding/connection and backend model when started. The fixed `gpt-live-1` voice session uses that credential without funding fallback. GPT-Live client delegation runs the existing read-only subject chat backend, using its subject-scoped search, passages and Recall tools with the captured chat selection. The server checks subject ownership for both session creation and each lookup. Backend results are returned to the voice session in bounded appends; spoken output, rather than hidden backend text, appears as the assistant transcript. Speech recognition or late captions can affect lookup context; this implementation has not been verified on-device.

Voice lookups preload bounded actual passage excerpts, using ranked keyword matches or a small sample from each saved source for broad questions. Tool retrieval remains available for further reading. Only the final grounded answer is handed back, without accumulated tool-loop commentary or native truncation. Transport chunks are appended as silent context before one request to speak the complete result. Retrieval diagnostics record only source/passage counts, character counts, tool names and error codes, never source text or learner speech.

Deploy both app and API. API funding needs the existing server OpenAI secret and positive request allowance; ChatGPT-funded Live remains experimental and previously returned `401/no_matching_rule`. Each API-funded handshake and lookup request consumes the existing request-count allowance, which is not a dollar or minutes budget. Voice duration and model usage are billed separately by OpenAI. Knowledge records handshake status, keeps transcripts only in the current chat session, and never sends credentials into JavaScript or logs SDP/transcripts.

## Build and review

Use an iOS build and static review only, following [AGENTS.md](../../AGENTS.md). Do not add or run automated tests, fixtures, harnesses, or manual testing.

See [cloud library](../../docs/Cloud-Library.md), [backend deployment](../../docs/Backend-Deployment.md), [Recall question design](../../docs/Recall-Question-System.md), and [grading policy](../../docs/Recall-Grading-Instructions.md). A successful build establishes compilation; it does not establish runtime behavior or provider approval.
