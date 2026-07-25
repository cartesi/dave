---
name: doc-drift-check
description: Verify a documentation file against the code it describes and fix pointer rot. Use when asked to review, audit, or update docs, after a refactor that renamed modules or functions, or periodically as maintenance.
---

# Doc drift check

The repo's docs state invariants (stable) and reference code by path,
symbol, and count (volatile). Empirically, the invariants hold and the
pointers rot - so check the pointers.

Procedure, per document:

1. Extract every pointer-type claim: file paths, module names, function
   and type names, table/schema lists, command names, counts ("21
   scenarios"), and cross-references to other docs.
2. Verify each against the tree (Glob/Grep, `just --list`). For claims
   about behavior shape (control flow, gating, ordering), read the
   named code - do not trust the doc's paraphrase.
3. Fix what drifted. Prefer fixes that cannot rot again: replace counts
   with "see <file> for the current list", link the authoritative file
   instead of restating its contents.
4. Check status headers: a plan whose own completion criteria are met
   should be marked frozen per the policy in `docs/README.md`; a
   "known debts" entry describing code that no longer exists should be
   marked retired with the date, matching the sibling entries' style.
5. For invariant-type claims that look wrong, do not silently "fix" the
   doc: the code is the source of truth, but a disagreement may be a
   code bug. Verify deeply, then either fix the doc with evidence or
   raise the discrepancy.

Sweep order when doing general maintenance: the AGENTS.md files, then
docs/README.md's reading list, then the doc nearest the most recent
refactor (git log tells you where the churn was).

Conventions for any doc fix: ASCII only, concise, state invariants and
reasons rather than restating code structure, and update docs in the
same change as the code that invalidated them.
