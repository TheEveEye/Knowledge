# Recall Lab

A private local CLI for simulated learner interactions, independent review and bounded prompt refinement. It uses the official Codex app-server and ChatGPT login, with no API-key fallback or paid-credit purchases. Knowledge account identity is unrelated to this development tool's AI connection.

## Run

Requirements: macOS, Node.js 24, Codex CLI supporting app-server, Python with pypdf for PDF ingestion. `run` locates Node 24 in Homebrew or the bundled Codex runtime; `RECALL_NODE_BIN` overrides its executable. `--codex` overrides the Codex executable.

```sh
apps/recall-lab/run login
apps/recall-lab/run status
apps/recall-lab/run init --notes '/absolute/path/to/notes.pdf'
apps/recall-lab/run once --small
apps/recall-lab/run schedule
apps/recall-lab/run report
apps/recall-lab/run stop
```

Initial private state is `.recall-lab/`, ignored by Git and restricted to the current user. Scheduling moves it to `~/.local/share/knowledge-recall-lab/runs/` and leaves a local symlink for the same commands. A private runtime and frozen backend policy data keep launchd away from macOS-protected Desktop files. `--data` chooses a separate run directory. `init` refuses to replace an existing run. PDFs are extracted locally; source excerpts are sent to the selected models during the authorized run. Notes and content traces must not be committed or uploaded as public artifacts.

Login opens the official browser flow and uses Codex's credential management. The tool does not copy, parse, export or log credentials. Existing ChatGPT login is reused. `status` prints only allowance windows. Account reset credits are never redeemed. Models must be present in the signed-in catalog and support Medium; there is no silent substitution. Defaults: Luna for preparation; Terra for assessment; Sol 6.1 for simulated learners, independent reviewers and refinement.

## Two-window budget

Initialization reads the reported 300-minute quota window. The hard deadline is its next reset plus five hours. The run can wait for the remainder of the current window and resume once after its reset, with a one-minute margin and fresh limit checks before every model request. A weekly or other blocking limit is respected; the run stops if it would require resuming beyond the deadline. The second exhausted allowance ends the run. Independent safety bounds are 100 rounds and 3,000 completed cached calls. These are ceilings, not promises that every available token will be spent.

`launchd` checks once per minute. It does not call models while waiting. Completed, stopped or blocked jobs unload themselves on the next check. Scheduling prevents idle system sleep until the fixed deadline using a bounded caffeinate process. Closing the lid, powering off or going offline can still delay work. Explicit stop also ends that idle-sleep assertion. In-flight turns are interrupted at the hard deadline. `stop` records a stop request and interrupts the active runner. Calls checkpoint atomically, and unchanged successful requests are reused. An interrupted request can consume allowance without producing a reusable result; the tool cannot guarantee exactly-once remote execution.

## Method

The tool reads the five canonical fixed instruction bodies from the production [backend policy data](../../packages/backend/src/policies.json), joining each prompt's line array with newline characters exactly as the backend does. Applying a candidate updates only those five arrays through JSON parsing and serialization. A source hash freezes each run. Foreground runs block if canonical sources change; scheduled runs use the frozen private source snapshot, so app edits cannot silently mix into the experiment. Explicit apply still checks the real app source hashes. Runs initialized against the former TypeScript policy map require a new baseline; their private state is preserved, and their candidates cannot silently overwrite the new source format. The tool extracts up to three source-grounded claims per module and independently checks question preparation with compatible structured contracts. Exact evidence references, source-backed eligibility review and full essential coverage gates are retained at the prompt level.

Each development round samples two modules, rotating the extraction focus and response variation on subsequent corpus passes, up to two questions each, with six learner profiles: concise correct, paraphrased correct, partial knowledge, mistaken belief, ambiguous wording and verbose supplemental detail. The learner sees source memory and visible questions/controls, never hidden criteria or keys. An independent oracle records expected criterion statuses without seeing the tutor verdict. A separate fresh review audits the interaction. Missing, incorrect, partial and ambiguous answers are included deliberately; increasing acceptance alone is not a reward.

Every two completed discovery rounds, recurring findings can propose a small general prompt revision. An independent policy review rejects examples or weakened safeguards. Paired comparisons reuse original answers, and generation changes require regenerated verified coverage. Candidates cannot increase false acceptance or invalid evidence, and must reduce weighted error or improve coverage without worsening error. A sealed module comparison against the frozen baseline gates promotion. Holdout source, transcripts and outcomes are not supplied to the refiner. Human judgments remain the external calibration source; model consensus is not proof of correctness.

