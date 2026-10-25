# Raw Notes transcription — proposed next step

Status: design only, 2026-10-25. The Raw Notes form and MCP capture work without transcription. No audio is sent to an external provider automatically.

## User flow

Settings → Voice transcription: deployment-level enable/disable, Local / external API, installed model, Download / Remove model, language Auto / Russian / English, automatic processing of new notes, queued/running/failed/completed status and Retry. Disabling stops new jobs; downloads and existing transcripts remain until explicitly removed. Several models may be downloaded; load only one active model at a time. Comparing models is an explicit action, not multiple automatic passes for every recording.

Save a note immediately, including original audio. A background worker transcribes it later. The note displays the transcript next to its recording; original audio remains available. Show that text is machine-generated and allow editing. Do not translate Russian into English. Language detection is fallible, especially on very short recordings, silence, boat noise, and speech that switches languages; allow a manual hint and retry. Transcription is not a summary.

## Components and storage

- Optional Compose worker, separately enabled per deployment; web UI never waits for recognition.
- Local runtime: start with whisper.cpp + FFmpeg. CPU on Linux AMD64/ARM64; native macOS can use Metal/Core ML. Docker on Mac should be benchmarked as a CPU deployment, not assumed to have native Metal acceleration.
- Alternative runtime: faster-whisper + CTranslate2, CPU int8 or NVIDIA GPU. Same application job/result contract, so changing runtime does not change document storage.
- Download versioned multilingual model weights (not `.en` models), verify checksums, store in a named volume outside Git. Pin runtime/version and trusted model manifest; do not download arbitrary user-provided executable model code.
- Reconstructible queue outside Git. Job identity: audio blob SHA + model/runtime version + language/options hash. Restart/retry must not duplicate transcripts. One worker task at a time initially, bounded CPU/RAM/time and maximum recording duration.
- Original `media/voice-*.m4a` stays unchanged. Store a readable `transcripts/voice-*.md` and hidden per-recording metadata (audio SHA, model, language, completion time, transcript SHA). Derived transcript paths are indexed by RAG and readable via MCP.
- Update note links/results through the common save/version-check mechanism in one commit. A note edited during recognition must be reread; never replace its whole text with a stale copy. Never overwrite a manually edited transcript on retry: retain a separate generated candidate for review.
- Trigger after committed note creation; scan after Git synchronization and on startup for pending audio. Skip matching completed jobs. External API failure must not silently fall back to another provider.
- MCP: list transcription jobs/status, request/retry with chosen model/language, read transcript. Existing read_raw_note should include transcript paths and state.

## First model choices and hardware

whisper.cpp documents approximate unquantized footprints: base 142 MiB disk / 388 MB RAM; small 466 MiB / 852 MB; medium 1.5 GiB / 2.1 GB. These are model/runtime estimates, not total container budgets. Quantization can reduce memory/disk use.

Start with multilingual base as the low-resource baseline; compare small on the same Russian and English recordings. Use medium or large-v3-turbo only after a measured quality/performance comparison and a sufficient memory budget. Auto language detection is supported; mixed-language recognition still needs evaluation.

The currently inspected cloud host has 3 vCPU, 3.7 GiB RAM, about 1.2 GiB available, no swap, and several other applications. Start with base and a single job, bounded to 1–2 CPU threads, then measure peak RSS and duration on actual recordings. Do not infer cloud speed from Mac speed. Increasing host RAM or running recognition on Mac are alternatives if small does not fit comfortably.

Record for each benchmark: model/version, quantization, runtime/CPU threads, audio duration, elapsed processing time (including cold load separately), peak memory, detected language, missed measurements/units/names, quality on wind/engine noise and mixed Russian/English. Avoid judging recognition from the synthetic tone used in upload tests.

## External option

A provider adapter can send audio to the OpenAI transcription API with a separately configured secret and explicit opt-in. Current official documentation recommends `gpt-transcribe`, with detected languages and optional language/context hints. File size limit is 25 MB; current notes cap each attachment at 20 MiB, but conversion/chunking still needs a limit check. Keep original-language transcription and record provider/model provenance. Do not promise timestamps or speaker labels unless supported by the selected model.

## Sources checked

- https://github.com/ggml-org/whisper.cpp — runtimes, quantization and memory table.
- https://github.com/SYSTRAN/faster-whisper — CTranslate2, CPU int8, automatic language detection and benchmark methodology.
- https://developers.openai.com/api/docs/guides/speech-to-text — current file transcription API, formats, limits and language hints.
