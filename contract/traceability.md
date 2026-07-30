# Requirement traceability index

This index maps every normative section of [parent specification #17](https://github.com/davelens/pi-browser-taskbar/issues/17) to one canonical owner and an eventual acceptance seam. `Foundation` means issue #18 establishes executable evidence; `Future` names the seam a later tracer bullet must complete. The machine-readable source is [`traceability.json`](traceability.json).

[Issue #25](https://github.com/davelens/pi-browser-taskbar/issues/25) covers Shared task API, Pi RPC lifecycle, Browser Client interaction, and both adapter rows through shared cancellation HTTP scenarios, the accepted-abort transcript, native tests, and packaged cross-adapter conformance. [Issue #26](https://github.com/davelens/pi-browser-taskbar/issues/26) extends those rows with confirmed in-process session reset, retained-state rejection, recovery-only process replacement, shared reset scenarios/transcripts, and Browser Client draft/focus preservation.

| Normative section | Owner | Eventual acceptance seam | Status |
| --- | --- | --- | --- |
| Problem Statement | Root tooling | Clean-checkout root verification and packaged-adapter acceptance | Foundation |
| Solution | Root tooling | Coordinated Rails and Phoenix package artifact inspection | Foundation |
| User Stories | Conformance Contract | Versioned contract scenarios mapped to adapter and browser acceptance | Future |
| Product and distribution | Root tooling | Self-contained gem and Hex package built at one root version | Foundation |
| Ownership boundaries | Root tooling | Machine-readable dependency graph and negative coupling checks | Foundation |
| Shared task API | Conformance Contract | Identical black-box HTTP scenarios against both packaged adapters | Adapter slices |
| Pi RPC lifecycle | Conformance Contract | Transcript replay through the deterministic fake Pi peer | Foundation |
| Normalized browser task context | Conformance Contract | Valid and invalid context fixtures parsed independently by both adapters | Adapter slices |
| Source-hint contract | Conformance Contract | Cross-adapter source classification fixtures plus native attribution tests | Adapter slices |
| Bounds, truncation, and normalization | Conformance Contract | Golden bounded-context fixtures compared across native validators | Adapter slices |
| Browser Client interaction | Browser Client | Browser-owned DOM tests and packaged example end-to-end flows | Adapter slices |
| Security and configuration | Conformance Contract | Framework-native access, CSRF, activation, and startup validation tests | Adapter slices |
| Rails Adapter | Rails Adapter | Built-gem clean-application integration and broker topology tests | Rails slice |
| Phoenix Adapter | Phoenix Adapter | Built-Hex clean-application integration and supervision tests | Phoenix slice |
| Documentation and examples | Root tooling | Documentation checks and examples installed only from built artifacts | Future |
| Versioning and coordinated release | Root tooling | Version drift, immutable artifact, checksum, and registry reconciliation gates | Foundation |
| Implementation sequence and change control | Root tooling | Traceability and clean vertical-slice gates before dependent work | Foundation |
| Test philosophy and primary seam | Conformance Contract | Behavior exercised at packaged adapter interfaces | Foundation |
| Shared Conformance Contract | Conformance Contract | Schema, fixture, scenario, transcript, and golden validation | Foundation |
| Browser Client | Browser Client | Fast browser module tests and cross-browser packaged example flows | Adapter slices |
| Accessibility | Browser Client | Automated WCAG checks, keyboard flows, and recorded assistive-technology pass | Future |
| Rails-native integration | Rails Adapter | Rails installer, engine, CSRF, attribution, and broker process tests | Rails slice |
| Phoenix-native integration | Phoenix Adapter | Phoenix installer, Plug, CSRF, attribution, and OTP isolation tests | Phoenix slice |
| Compatibility matrix | Root tooling | Published matrix synchronized to clean generated application CI rows | Future |
| Examples, artifacts, documentation, and release | Root tooling | Packaged example, artifact content, documentation, and release rehearsal gates | Future |
| Out of Scope | Conformance Contract | Contract and architecture review rejects accidental unsupported interfaces | Foundation |