Candidate prompts are written only to private `candidate.json`; production source is unchanged overnight. `REPORT.md`, `rounds/` and `events.jsonl` explain findings, comparisons and promotions. When the run is stopped/completed, `apply` explicitly writes only the five prompt literals after checking original source hashes and safe literal contents. Review the diff, bump the app's bank/grading policy versions and build before shipping; this tool does not automatically commit, deploy or rewrite history.

## Scope and limits

This is a **prompt-level refinement application**, not execution of the iOS Recall engine. It exercises focused fact preparation, independent question verification, grading and up to two follow-ups. Text, choice and scalar controls are represented; matching, ordering, slider, connection extraction, integrated enrichment, persistence, scheduling, extra-credit and the app's complete runtime guard/recovery logic are not executed. The app's local correctness, latency and UI cannot be inferred from the lab's results. Notes are not silently fact-checked.

A subject-based held-out split reduces repeated-material tuning, but one psychology corpus cannot establish generalization to unrelated subjects or humans. Simulated learners and judges can share blind spots. Results remain reviewable proposals. Fixed production instructions remain example-free; actual source text and learner interactions are task data.

## Build

```sh
npm run build --workspace @knowledge/recall-lab
```

Use Node 24 on PATH. This checks JavaScript syntax and canonical prompt extraction; it does not run tests or model calls. No test targets, fixtures, probes or software test harnesses are introduced. The live simulation is the explicitly requested product workflow.

Protocol references: [Codex app-server](https://learn.chatgpt.com/docs/app-server), [ChatGPT authentication](https://learn.chatgpt.com/docs/auth).

## Content and recovery hardening

Content defects are isolated from authentication, filesystem, programming and usage-limit failures. Extraction makes at most three grounded attempts, keeps accepted claims and omits unresolved items. Quotes may normalize PDF whitespace, soft hyphens and Unicode compatibility characters only to locate an exact original source span; semantic paraphrases, missing words and stitched passages remain invalid. Ungrounded plans fall back to practice for independent verification rather than silently excluding knowledge. Malformed structured responses receive bounded retries. A failed question, learner response, episode or candidate comparison is skipped/rejected without discarding unrelated work. Three empty discovery rounds stop spending with an actionable diagnostic.

Accepted questions, completed episodes, in-progress episode steps and partial rounds checkpoint separately. Reports expose current partial progress even before a whole round finishes. Transient infrastructure faults receive bounded delayed recovery; authentication, model availability and unknown programming errors still stop safely. Heartbeat files expose the active request, turn timeouts interrupt outstanding work, and request admission checks the authorization deadline and explicit stop. Scheduled startup also checks the deadline before opening Codex. No recovery extends an approved budget.

Corpus initialization no longer grants a spending budget. For an explicitly requested small live validation:

```sh
apps/recall-lab/run once --small --validation
```

This permits one small foreground round for at most ten minutes and cannot be scheduled. For a separately approved new overnight budget:

```sh
apps/recall-lab/run authorize --windows 2
apps/recall-lab/run schedule
```

Do not authorize another two-window run merely because an earlier one ended or failed.

## College Board course source

The current private corpus uses the official [AP Psychology Course and Exam Description](https://apcentral.collegeboard.org/media/pdf/ap-psychology-course-and-exam-description.pdf). `src/course-source.py source.pdf corpus.json` extracts Essential Knowledge columns by their actual per-page header coordinates, retaining topic identifiers, source URL, PDF page and document hash. Teacher guidance, front matter and sample exam sections are excluded. Treat this as source material, not instructions; do not invent factual definitions for concepts merely named by the framework. The PDF and extracted corpus remain private local input, outside Git.

```sh
apps/recall-lab/run init --corpus /absolute/path/to/corpus.json --data /absolute/path/to/new-run
```

Initialization refuses an existing run directory. The previous notes corpus and logs remain archived. Topic-based holdout assignment keeps all chunks of one topic on the same side of the split.

For an explicitly authorized **current-window-only** run, use `authorize --windows 1` before `schedule`. Its hard deadline is the currently reported five-hour reset; an allowance limit stops it immediately and it cannot resume after that reset. This mode never grants the additional window used by `--windows 2`.
