# FORGE Library & Orchestrator — Benavora

## What This Is

The FORGE Library is a structured collection of pre-written build queues that the Orchestrator runs in dependency order, non-stop, until the entire platform is built.

Instead of manually copying queue files and launching FORGE after each run, you run one command and walk away. The orchestrator handles everything.

---

## Folder Structure

```
C:\Users\manag\Documents\FORGE\
├── forge.ps1                          # Original FORGE runner (unchanged)
├── chain-forge.ps1                    # Runs multiple queues sequentially
├── forge-orchestrator.ps1             # NEW — runs entire library autonomously
├── library\
│   └── benavora\
│       ├── library-manifest.yaml      # NEW — master index of all queues
│       ├── queue-autonomous-agents.yaml
│       ├── queue-ui-flightpath-hud.yaml
│       ├── queue-ui-opportunities.yaml
│       ├── queue-ui-command-center.yaml
│       ├── queue-ui-remaining-pages.yaml
│       ├── queue-pillars-fundability-score.yaml
│       ├── queue-donor-intent-engine.yaml
│       ├── queue-twin-powered-draft.yaml
│       ├── queue-autoapply-autonomous.yaml
│       ├── queue-corporate-relationship-graph.yaml
│       ├── queue-pig-phase2.yaml
│       ├── queue-community-need-prediction.yaml
│       ├── queue-990-xml-enrichment.yaml
│       ├── queue-eligibility-scoring.yaml
│       ├── queue-corporate-prospects.yaml
│       ├── queue-global-learning-network.yaml
│       ├── queue-fundraising-simulator.yaml
│       ├── queue-continuous-improvement.yaml
│       ├── queue-roi-optimizer.yaml
│       ├── queue-strategic-advisor.yaml
│       ├── queue-testing-suite.yaml
│       ├── queue-performance-optimization.yaml
│       └── queue-consultant-tier.yaml
└── projects\
    └── benavora\
        └── queue.yaml                 # Active queue (orchestrator writes this)
```

---

## How To Use

### Option 1 — Dry run (see what would run without executing)
```powershell
cd C:\Users\manag\Documents\FORGE
powershell -ExecutionPolicy Bypass -File .\forge-orchestrator.ps1 -project benavora -dryRun
```

### Option 2 — Full overnight run (runs everything in dependency order)
```powershell
cd C:\Users\manag\Documents\FORGE
powershell -ExecutionPolicy Bypass -File .\forge-orchestrator.ps1 -project benavora
```

### Option 3 — Skip to a specific queue (resume after partial failure)
```powershell
cd C:\Users\manag\Documents\FORGE
powershell -ExecutionPolicy Bypass -File .\forge-orchestrator.ps1 -project benavora -skipTo ui-command-center
```

### Option 4 — Run a single specific queue only
```powershell
cd C:\Users\manag\Documents\FORGE
powershell -ExecutionPolicy Bypass -File .\forge-orchestrator.ps1 -project benavora -only ui-flightpath-hud
```

---

## How The Manifest Works

`library-manifest.yaml` is the master build plan. Each entry has:

| Field | Meaning |
|---|---|
| `id` | Unique identifier for this queue |
| `file` | Filename inside the library folder |
| `status` | `pending` / `running` / `complete` / `failed` / `planned` |
| `depends_on` | List of queue ids that must complete first |
| `priority` | Lower number runs first when multiple queues are runnable |
| `prompt_count` | Number of prompts in this queue |
| `estimated_hours` | Rough runtime estimate |
| `note` | Human note (e.g. "Do not build until 25+ customers") |

**Status values:**
- `pending` — ready to run when dependencies are met
- `running` — currently executing (set by orchestrator)
- `complete` — finished successfully
- `failed` — failed, but orchestrator continues with unblocked queues
- `planned` — intentionally deferred (future phase, not ready to build)

---

## Adding A New Queue To The Library

1. Write the queue YAML file with full engineering-grade prompts
2. Save it to `C:\Users\manag\Documents\FORGE\library\benavora\`
3. Add an entry to `library-manifest.yaml` with correct `depends_on`
4. The orchestrator will pick it up automatically on next run

---

## The Pre-Launch Checklist (run before every orchestrator launch)

```powershell
cd C:\Users\manag\Documents\benavora
pnpm install
pnpm build
git status
```

All three must be clean before launching. FORGE builds on top of a clean codebase — if the build is broken before it starts, every prompt inherits broken code.

---

## Queue Writing Rules (why prompts go shallow)

The single biggest cause of shallow builds is vague prompts. Every queue prompt must:

1. **Start with file reads** — "Read X in full" before any instruction
2. **Specify minimum implementation size** — "This file must be at least 150 lines"
3. **Name exact function signatures** — not "create a function that does X" but the full TypeScript signature
4. **Specify exact database operations** — not "save to database" but exact table name, columns, upsert logic
5. **Never put Supabase migrations inside FORGE prompts** — apply migrations via PowerShell before FORGE runs
6. **End with explicit commit message** — forces CC to verify the work before moving on

---

## Current Build Status

See `library-manifest.yaml` for live status of all queues.

As of July 19, 2026:
- `autonomous-agents` — RUNNING (24 prompts, tonight)
- All others — PENDING (waiting for their dependencies or for queue files to be written)

Next session: write the UI queue files and add them to the library.
