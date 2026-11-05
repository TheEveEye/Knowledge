# Knowledge for iOS

Knowledge is an iOS 27 SwiftUI client for an account-owned cloud study library. Open `apps/ios/Knowledge.xcodeproj` from the repository root in Xcode 27 and select the shared **Knowledge** scheme. The repository's deployment target is iOS 27.0.

## Accounts and library ownership

A verified Knowledge email/password account is required. Existing registration, email verification, password recovery, session validation, and device-only Keychain storage remain in place. Apple, Google, and other social login methods are deferred. See [email sign-in](../../docs/Email-Sign-In.md).

The permanent Knowledge user UUID owns subjects, source documents, saved concepts/facts/connections, organization, import drafts, history, Recall questions, sessions, answers, memory state, and model preferences. AI connections are separate permissions. Changing a ChatGPT connection does not change Knowledge ownership.

`KnowledgeApp` opens `CloudAuthenticationRootView`. After Knowledge authentication, `CloudLibraryStore` creates a new SwiftData display cache under `Library/Caches/KnowledgeCloud-v1/<origin-hash>/<user-UUID>/`. The old shared library is never opened, converted, or uploaded. Existing development content is intentionally abandoned; existing server accounts remain intact.

Library content becomes available only after a successful server refresh. The client refreshes on sign-in, foregrounding, subject navigation, confirmed changes, and SSE invalidation. SSE reconnects trigger authoritative refetches. A connection failure covers library views and library sheets with retry UI, preserving unsent form input underneath. There is no offline library mode or offline mutation queue.

Background suspension cancels foreground reads and the event stream silently. Only the current foreground connection may report a connection failure; cancelled or superseded work cannot replace a resumed library with an error. Brief inactive transitions retain the existing connection, and an explicit connection retry shows progress in its button.

Changes use asynchronous `/api/v1` commands and appear saved only after server confirmation. Forms retain their starting resource version, so a refresh cannot silently turn stale input into an overwrite. Uncertain mutations retain operation IDs in account-scoped cache metadata; retries reuse the same ID. Raw uploads use a content fingerprint. The metadata stores no request bodies or provider credentials.

Sign-out cancels URLSession requests and event streams, clears displayed account state and session-only chats, deletes cached records/files, and discards the account container. Closed clients reject late responses. Server jobs continue across app termination and Knowledge sign-out; Pause, Cancel, and provider disconnection are separate controls.

## Native flows

The cloud client reuses the native account sheet, floating subject/import chat, study cards, topic hierarchy, evidence sheets, file preview, import fields, and Recall session presentation. Account-scoped adapters in `Knowledge/Cloud` issue asynchronous server commands; shared presentation views do not execute device-owned import, assessment, or scheduling work. Draft text stays separate from confirmed data, and conflicts retain input for explicit review.

The library uses a navigation split view with subjects, topics, concepts, facts, connections, evidence, source reading, history, and subject settings. Wording and placement changes are versioned server commands. Manual wording is protected from later import proposals. Import and undo conflicts present explicit current/proposed choices.

PDF, TXT, Markdown, and pasted text are uploaded to the server. Canonical extraction runs on the worker; the iOS client does not extract or execute imports locally. Limits are 25 MiB and 300,000 characters. Source passages preserve page references, and original files are downloaded separately through authenticated requests into the account cache.

Import review supports selection dependencies, concept identity merges, naming suggestions with apply/undo, source evidence, coverage warnings, progress, pause/retry, saving, and draft deletion. Import chat has bounded tools for reading source passages and reversible draft selection, naming, and placement changes. It cannot save or delete the draft or change saved library content. Chat conversations remain session-only.

Reopening an import review attaches its account-scoped in-memory editor before awaiting navigation refresh. While connected, review navigation reuses a confirmed subject snapshot with a matching subject version and invalidation epoch; mutations, server invalidations, and reconnects still require fresh server reads. This reuse lasts only for the current account session and does not enable offline access.

Confirmed draft edits schedule their display refresh independently, so a superseded background read cannot turn a successful edit into a cancellation error or prevent the import save from being queued. The Save button retains inline progress from the tap through acknowledgement and display of its queued/running job. Editors ignore snapshots older than their acknowledged draft version, and account/editor cancellation does not appear as a form error.

Subject chat is read-only and streams through Fastify. It retrieves saved entries, active source passages, and Recall banks/progress as needed. Internal source citations open supporting passages within the current subject. Import drafts are outside subject-chat scope.

Recall preparation and verification run on the worker. Practice is resumable from the server, with six native answer controls: text, choice, number, slider, ordering, and matching. Answers are persisted before assessment. Follow-up feedback stays hidden until assessment completes. Reconsideration distinguishes the initial answer from the whole conversation. Reviews, integrated participants, independently verified extra credit, schedules, and session advancement commit together. Undo restores the whole review group when no later target change prevents it. Objective controls use deterministic server grading from their verified keys. The backend computes FSRS memory and proficiency; the client displays its results. An explicit Finish session action releases changed or excluded material without discarding saved answers.

“I don't know” reveals the prepared answer immediately while the deterministic result saves on the server. Advancing still requires confirmation, with progress in the Next question row. Session commands retain the current presentation rather than entering grading mode. Confirmed commands refresh the session separately from the library dashboard; a retry after a failed session read repeats only the read. Existing displayed material is reused when it can present the server's confirmed question.

Question answers can be revealed from the bank, with a server-recorded exposure cooldown. Exclusion/restoration and regeneration use server commands. Sources become available after assessment. Reset learning progress preserves library content, prepared banks, and append-only history while clearing current memory and ending sessions.

## AI funding

Account settings retain the ChatGPT connection list and default-model controls for importing, chat, Recall preparation, and assessment. Explicit connection/funding choices apply across those roles; each role retains its own model and reasoning. Changes are saved only after server confirmation. The server captures the selected funding and never switches to API spending after a ChatGPT failure. Blocked jobs offer a separately labeled retry action when you explicitly choose another connection or allowance. Default importing/chat use GPT-6 Luna with model-default reasoning; preparation uses Luna/Medium and assessment Terra/Medium.

Personal self-hosted ChatGPT authorization starts locally and explicitly transfers the resulting renewable grant to the Pi. After confirmed handoff the device relinquishes local refresh ownership. The Pi encrypts credentials and serializes refresh across API and worker. Knowledge credentials remain in their separate device-only Keychain service. Server API access is optional and requires an explicit configured allowance.

Import extraction, Recall preparation, assessment, and scheduling execute on the server. The iOS app retains the native presentation and draft editing code; the former device execution, persistence, and request queue implementations have been removed. Presentation preferences remain local.

## Build and review

Use an iOS build and static review only, following [AGENTS.md](../../AGENTS.md). Do not add or run automated tests, fixtures, harnesses, or manual testing.

See [cloud library](../../docs/Cloud-Library.md), [backend deployment](../../docs/Backend-Deployment.md), [Recall question design](../../docs/Recall-Question-System.md), and [grading policy](../../docs/Recall-Grading-Instructions.md). A successful build establishes compilation; it does not establish runtime behavior or provider approval.
