EXPLANATION:
High-Level Goals

Stand up a Riva/NIM ASR instance exposing Parakeet RNNT over gRPC.

Replace the local RNNT path in your repo with a thin Riva client wrapper that preserves your current JSON/WS contract (partials/finals).

Ship observability, tests, and load checks so you can trust latency, accuracy, and stability in prod.

Harden for security & failure modes (TLS, timeouts, retries, backpressure).

Milestones (checkpoint criteria)

M0 – Plan Locked: Inputs gathered; repo entry points and ASR boundaries identified.

M1 – Riva Online: Riva/NIM container running; health checks pass; model enumerated.

M2 – Client Wrapper: Your code can stream to Riva and receive partial/final results; unit tests green.

M3 – WS Integration: End-to-end via your WebSocket/API; golden samples pass; latency SLO met.

M4 – Observability & Scale: Metrics/logs emitted; load tests hit target concurrency without degradation.

M5 – Production Ready: Security (TLS/mTLS/JWT), runbooks, alerts, and rollback path in place.

Step-by-Step Plan (LLM-guided with tests)

For each step: LLM Task → Inputs → Deliverables → Tests/Checks → Acceptance.

1) Repo Audit & Plan Lock (M0)

LLM Task: Map the ASR call sites. Identify where audio frames are ingested, where RNNT is invoked, and where partial/final transcripts are emitted to clients.

Inputs: Repo URL/branch; paths for scripts/, Dockerfile*, server/WS modules; current .env/config.

Deliverables:

A short architecture note (200–400 words) with file/function names and a single “ASR boundary” interface to replace.

A list of env keys to introduce (e.g., RIVA_HOST, RIVA_PORT, RIVA_SSL, RIVA_MODEL).

Tests/Checks:

Grep/symbol search shows one import path for ASR (no stray call sites).

Existing unit tests compile and run (even if they fail) to ensure harness is intact.

Acceptance: Architecture note approved; boundary chosen.

2) Stand Up Riva/NIM Locally or in Dev (M1)

LLM Task: Produce a scripts/step-015-deploy-riva.sh to pull & run the Riva/NIM ASR container with Parakeet RNNT enabled; include health/ready checks.

Inputs: Target GPU/driver, container runtime (Docker), port plan, SSL choice.

Deliverables:

Script with env vars and a health probe (e.g., grpcurl or Python client sanity script).

Minimal README with start/stop and model list command.

Tests/Checks:

docker ps shows container healthy; list models returns Parakeet RNNT.

Sanity script transcribes a 3–5 sec WAV and prints text.

Acceptance: Health & sanity pass in CI/dev.

3) Dependencies & Config

LLM Task: Update requirements.txt / pyproject.toml to add riva client SDK, remove SpeechBrain if unused. Add .env.example keys and config loader.

Inputs: Python version, base image, existing dependency pins.

Deliverables:

Diff for deps; .env.example with RIVA_* keys; config module with typed accessors.

Tests/Checks:

Fresh pip install/uv lock succeeds; import works in a scratch script.

CI lints and builds pass.

Acceptance: Clean build; config keys load.

4) Implement a Thin RivaASRClient Wrapper (M2)

LLM Task: Create src/asr/riva_client.py exposing a minimal interface:

stream_transcribe(audio_iter, sample_rate, enable_partials=True) → yields partial/final events (your existing JSON shape).

Inputs: Your current ASR response schema and partial/final semantics.

Deliverables:

Wrapper module with stream generator; timeout/retry knobs; hotword param placeholder.

Mapping from Riva fields → your JSON schema (stable).

Tests/Checks:

Unit tests: mock Riva stub; assert event order (partials then final), timestamps sorted, is_final toggling.

Fixture test with a 2–3 sec WAV → deterministic expected transcript (golden).

Acceptance: Unit tests green; golden matches within tolerance.

5) Wire Into Your WebSocket/API Path (M3)

LLM Task: Replace the old RNNT call site with RivaASRClient.stream_transcribe(...). Ensure backpressure and “end-of-stream → final flush” semantics.

Inputs: WS handler path, buffering/chunk size, sample format (PCM16/float32).

Deliverables:

Diff to WS handler; stream pump that yields interim at ~100–300ms cadence and final on VAD/end.

Error propagation: if Riva errors, send a structured error and close cleanly.

Tests/Checks:

E2E test: Connect a test client, stream a WAV; verify partials cadence and final stability.

Silence/low-SNR clip: ensure no hallucinated finals; partials minimal/empty.

Acceptance: Manual e2e demo works; latency SLO (see below) met.

6) Docker & Runtime Integration

