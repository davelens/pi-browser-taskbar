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
- `release/evidence/real-pi.json`, after a real-Pi task, cancellation, and **New session** flow in each
  clean artifact-installed example.

Both records contain `product_version`, `result` (`passed`), `tester`, `date`, `examples` (`rails` and
`phoenix`), and `artifacts`, mapping each adapter to the exact candidate SHA-256. Accessibility
records also contain a non-empty `pairing` describing OS, assistive technology, and browser versions.
Real-Pi records contain `flows` for each adapter with `task`, `cancellation`, and `new-session`.
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
GitHub Release for durable preparation handoff. A pre-existing release name stops the workflow rather
than mixing runs or commits. No tag is created or release announced by preparation; later publication
must reuse these bytes and this manifest.
