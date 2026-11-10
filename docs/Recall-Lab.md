# Local Recall refinement

The standalone command-line application lives in [`apps/recall-lab`](../apps/recall-lab/README.md). It uses official Codex ChatGPT authentication and canonical backend instructions from [`policies.json`](../packages/backend/src/policies.json) to discover prompt-level question and grading defects with simulated learners and independent reviews.

Private notes, prompts under comparison, transcripts and checkpoints remain in private local storage, reached through the ignored `.recall-lab/` symlink after scheduling. They are not part of the backend database or Knowledge account identity. Candidate improvements remain separate from production source until explicitly applied and reviewed.

An initialized run is bounded to the rest of one reported five-hour allowance and one subsequent window. It can resume after the first reset once, and stops at the second exhausted allowance or its hard deadline. It never purchases credit or redeems resets. The Mac must remain available. See the application README for exact commands, safeguards and limitations.

This tool compares prompt-level behavior rather than executing the complete backend Recall engine or native app. Synthetic review findings supplement human diagnostic review; they cannot establish human learning quality or end-to-end app correctness.

The current corpus has switched to the College Board course description's Essential Knowledge sections, with PDF-page/topic provenance and topic-isolated holdouts. The original notes run remains archived. Initialization does not authorize spending. A ten-minute small foreground validation is separate from a newly authorized overnight window. Content defects receive bounded repair or item-level skips; partial progress is saved independently of round completion, and no recovery extends an approved deadline.
