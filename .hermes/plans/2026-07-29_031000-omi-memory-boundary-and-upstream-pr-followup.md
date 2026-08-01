# Omi memory boundary and upstream PR follow-up Implementation Plan

> **For Hermes:** Use test-driven development and isolated Codex worktrees for every code change.

**Goal:** Deliver a reviewable Omi-v4 opaque Cupboard-tenant control-plane boundary plus a hermetic ZKR scope/projection/retrieval proof, then resolve and rebase every actionable review item on the user-owned open upstream Omi PRs.

**Architecture:** Omi-v4 keeps `users.uid` and ZKR evidence/claims authoritative. A separate D1 mapping holds a randomly minted opaque Cupboard tenant identifier; this control plane must not call Cupboard or change ingestion/retrieval authority. The proof harness uses real existing projection/retrieval SQL against in-memory SQLite and makes no live channel/deployment claim. Each upstream PR is isolated in its own Git worktree.

**Tech Stack:** Rust Worker/D1, SQLite, Cargo; Git/GitHub CLI; Codex CLI; Swift/Node/pnpm checks as determined by the affected PR.

---

### Task 1: Audit and finish opaque tenant lifecycle contract

**Objective:** Verify the mapping code preserves UID secrecy, idempotent minting, cross-user isolation, and an explicit reversible lifecycle.

**Files:**
- Create: `cloud/migrations/0042_cupboard_tenants.sql`
- Create: `worker-rs/src/cupboard_tenant.rs`
- Create: `worker-rs/tests/cupboard_tenant.rs`
- Modify: `worker-rs/src/lib.rs`
- Modify: `worker-rs/src/routes_memory/wasm_glue.rs`
- Modify: `docs/memory-authority.md`

**Step 1: Review the existing agent diff and add a failing behavior test for any missing lifecycle invariant.**

The public response must not echo `uid`; a repeated mint must return the existing opaque ID; another UID must not observe it; revocation/delete must be explicit if “reversible” means ending the grant rather than merely reading a persisted mapping.

**Step 2: Run the focused test to verify RED.**

Run: `cargo test --test cupboard_tenant -- --nocapture`

Expected: the new lifecycle assertion fails for the missing behavior, not a compile or fixture error.

**Step 3: Make the smallest control-plane-only implementation change.**

Do not add Cupboard I/O, memory copies, vector/graph mutation, pairing, MCP behavior, or an unscoped UID lookup.

**Step 4: Verify GREEN and format.**

Run:
```bash
cargo fmt --check
cargo test --test cupboard_tenant -- --nocapture
cargo check --target wasm32-unknown-unknown
```

**Step 5: Commit only mapping files.**

```bash
git add cloud/migrations/0042_cupboard_tenants.sql worker-rs/src/cupboard_tenant.rs worker-rs/tests/cupboard_tenant.rs worker-rs/src/lib.rs worker-rs/src/routes_memory/wasm_glue.rs docs/memory-authority.md
git commit -m "feat(memory): add opaque Cupboard tenant mapping"
```

### Task 2: Add the hermetic scoped ZKR retrieval proof

**Objective:** Prove the real Worker scope, projection, citation, and liveness behavior without pretending to test deployed services.

**Files:**
- Modify: `worker-rs/src/routes_memory.rs` (or its existing `#[cfg(test)]` module)
- Modify only an existing test support module if necessary; do not add production code unless a failing test demonstrates a genuine defect.

**Step 1: Write one failing in-memory SQLite test.**

Arrange one `uid-a` accepted claim with cited evidence, one foreign `uid-b` claim, and one tombstoned `uid-a` claim. Exercise existing `parse_commit`/scope helpers and the same projection/query SQL used by Worker retrieval.

**Step 2: Verify RED.**

Run the precise test target and confirm it fails only because the fixture/helper is absent.

**Step 3: Add the minimal fixture/helper implementation.**

Use actual migration/projection/cited retrieval SQL. Do not mock scope filters or claim liveness.

**Step 4: Verify GREEN.**

Run the focused test, then `cargo test --lib routes_memory` and formatting.

**Step 5: Commit only the proof harness.**

```bash
git add worker-rs/src/routes_memory.rs [any minimal test-support file]
git commit -m "test(memory): prove scoped cited retrieval"
```

### Task 3: Final Omi-v4 pre-publish verification

**Objective:** Verify repository integrity and report proof limits before pushing.

**Steps:**
1. Preserve the pre-existing unrelated `app/ios/Podfile.lock` modification; confirm it is not staged or committed.
2. Run `git diff --check`, the focused mapping test, focused route-memory test, `cargo fmt --check`, and WASM `cargo check`.
3. Manually run the exact focused harness command (“use it ourselves”) and retain its real output.
4. Push the feature branch to `origin` only after all checks are green.
5. Inspect release workflows/version policy before creating a tag. If no explicit release target exists, report the branch as published and leave tagging/release pending rather than guessing a product release.

### Task 4: Resolve user-owned upstream Omi PR feedback in isolated lanes

**Objective:** Address review feedback and CI failures only for open PRs owned by `undivisible`: #10832, #10831, #10733.

**Files/worktrees:**
- `/Users/undivisible/projects/worktrees/omi-pr-10832`
- `/Users/undivisible/projects/worktrees/omi-pr-10831`
- `/Users/undivisible/projects/worktrees/omi-pr-10733`

**Steps per PR:**
1. Fetch the PR branch and current `origin/main`, inspect status, preserve unrelated work, and collect all review/issue comments.
2. Rebase onto current `origin/main` using an isolated worktree.
3. Write/run a failing targeted test for each actual comment; implement the smallest fix; rerun GREEN.
4. Run the affected project checks plus `git diff --check`.
5. Commit exact files and force-push with `--force-with-lease` only after review.
6. Watch the new GitHub checks. If a check fails, inspect the actual log, fix no more than three cycles, then report an honest blocker.

**Known initial comments:**
- #10832: retain headless-compatible user extensions; keep the UI-request stall handling.
- #10831: place overrides in active `pnpm-workspace.yaml`, regenerate lockfile, avoid incompatible React Router 8 override.
- #10733: ensure the Escape dispatch test target has `@testable import Omi_Computer`, then repair any remaining CI-only compilation failure from actual logs.

### Risks and proof boundaries

- The Omi-v4 tests do not prove Firebase/Worker credential issuance, deployed D1 behavior, real Cupboard service calls, device/channel linking, or production retrieval.
- An opaque tenant map is not a completed Cupboard data integration; it is only an explicit, reversible precondition.
- GitHub’s current base can advance during work; every upstream PR must be rebased immediately before push and its actual head/checks re-read after push.
- A release tag requires a verified target/version/release workflow; branch publishing alone must not be described as a release.
