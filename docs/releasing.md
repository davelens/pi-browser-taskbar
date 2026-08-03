# Coordinated release preparation

Release preparation and publication are separate. The **Prepare coordinated release** workflow is the
only normal preparation entry point. Dispatch it with the full SHA of the current protected `main`;
tag pushes do not prepare a release. It performs no registry write.

## Prerequisites

The selected commit must have successful `Verify`, complete Rails compatibility, and complete Phoenix
compatibility checks. Preparation then runs `bin/verify` from a clean checkout, reproduces committed
Browser Client assets and staged documents, builds each candidate artifact once, inspects package
allowlists and denylists, exercises clean artifact-installed examples without workspace fallback,
uses a fixed archive timestamp, and compares the candidate bytes with two clean deterministic
rebuilds.

The release version must be absent from both RubyGems and Hex. A response other than an authoritative
not-found result stops preparation without a write. Publication and reconciliation remain separate
release operations.

## Human evidence

Automation cannot satisfy the first-release human gates. Before dispatch, record sanitized JSON in:

- `release/evidence/accessibility.json`, after completing the checklist in
  [Browser and accessibility acceptance](accessibility-acceptance.md); and
- `release/evidence/real-pi.json`, after a real-Pi task and cancellation flow in each clean
  artifact-installed example.

Both records contain `product_version`, `result` (`passed`), `tester`, `date`, `examples` (`rails` and
`phoenix`), and `artifacts`, mapping each adapter to the exact candidate SHA-256. Accessibility
records also contain a non-empty `pairing` describing OS, assistive technology, and browser versions.
Real-Pi records contain `flows` for each adapter with `task` and `cancellation`.
Sanitized observations may be added, but never prompts, page context, credentials, provider output,
or absolute paths. Missing, stale, malformed, or non-passing evidence fails actionably; do not create
a placeholder pass.

No manual evidence is currently recorded, so release preparation remains intentionally blocked.

## Preserved candidate

After every gate passes, one process writes `SHA256SUMS`, `release-manifest.json`, and
`RELEASE_NOTES.md` beside the exact gem and Hex tarball. The manifest records product and contract
versions, source repository/ref/commit, workflow run and attempt, build-tool versions, artifact bytes
and SHA-256 values, package metadata and file lists, committed/packaged generated-asset digests, and
SHA-256 values for automated, clean-example, commit-check, and human acceptance inputs.

`actions/upload-artifact` preserves that run-specific directory as an immutable workflow artifact for
the repository's configured retention period. The same files are attached to an unpublished draft
GitHub Release for durable preparation handoff, including the preserved Hex documentation archive and
an initial `prepared` state checkpoint. A pre-existing release name stops the workflow rather than
mixing runs or commits. No tag is created or release announced by preparation; publication reuses
these bytes and this manifest.

## Publish, resume, and verify

Configure a protected `coordinated-release` GitHub environment with required reviewers. Store one
Hex API key limited to package and documentation publication as its `HEX_API_KEY` secret, and register
the **Publish, resume, or verify coordinated release** workflow as the RubyGems Trusted Publisher for
`pi-browser-taskbar-rails`. Add a dedicated write deploy key whose private half is stored only as the
environment secret `RELEASE_TAG_DEPLOY_KEY`; grant deploy keys the sole bypass in an active `v*` tag
ruleset that restricts tag creation, updates, and deletion. The workflow uses that key only for
protected publication operations. It receives its RubyGems credential through GitHub OIDC; do not
store a RubyGems API key.

Dispatch the workflow with the prepared source commit and `publish-resume`. It validates the draft and
manifest, then handles Hex package, Hex documentation, and RubyGems in that order. Every step queries
first, writes only an absent preserved artifact, polls with bounded retries, compares public bytes and
metadata, and performs a clean public fetch or install. It uploads `release-state.json` after
`hex_package_verified`, `hex_docs_verified`, `rubygems_verified`, `tagged`, and `announced`.

A timeout stops without repeating a write. Dispatch `publish-resume` again: it downloads the same
draft, accepts only an identical public artifact, and continues with the missing step. A checksum or
metadata mismatch stops for incident handling. If publication is already partial and a permanent
failure is recorded, do not yank, replace, rebuild, or bypass the state; document the incomplete
version and prepare the next coordinated patch. `verify` is read-only and rechecks the public package,
documentation, gem, tag, and announcement implied by the durable state.

The annotated `vVERSION` tag and draft-to-public GitHub Release transition occur only after a fresh
verification of all three public registry surfaces. Both operations reconcile exact existing state,
so an ambiguous tag or announcement result is safe to resume.

## Constrained break-glass resume

Use `break-glass-resume` only when `release-state.json` is missing from an otherwise intact prepared
draft. Supply the exact SHA-256 of `release-manifest.json` and a non-empty incident or change reference.
The operation reconstructs only `prepared`, records the reason, and runs the same protected
reconciliation and announcement gates. It cannot replace artifacts, rebuild bytes, skip a registry
check, clear an incomplete record, or operate on a different source commit.

Release output intentionally omits credentials, registry response bodies, command output, and absolute
paths. Errors identify the failed public surface and whether an operator should resume or begin
incident handling.
