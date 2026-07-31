# Architecture and ownership

## Scope

This guide describes source ownership and dependency direction. Exact cross-adapter behavior
belongs to the [canonical Conformance Contract](../contract/docs/index.md).

## Modules

| Module | Owns | Allowed dependency direction |
| --- | --- | --- |
| Browser Client | Private framework-neutral JavaScript/CSS and its provider interface | Depends on no adapter or framework |
| Conformance Contract | Normative schemas, scenarios, fixtures, transcripts, prompt goldens, and contract prose | Depends on no implementation and generates no runtime code |
| Rails Adapter | Rails integration, its source provider, package metadata, native runtime, and generated assets | Build-time Browser Client input; test-time Contract input only |
| Phoenix Adapter | Phoenix integration, its source provider, package metadata, native runtime, and generated assets | Build-time Browser Client input; test-time Contract input only |
| Examples | Public package usage demonstrations | Each example may use only its matching adapter |
| Root tooling | Asset composition, conformance orchestration, package inspection, and version checks | May inspect every module; contains no product runtime behavior |

The machine-readable declaration is [`tooling/ownership.json`](../tooling/ownership.json), and
`tooling/verify_architecture.rb` enforces the critical negative dependencies.

## One-way composition

```text
Browser Client source ----> root asset builder <---- adapter ContextProvider
                                     |
                                     v
                         adapter-owned generated asset

Conformance Contract ----> adapter tests (eventual)
Rails Adapter -----------> Rails ERB/Turbo example
Phoenix Adapter ---------> Phoenix controller-HEEx/LiveView example
```

There is no shared Ruby or Elixir runtime. The adapters never load one another. Generated browser
assets are package-owned build outputs and are checked against their private source inputs.

Rails serving processes are reload- and fork-safe clients of one gem-packaged external broker keyed
by canonical checkout and OS user. The broker alone owns Pi and shared state; OS locking and a
versioned Unix-socket identity handshake converge Puma workers, phased replacements, and concurrent
servers without a process-local fallback. Phoenix retains its separate OTP-supervised ownership.
Both adapters resolve shared server-owned settings at startup and compile or boot all routes, assets,
and Pi ownership out unless native framework development mode is active. The exact fields and
semantics remain in the canonical contract.

## Version ownership

The root [`VERSION`](../VERSION) is the canonical semantic product version. Ecosystem metadata and
generated browser bootstraps repeat that value only where packaging requires it; verification
rejects drift.
