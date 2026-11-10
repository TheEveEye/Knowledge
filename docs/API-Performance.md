# API and iOS performance — 2026-11-09

The backend changes were deployed on 2026-11-09 in release `20261109T173401Z-8544fbffd10a`; the updated iOS client has not been installed. Source changes remain uncommitted. The earlier consolidated endpoints and checkpoint/draft payload fix were already deployed and installed before this work. No new migrations, database volumes, credentials, worker recovery state, or AI funding settings were introduced or changed. No AI work was triggered by the investigation.

## Evidence

Read-only production logs, aggregate PostgreSQL queries, a query plan, and in-memory response reconstruction were used. Private content, account identifiers, and credentials were not printed. Sizes below are bytes, not database on-disk sizes or phone transfer measurements.

| Measurement | Before | After |
| --- | ---: | ---: |
| Normal subject JSON, same stored subject | 2,008,897 | 932,437 |
| Subject JSON when the caller already has the current revision | 2,008,897 | 86,386 |
| Gzip level 1, reduced normal subject JSON | — | 186,152 |
| Gzip level 1, unchanged-revision JSON | — | 26,965 |
| Recall dashboard material snapshot projection, PostgreSQL JSON text | 1,272,208 | 90,800 |
| Unused question-bank JSON in dashboard target rows | 3,501,415 | 0 |
| Recall dashboard reconstruction on Pi, three observations | 108.1 / 101.4 / 116.2 ms | 44.4 / 36.1 / 32.7 ms |

The normal subject reduction excludes 881 contribution records, retaining 1,233 display entries. Contributions remain stored and accessible through explicit entry/history reads. Their original wording and evidence duplicate fields already present on the entities used by iOS.

The dashboard comparison evaluated the deployed service and the locally compiled replacement in memory, inside read-only repeatable-read transactions on the Pi. Invocation order alternated; the replacement received the already-owned subject. Both produced 58,831 bytes of dashboard JSON in these observations. These are targeted server reconstructions, not production request or phone timings. The replacement's dashboard path without preloaded entries took 45.8 / 49.5 / 40.2 ms.

The baseline complete reconstruction took 262.3 / 142.2 / 151.0 ms. Serializing the full baseline took 23.2 / 24.0 / 21.1 ms; serializing the response without contributions took 12.5 / 13.8 / 10.3 ms. These serialization observations used the same in-memory response. They do not measure the complete new endpoint's duration.

On the Pi, Node gzip level 1 compressed the reduced normal JSON in 8.5 / 7.1 / 6.7 ms. Level 6 produced 160,724 bytes in 14.1 / 13.8 / 13.9 ms. Level 1 was selected to limit CPU work. Caddy's Go implementation and real streaming/edge transfer time were not benchmarked. Caddy now negotiates gzip for JSON of at least 1,024 bytes; SSE and source downloads are excluded by content type. See the [Caddy encode documentation](https://caddyserver.com/docs/caddyfile/directives/encode).

Existing production request logs showed subject snapshots at 157–209 ms, Recall dashboards at 113–206 ms, and repeated sequences of roughly eleven material page requests on Recall visits. Those are logged server request durations. Phone transfer, decoding, caching, first usable frame, and rendering latency were not measured.

The filtered entry query took 1.436 ms, used 300 shared buffer hits, and sorted about 1 MB without spilling. PostgreSQL chose a sequential scan for the small current dataset. Existing ownership/subject/cursor indexes cover the query families inspected; the evidence did not justify adding an index or increasing the five-connection process pool. No immutable migration was edited.

## Routes and callers reviewed

