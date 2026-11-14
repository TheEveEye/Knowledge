# Voice Recall

**Start voice recall** appears below **Start Recall**. Voice sessions resume through the voice screen; **Continue in text** opens the same saved session.

## One paced tutor turn

Recall uses `gpt-realtime-2.1` over WebRTC. The same model hears the learner's original audio and assesses the answer. The application supplies the verified question, expected answer, criterion rubric, bound source passages, saved attempts and assistance history directly. No search or intent-routing text model is involved. Subject voice chat retains its separate GPT-Live integration.

The flow is **question → learner answer → silent decision → validated saved result → matching UI and speech**. The voice model calls exactly one tool without first speaking a verdict or holding phrase. The server saves the original transcript and validates the assessment. The native view accepts the result before the server requests speech containing only that approved feedback. Generated speech transcripts are diagnostic captions; they never independently change the assessment or feedback card.

Feedback is normally one or two useful sentences. A genuine gap may lead to one focused follow-up. Feedback is spoken first; the follow-up then becomes the displayed and spoken question. Routine grading uses no second model. Silent decisions have bounded timeouts and at most one validation repair; an invalid result exposes Retry instead of entering a background recovery loop. Unfinished meaningful fragments can be retained for continuation without continuously retrying the same input.

Validation checks ownership, current question and session versions, exact criterion coverage, valid learner evidence turns, verbatim quotes and follow-up limits. Short answers may use their entire original transcript as evidence; longer answers require exact excerpts. Structured controls retain deterministic answer-key checks. A conflicting voice judgment becomes uncertain and records no learning penalty. Semantic assessment remains the voice model's responsibility.

## Microphone and playback

Recall starts with microphone transmission gated until the initial question finishes. The microphone is also gated while a decision is being processed and while tutor audio plays. It reopens automatically afterward unless muted, paused or finished. Manual mode still captures a draft; it disables automatic submission, not capture.

**Interrupt** immediately silences local playback and requests authenticated server cancellation. To speak during tutor playback, tap Interrupt first. User mute, server listening state, pause and local playback state are independent gates. A short local drain interval reduces capture of the playback tail. There is no automatic audio barge-in. The WebRTC connection and audio element stay attached between normal replies.

Provider buffer events describe server stream state and do not prove exact phone playback. The transport accepts playback only for the currently approved utterance, and a playback timeout exposes Retry if completion never arrives.

## Answers, help and navigation

Each audio input is bound to the active question and displayed prompt at speech start. The original transcript is required before assessment is saved; model-written reconstructions never replace it. Noise, greetings, hesitation and transcription failures do not create incorrect attempts. Later discussion after completed feedback is practice without additional independent-review credit.

Help, explanations and bounded steps, flow and comparison visuals use native views. Support requires exact quotes from the loaded passages. Source membership is validated; semantic grounding remains the tutor's responsibility. No generated HTML or executable UI is accepted. Assistance is recorded before speech dispatch, using utterance timestamps to preserve credit for earlier independent attempts. Neutral clarification and question repetition do not create assistance annotations.

**Finish answer** explicitly submits typed, reviewed or structured input. Editing the transcript enables **Finish answers manually**. Explicit help requests still work in manual mode. The answer composer closes after completed feedback, leaving the feedback, help, optional review and navigation controls.

The app owns Next. Common explicit English and German navigation requests bypass model inference, and the Next button uses the same server operation. Other explicit navigation intents can be selected by the silent tutor decision. The next verified question and its evidence are preloaded. The server commits the review before displaying that question, then speaks the displayed question. Next may end an optional follow-up using assessed evidence. Uncertain questions can be skipped without penalty.

## Funding

All voice tutoring, transcription and routine voice assessment use the server allowance. **Review assessment** explicitly invokes the session's selected text provider and model. A spoken challenge must express an explicit review request. Text-mode Recall also uses the selected text provider. Funding never switches after a failure.

The provider selection is captured when the session starts; changing account defaults applies to new sessions. Native labels distinguish voice usage from text mode and requested reviews.

## Lifecycle and diagnostics

The authenticated backend creates the Realtime call, attaches its sideband, executes tools and hangs up the call. Credentials remain server-side. Protocol **5** is required; older clients receive an update-required error. Commands are deduplicated, and durable Recall operations retain version and idempotency checks.

Closing the screen, backgrounding, Knowledge disconnection, audio interruption, headphone disconnection and sign-out stop capture. Calls have a 20-minute limit and end after twelve seconds without an event subscriber. Event-stream reconnection reuses the call; restarting ended audio requires an explicit tap. Pause cancels pending work and playback. Resume recovers a saved pending assessment or repeats the interrupted approved utterance.

Call routing is process-local for the current single-API deployment. Saved attempts and assessments survive API restarts; an interrupted live call must be started again. Legacy persisted queued attempts remain in Recall context for recovery through the saved-session flow.

Response token usage accumulates independently of selected-provider review usage. Duration is estimated wall-clock time. Raw audio is not persisted. Private learning events record bound learner transcripts, the application state supplied to each silent decision, returned tool arguments, accepted display text and generated tutor transcript completions. These allow comparison of what the app supplied, what the model decided, what appeared and what speech was generated. They do not prove the learner heard completed playback. Provider retention follows applicable API settings.

Sanitized service logs record validation outcomes, decision duration, display-to-speech request time, server audio-stream start and navigation duration. Credentials and raw provider rejection bodies never appear in those logs; existing private encrypted rejection diagnostics remain available.

Build and typecheck commands are permitted. Automated tests, harnesses and live voice/device testing are not run without an explicit request. Compilation cannot establish conversation quality, provider access, real latency or audio-route behavior.

API reference: [Realtime client events](https://developers.openai.com/api/reference/resources/realtime/client-events), including manual response creation, response-specific tools and voice activity detection controls.
