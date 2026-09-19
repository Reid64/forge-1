# Detached-launch wrapper for the BENAVORA AR-13..AR-23 remediation chain.
#
# 55 prompts, 11 queues, in dependency order. Engine first (AR-13..AR-19),
# then the product surface (AR-20..AR-23).
#
# Takes no parameters, deliberately: Start-Process flattens -ArgumentList to a
# single OS command-line string, and bare space-separated tokens do not rebind
# as chain-forge.ps1's [string[]]$queues across a process boundary. The array
# is constructed natively in-process here instead.
#
# ORDER IS NOT ALPHABETICAL AND MUST NOT BE SORTED:
#   AR-18 runs SECOND, before AR-14..AR-17, because it builds work-landed.mjs -
#   the gate that catches the ar-10-3 failure of 2026-09-18, where four gates
#   passed with migration 198 live in production and its code uncommitted.
#   50 downstream prompts gate on that script existing.
#   AR-21 runs before AR-22 for the same reason: it builds route-renders.mjs,
#   design-tokens.mjs, ui-primitives.mjs, route-boundaries.mjs and a11y.mjs,
#   which 17, 8, 2, 3 and 9 later prompts respectively depend on.

Set-Location "C:\Users\manag\Documents\FORGE"

$queues = @(
  "queue-ar-13-full-platform-diagnostic.yaml",          # 4  diagnostics only
  "queue-ar-18-build-system-hardening.yaml",            # 3  work-landed + deploy verify + CI integrity
  "queue-ar-14-pipelines-and-schedulers.yaml",          # 3
  "queue-ar-15-the-fifty-one.yaml",                     # 7
  "queue-ar-16-autoapply-to-production.yaml",           # 3
  "queue-ar-17-agent-efficacy.yaml",                    # 8
  "queue-ar-19-final-verification.yaml",                # 4  engine delta
  "queue-ar-20-product-surface-diagnostic.yaml",        # 5  diagnostics only
  "queue-ar-21-ui-gates-and-design-system.yaml",        # 6  UI gates + token layer
  "queue-ar-22-product-surface-remediation.yaml",       # 8
  "queue-ar-23-billing-and-surface-verification.yaml"   # 5  surface delta
)

& "C:\Users\manag\Documents\FORGE\chain-forge.ps1" -project benavora -queues $queues
