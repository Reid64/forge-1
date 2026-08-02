# CLAUDE.md — FORGE Autonomous Build System Governance

## IDENTITY

You are operating inside FORGE (Factory for Orchestrated Replicable Governed Execution), an autonomous software build system owned by Reid Whitesides. Your job is to build production-grade applications from governance documents and prompt queues with ZERO human intervention during execution.

## IRON LAWS — NEVER VIOLATE UNDER ANY CIRCUMSTANCES

1. **NEVER modify or delete governance files** (BLUEPRINT.md, SCHEMA_REGISTRY.md, BEHAVIORAL_CONTRACTS.md, CLAUDE.md, STATE_OF_THE_BUILD.md, SESSION_STATE.md). These are READ-ONLY inputs.
2. **NEVER skip a quality gate.** Every gate must pass before advancing to the next prompt. No exceptions.
3. **NEVER fabricate test results.** If a test fails, report the actual failure. Never claim something passes that has not been verified.
4. **NEVER modify middleware.ts with a patch.** Always full file replacement. Role fetch failure = /login redirect only.
5. **NEVER serve dashboard HTML from public/ directly.** Always use no-cache API routes.
6. **NEVER leave TypeScript errors unresolved.** `pnpm tsc --noEmit` must return zero errors before any commit.
7. **NEVER commit without running the full gate sequence:** tsc → build → lint → test.
8. **NEVER use mocks or placeholder data in production code.** All data must come from real API calls to real tables.
9. **NEVER assume a file exists.** Always verify with Test-Path or equivalent before referencing.
10. **NEVER proceed past 3 failed retry attempts.** Halt the pipeline and log the failure for human review.

## DANGER ZONES — AUTOMATIC HALT IF TOUCHED

- Any file in the `governance/` directory
- Any `.env` or `.env.local` file (read for values, never modify)
- Any Supabase RLS policy (read and verify, never drop)
- The `FORGE-setup.ps1` script
- This `CLAUDE.md` file
- Any file owned by a different project (stay in your project boundary)

## TECH STACK — LOCKED, NON-NEGOTIABLE

- **Framework:** Next.js 14, TypeScript strict mode
- **Database:** Supabase (PostgreSQL + Auth + RLS + Realtime)
- **Hosting:** Vercel
- **Package Manager:** pnpm (NEVER npm or yarn)
- **Telephony:** Twilio (when applicable)
- **Payments:** Stripe (when applicable)
- **Email:** Resend (when applicable)
- **Maps:** Mapbox (when applicable)
- **AI:** Anthropic Claude API (when applicable)
- **Testing:** Playwright
- **Version Control:** Git → GitHub

## THE SIX LAWS OF FEATURE COMPLETION

A feature is ONLY complete when ALL SIX pass:

1. **SCHEMA:** Tables exist in real database. RLS policies applied. company_id scoping enforced.
2. **API:** Routes exist, authenticate user, derive company_id from session (never from request body).
3. **UI:** Real UI components rendered. No placeholders. Empty states handled.
4. **DATA:** Real API calls to real tables. Company-scoped queries. Zero mocks.
5. **WIRING:** Navigation linked. Role gates correct. All buttons and forms save to database.
6. **VERIFICATION:** Verified in browser via Playwright. UNVERIFIED until this step completes.

## QUALITY GATES — EXECUTED IN ORDER

After every prompt execution, run these gates in sequence. ALL must pass.

### Gate 1: Compile
```
pnpm tsc --noEmit
```
Must return zero errors. Any error = retry with error context.

### Gate 2: Build
```
pnpm run build
```
Must complete without errors. Build warnings are acceptable. Build errors = retry.

### Gate 3: Lint
```
pnpm lint
```
Must pass. Fix lint errors before proceeding.

### Gate 4: Test (when test files exist)
```
npx playwright test --reporter=list
```
Must pass 10/10. Any failure = retry with failure context.

### Gate 5: AI Review (every 5th prompt)
Run a separate Claude instance to review the last 5 prompts' output for:
- Dead code
- Security vulnerabilities (exposed keys, SQL injection, XSS)
- TypeScript strict mode violations
- Missing error handling
- Unused imports

### Gate 6: Governance Compliance (every 10th prompt)
Verify against the Six Laws for all features touched in the last 10 prompts.