LLM Task: Update your app Dockerfile(s) to include Riva client deps; do not bundle model weights. Add health endpoints.

Inputs: Base image, CUDA toolkit presence (client-only is fine).

Deliverables:

Dockerfile diff; HEALTHCHECK with a quick self-probe (doesn’t call Riva).

scripts/step-020-build-run-app.sh with .env passthrough.

Tests/Checks:

Container builds reproducibly; starts and serves WS.

With Riva up, smoke test passes.

Acceptance: Container image ready; smoke test green.

7) Observability (Logs, Metrics, Traces)

LLM Task: Add structured logs (start/end, RTFx), metrics (partial latency p50/p95, final latency p50/p95, error rates), and trace IDs for each stream.

Inputs: Your logging lib; metrics stack (Prometheus/OpenTelemetry).

Deliverables:

Middleware that stamps a stream_id; log lines with durations and sizes.

Metrics exporter/endpoint and basic Grafana dashboard JSON.

Tests/Checks:

Unit test: metrics counters increment; log schema validated.

Manual: dashboard shows a stream with realistic values.

Acceptance: Metrics/logs visible; alarms can be defined.

8) Functional QA Suite (Golden Fixtures)

LLM Task: Build a fixture set covering: clean speech, fast speech, accents, noise, music-under-voice, silence, long (≥2 min). Include 8k/16k sample rates if relevant.

Inputs: Small curated audio set; expected transcripts (hand-checked).

Deliverables:

tests/fixtures/*.wav and tests/golden/*.json.

Test runner producing WER and latency report per clip.

Tests/Checks:

WER thresholds (e.g., ≤ 12% clean, ≤ 18% noisy).

Latency SLOs:

Interim/partial first token ≤ 300 ms p95

Final after end-of-speech ≤ 800 ms p95

Acceptance: Thresholds met across the matrix.

9) Load & Concurrency

LLM Task: Add a synthetic load script (k6/Locust or Python asyncio) that opens N WS sessions streaming pre-recorded clips at real-time speed.

Inputs: Target GPU, desired concurrency (e.g., 50/100 sessions).

Deliverables:

load/ tool; report of RTFx, queue time, error/timeout rates vs. concurrency.

Recommended max concurrent sessions per Riva instance and app instance.

Tests/Checks:

No WS disconnect storms; p95 latency within SLO at the chosen limit.

Graceful throttling/backpressure when exceeding limits.

Acceptance: Concurrency target achieved with SLOs.

10) Failure Modes & Resilience

LLM Task: Implement timeouts, retries (idempotent), circuit breakers for Riva RPC; classify errors (transient vs fatal). Add health gates before accepting streams.

Inputs: Your retry/backoff policy; connection pools.

Deliverables:

Error taxonomy; retryable codes; breaker thresholds; fallback messaging to clients.

Runbook snippet for “Riva down / degraded.”

Tests/Checks:

Chaos tests: kill Riva, flap network; verify app degrades gracefully.

Clients receive structured error and do not hang.

Acceptance: Chaos suite passes; no deadlocks/leaks.

11) Security & Secrets

LLM Task: Configure TLS to Riva; optionally mTLS or JWT between app ↔ Riva; store secrets in your chosen manager; restrict inbound to app/Riva via network policy.

Inputs: Certs/PKI plan; secret manager (AWS SM, SOPS, etc.).

Deliverables:

TLS/mTLS setup doc; code/config changes; network policy/SG rules.

CI secret scanning gates.

Tests/Checks:

Cert rotation drill; request fails without proper client cert.

No secrets in logs/images.

Acceptance: Security checks pass; pen-test basics OK.

12) Rollout, Monitoring, and Runbooks (M5)

LLM Task: Write a canary rollout plan; define SLOs/alerts (latency, errors, saturation). Add quick rollback (env flag to disable ASR or revert to prior path).

Inputs: Your deployment tool (ECS/K8s), alerting stack.

Deliverables:

Canary checklist; alert rules; rollback procedure; on-call runbook.

“Known issues” page (VAD edge cases, accents, long silences).

Tests/Checks:

Dry-run a canary with small traffic; simulate alert breaches; rollback in under 5 minutes.

Acceptance: Leadership sign-off for prod launch.

Test Matrix (condensed)

Audio types: clean, fast, accented, noisy, music-under-voice, silence, long (2–10 min).

Rates: 8k/16k where relevant.

Metrics per clip: partial-first-byte latency, final latency, WER, CPU/GPU utilization, memory, WS errors.

SLOs: Partial p95 ≤ 300 ms; Final p95 ≤ 800 ms; Error rate < 0.5% at target concurrency.