| Route family | Actual caller / resulting work |
| --- | --- |
| `/api/status`, `/api/ready`, `/api/me`, account/auth routes | Operational readiness and account restoration; no study payload or auth-policy changes. |
| `/library`, `/subjects`, preferences, AI connections | Library bootstrap and settings. Concurrent bootstrap requests join one client read. The existing four bounded server branches and pool limit remain. Preferences/connection events no longer invalidate every subject. Connection identity display still needs the encrypted identity token server-side; credentials remain absent from responses. |
| Subject `/snapshot` | Navigation, foreground, reconnect, mutation refresh. Full display entries on first read; `knownRevisionID` permits `entries: null` only if it equals the owned subject revision in the same transaction. Sources, import metadata, jobs, decisions, and dashboard remain current. A changed revision returns entries. |
| Subject/entry/placement mutations and entry collections/detail | iOS edit/move actions and retained paginated APIs. Mutations still use server versions, operation receipts, and original transaction behavior. Explicit entry APIs retain contribution access. |
| Sources, passages, download/upload | Source detail, evidence, downloads, imports, and chat tools. Original bytes remain separate authenticated streams. Source review notes project only `draft.reviewNotes`, avoiding historical draft bodies. |
| Imports, import edits/chat/save/recheck/discard | Sidebar summaries and open review. Display list/detail queries exclude checkpoints in SQL and suppress saved drafts in SQL; chat's pre-stream ownership check projects ID only. Internal worker `get` remains unchanged. Open review's unsaved draft, version reconciliation, local edits, and direct-draft race protection remain. |
| Jobs and job control | Progress/troubleshooting rows, versioned pause/resume/retry/cancel. Shared display projection fetches only source ID from input plus display fields; worker checkpoints/input/leases stay in storage. Control code still reads full worker state where required. |
| Subject history list/detail/undo | History and conflict review. Lists exclude manifests and changes in SQL; revision detail retains changes. Detail's undo-job query fetches display columns only. |
| Recall dashboard | Subject snapshot and Recall home/topic. Fetches only concept/relationship/policy metadata and target scheduling fields, omitting evidence and duplicated question banks. Reuses owned subjects/entries within snapshots and records within topic scope. Learning-event projection keeps only scoring fields; maps replace repeated event/target/material scans. |
| Recall materials | Concept coverage and session presentation request `includeQuestions=false`; banks remain the default for compatibility and the explicit question-library request. Target rows project only the issue field from bank data. iOS pages at 100 instead of 50. |
| Recall session list/detail and commands | Home/history lists need ID, subject, version, finished flag, update date, and `state.topicID`; SQL projects that state only. Session detail still returns the full presentation. Answer/edit/assessment/explanation/unknown/finish events refresh session surfaces without full-subject invalidation; report/advance/undo still invalidate Recall data. |
| AI model catalog/handoff/disconnect/usage and operation/status routes | Settings, explicit controls, and recovery. No provider call or paid inference was made for investigation. Existing ownership, origin, cancellation, spending, and idempotency rules remain. |
| `/events` | SSE still starts with a full invalidation to close the bootstrap-to-stream race, polls with its existing bounds, and rechecks sessions. Subject events invalidate that subject; job/import progress does not discard Recall banks. Refresh bursts queue a follow-up instead of repeatedly restarting a running scheduled refresh. |

## iOS work removed

Successful HTTP responses previously decoded their entire body into dynamic JSON on the main actor during response acceptance, then decoded again through `CloudCoding`. Successful acceptance now handles headers/status only; the body is decoded once on the concurrent executor. Error-body handling and session renewal remain.

Every subject read also encoded all entries again and fetched/upserted/deleted/saved SwiftData cache records on the main actor before returning the snapshot. Static reference review found no consumers of those records. Those writes and their encoding pass are removed. The subsequent cleanup also removes the unused cache schema/container; no study data migration is needed. The account-scoped directory still holds pending-operation metadata and downloaded files and is purged on sign-out, including any obsolete cache database files. No offline access was added.

Speculative downloads of every other subject are removed. Confirmed in-memory snapshots are reused while connected until invalidated, rather than expiring after two seconds. Reconnect/foreground and explicit refresh retain fresh server reads. Revision-confirmed metadata responses reuse the existing entries array without publishing it again to SwiftUI. Question banks no longer block subject refreshes after a Recall screen has once been opened.

## Validation and remaining work

Node.js 24.22.2 workspace build and typecheck passed for contracts, backend, API, and worker. The Knowledge Debug simulator build passed with Xcode 27.2, deployment target iOS 27.0. Caddy accepted the proposed configuration with its installed production binary in a separate validation process; the running configuration was not reloaded. Diff whitespace checks passed. No automated tests, fixtures, harnesses, manual app/API testing, or live model generations were run.

The remaining first-open subject contains about 0.93 MB of JSON before compression. Material metadata still loads the subject's material collection, and the full bank remains a large on-demand response. Topic hierarchy aggregation, session-detail duplication, and provider latency remain possible costs. Neither phone-side CPU/rendering nor end-to-end network latency has been profiled, so no phone speedup is claimed.

The backend must precede the new client because the previous snapshot route rejects `knownRevisionID`. That backend rollout is now complete. An isolated checkout included exactly the six intended backend/infrastructure file changes: API routes, imports, jobs, library, Recall, and Caddy. The unrelated semantic processing/documentation edits and additional Recall UI edits were excluded and preserved locally. The deployed semantic file's SHA-256 matches committed HEAD. No commit was created.

The deployment built contracts/backend/API/worker with Node 24 on the Pi, created a 5.5 MB database/source backup before running the existing migration command, retained the previous release for rollback, and left PostgreSQL's existing container and volumes in place. API and worker health checks passed; public `/api/status` reports revision `e492a4184285-dirty-8544fbffd10a`, and `/api/ready` returns ready. Caddy is running the deployed configuration, and the public gateway responds successfully. No manual app/API feature testing or phone installation was performed.

The navigation description in `docs/Cloud-Library.md` now matches this report and the iOS README.