### Gate 7: Deploy Verification (`deploy_verify` — mandatory closing gate, every queue)
Runs `vercel --prod`, then confirms the resulting production deployment's commit SHA
(read from the Vercel API, not `vercel inspect`/`vercel ls`) matches `git rev-parse HEAD`.
Logic lives in `scripts/verify-deployment.ts` inside the target project repo; the FORGE
gate (`gates/deploy_verify.ps1`) shells out to that same script. FAILS LOUDLY — prints
`DEPLOYMENT VERIFICATION FAILED: ...` and exits non-zero — on any SHA mismatch, failed
deploy, or non-READY state.

**Every queue file authored from now on MUST add `- type: deploy_verify` as the LAST
gate on its final prompt** (after `compile`/`build`), so it fires once per queue, not
once per prompt. `forge-orchestrator.ps1` additionally runs this same check as a
mandatory, non-skippable step after every queue completes — success or partial — via
`Invoke-DeployVerification`, and will not mark a queue `complete` in
`library-manifest.yaml` until it passes. See STATE_OF_THE_BUILD.md in the target
project for the 2026-08 incident (repeated silent production drift) that made this
mandatory.

## ERROR RECOVERY PROTOCOL

When a gate fails:

1. **Capture** the exact error output (full stderr/stdout)
2. **Analyze** the error category:
   - Tier 1 (syntax/compile): Auto-retry with error fed back as context
   - Tier 2 (logic/integration): Attempt fix with full error analysis (max 3 attempts)
   - Tier 3 (architectural/unknown): HALT. Write failure to `state/halt-reason.md`. Do not proceed.
3. **Retry** up to 3 times per tier
4. **Escalate** if retries exhausted: write detailed report to `reports/` and stop

## DEPLOYMENT PROTOCOL

Every deploy follows this exact sequence:
1. `pnpm tsc --noEmit` — must pass
2. `pnpm run build` — must pass
3. `vercel --prod` — must succeed
4. `npx playwright test` — must pass 10/10
5. `git add -A && git commit -m "[FORGE] <description>" && git push`
6. `deploy_verify` (`scripts/verify-deployment.ts`) — production's deployed commit SHA
   must match `git rev-parse HEAD`. A successful `vercel --prod` in step 3 is NOT
   sufficient on its own: it only proves *a* build succeeded, not that the SHA Vercel
   actually promoted to production is the one just pushed. **No queue is complete until
   this step passes.**

If ANY step fails, the deploy is ABORTED. Do not force-push broken code.

## STATE MANAGEMENT

After every prompt completion (pass or fail), update:
- `state/current-prompt.json` — which prompt index you are on
- `state/gate-results.json` — pass/fail for each gate
- `state/build-log.md` — running log of all actions taken

After build completion, generate:
- `reports/STATE_OF_THE_BUILD_<timestamp>.md` — full summary

## PROMPT QUEUE EXECUTION

1. Read the project's `queue.yaml` file
2. Parse all prompts in order
3. For each prompt:
   a. Read all governance docs as context prefix
   b. Execute the prompt via `claude -p`
   c. Run all quality gates
   d. If pass: update state, move to next prompt
   e. If fail: enter error recovery protocol
4. After all prompts complete: run deployment protocol
5. Generate State of the Build report

## AUTONOMOUS OPERATION RULES

- Never ask for human input. Make the best decision based on governance docs.
- Never wait for approval. The governance docs ARE the approval.
- Never skip steps to save time. Every gate exists for a reason.
- Never modify the prompt queue during execution. Execute as written.
- If you encounter an ambiguity not covered by governance docs: HALT and log it. Do not guess.
- Log every action with timestamps to `state/build-log.md`.

## COMMIT MESSAGE FORMAT

All commits follow this format:
```
[FORGE] <phase>: <description>

Gates: compile=PASS build=PASS lint=PASS test=PASS
Prompt: <prompt-id> of <total>
```

## SESSION END REQUIREMENTS

Before ending any session, you MUST:
1. Update `STATE_OF_THE_BUILD.md` from a live codebase audit
2. Update `SESSION_STATE.md` with current progress
3. Commit and push all changes to GitHub
4. Write a summary to `reports/`
