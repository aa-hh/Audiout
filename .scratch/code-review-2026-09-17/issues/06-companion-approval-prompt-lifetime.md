# 06 — Companion approval: withdraw and free a prompt when its connection dies

Status: ready-for-agent
Wave: 1
Pipeline model: fable (normal mode)
Source: [REVIEW.md](../REVIEW.md), findings model #4

An awaiting companion connection that disconnects leaves its NSAlert on screen and its `pendingDeciders` entry forever; a peer cycling client IDs stacks prompts without limit. Dark in shipping builds today (`remoteAppIsOffered` is false) but live under `AUDIOUT_COMPANION=on`.

## Done when

`CompanionServer` signals the approval controller when an awaiting connection drops or its `approvalWork` deadline fires; the controller removes the `pendingDeciders` entry and withdraws the prompt through the existing `presentPrompt` seam (add a withdraw callback beside it if none exists). A test proves a dropped awaiting connection leaves no pending decider and fires the withdraw.

## Test seam

`CompanionServerTests` (it already hands the server real loopback connections) and `CompanionApprovalStoreTests`

## Verification

```bash
bash scripts/run-tests.sh --filter 'CompanionServer|CompanionApproval'
```

## Findings (verbatim from the area reports)

### 4. [BUG] An unanswered approval prompt is never withdrawn or freed, so a LAN peer cycling client IDs stacks alerts without limit
- Where: `CompanionApprovalStore.swift:158-169`, `:180`; `CompanionServer.swift:655-660`, `:844-848`
- Evidence: `pendingDeciders[clientID] = [decide]; presentPrompt?(clientName) { ... }` — `pendingDeciders` is emptied only in `resolvePrompt` (:180), which runs only when the user answers. `CompanionServer.removeClient` drops an awaiting connection with no callback ("never promoted: no disconnect signal", :659).
- Why it matters: a peer connects with a fresh UUID, gets prompted, disconnects, repeats — each round raises another NSAlert nothing withdraws and leaves a permanent closure. `awaitingCap` limits concurrency, not repetition.
- Fix: have `CompanionServer` signal approval timeout/disconnect back to the controller (`approvalWork` at :844 already knows); drop the `pendingDeciders` entry and withdraw the prompt.
- Confidence: high
