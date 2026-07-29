# Research: persistent Pi RPC ownership under Rails development servers

## Summary
A Rails engine can keep a child alive **per Ruby server process**, but Rails reload hooks are not a process-lifecycle boundary and cannot provide one project-wide owner when Puma has workers, overlapping phased workers, or more than one server invocation. The documented Rails mechanism is an idempotent `to_prepare` registration/reconciliation point; durable process lifetime needs either a Puma master-level integration or an external, project-scoped broker guarded by an OS lock and reached through a Unix socket.

For development, a direct in-process owner is supportable only for Puma single-process mode and must be deliberately treated as per-process. A master bridge or external broker is required for the stated “one conversation per project” property where clustered/phased modes are in scope; an external broker is the only option that also naturally survives replacement of the Puma master.

## Findings

1. **Rails reload callbacks are not start/stop ownership hooks (high confidence).** `Rails.application.reloader.to_prepare` / `ActiveSupport::Reloader.to_prepare` runs at boot and on every reload, and Rails explicitly requires its body to be idempotent. It is suitable for (re)installing a reference or checking an already-owned service, not unconditional spawn/teardown. Initializers run during boot rather than each reload. `to_run`/`to_complete` bracket reload work and are likewise reloader callbacks, not server shutdown callbacks. [Rails API/source, v7.1.3](https://github.com/rails/rails/blob/v7.1.3/activesupport/lib/active_support/reloader.rb) · [Rails autoloading guide, “to_prepare”](https://guides.rubyonrails.org/v7.1.3/autoloading_and_reloading_constants.html#reloading-and-stale-objects) · [Rails initialization guide](https://guides.rubyonrails.org/v7.1.3/initialization.html)

2. **Keep the owner object non-reloadable; do not let it retain reloadable application objects (high confidence).** Rails documents `autoload_once_paths` for code that is not reloaded and warns that non-reloadable code must not cache reloadable classes/objects, because stale objects result. A small owner/client interface loaded once may live there (or be explicitly required during boot); callbacks can resolve current reloadable behavior at use time. This gives continuity across Rails reloads *in the same VM*, not across Puma workers or server replacement. [Rails autoloading guide, autoload-once paths](https://guides.rubyonrails.org/v7.1.3/autoloading_and_reloading_constants.html#config-autoload-once-paths)

3. **Puma topology defines the maximum scope of an in-process owner (high confidence).** Threaded requests share a process and therefore require serialization of a single stdio RPC conversation. Puma workers are OS processes; each has separate Ruby globals, locks, and child table. `preload_app!` loads the application before worker fork, so opening/spawning the RPC process before fork is unsafe: inherited IO/threads and duplicated ownership can result. Puma exposes master/worker hook DSL entries including `on_booted`, `on_thread_start`, `on_worker_boot`, and `on_worker_shutdown`; hook timing is configured by Puma, not Rails. [Puma hook DSL source, v6.4.2](https://github.com/puma/puma/blob/v6.4.2/lib/puma/dsl.rb) · [Puma cluster implementation, v6.4.2](https://github.com/puma/puma/blob/v6.4.2/lib/puma/cluster.rb) · [Puma configuration reference](https://puma.io/puma/Puma/DSL.html)

4. **Phased restart is specifically incompatible with `preload_app!` and overlaps worker generations (high confidence).** Puma’s restart documentation says phased restart is unavailable with `preload_app!`; its purpose is to replace workers gradually. Thus even a correct worker-owned singleton has more than one instance during a phased cycle. A master-owned process can remain singular while the same master remains alive, but it must proxy IPC for workers; a process restart/new master still needs external coordination if project-wide continuity is desired. [Puma restart documentation](https://github.com/puma/puma/blob/v6.4.2/docs/restart.md) · [Puma launcher/restart source, v6.4.2](https://github.com/puma/puma/blob/v6.4.2/lib/puma/launcher.rb)

5. **Three realistic ownership shapes have materially different guarantees (high confidence for process facts; medium for Puma hook operational details).**

   | Shape | Reload / threaded | Cluster / phased | Preload | Shutdown & main limitation |
   |---|---|---|---|---|
   | Rails-process owner | Persist in one VM; mutex/queue required | One child per worker; duplicates during phased replacement | Spawn only after fork | Ruby `at_exit`/signal cleanup is best-effort; not project-scoped |
   | Puma-master owner plus local proxy | Rails reload does not affect it; workers use socket/proxy | One owner per Puma master, so works across that master’s workers | Do not construct app-dependent resources before fork | Puma configuration/hook integration, proxy protocol, and master restart handling required |
   | External project broker (PID/lock + Unix socket) | Rails is client only; reload-safe | Shared by all local server processes and generations | Independent | Explicit broker lifecycle/reaper required; strongest practical project scope |

   The first uses only Rails/Ruby public APIs but does not satisfy project scope beyond one process. The second relies on documented Puma configuration API but couples the engine deployment to Puma configuration. The third uses standard OS/Ruby primitives and is topology-independent, at the cost of a separate supervisor protocol. No option should claim a global singleton without defining “project” (canonical project path/runtime directory) and the set of participating server invocations.

6. **Duplicate prevention and crash recovery must be OS-visible, not a Ruby class variable (high confidence).** `Mutex` protects only threads in one VM. For a broker/master launcher, take an advisory exclusive `File#flock` on a project runtime lock, re-check a state record while holding it, validate the recorded PID/socket using a connect-and-protocol handshake, then spawn and atomically publish endpoint metadata. A PID alone is unsafe (PID reuse); the handshake should include a freshly generated instance token. On connection EOF or failed health check, exactly one contender obtains the lock and replaces the child with bounded exponential backoff. `Process.spawn` provides a child PID and supports a separate process group (`pgroup: true`); `waitpid(..., WNOHANG)` observes exit without blocking. [Ruby `File#flock`](https://docs.ruby-lang.org/en/3.2/File.html#method-i-flock) · [Ruby `Process.spawn`](https://docs.ruby-lang.org/en/3.2/Process.html#method-c-spawn) · [Ruby `Process.waitpid`](https://docs.ruby-lang.org/en/3.2/Process.html#method-c-waitpid)

7. **RPC I/O needs one writer/reader authority and explicit cancellation semantics (high confidence).** `Open3.popen3` supplies dedicated stdin/stdout/stderr and a wait thread; do not have request threads concurrently write/read a line-oriented conversation. Put framing, pending-request map, and a mutex/queue in the owner/proxy; establish whether Pi allows request multiplexing before allowing parallel calls. Cancellation should first use Pi’s protocol cancellation if it exists; otherwise cancel local waiters, close the child pipes to unblock readers, send `TERM` to the child process group, wait with a deadline, then `KILL` as a last resort and reap. `at_exit` is a fallback, not proof of graceful cleanup (it is bypassed by fatal termination such as `SIGKILL`). [Ruby `Open3.popen3`](https://ruby-doc.org/3.2.2/stdlibs/open3/Open3.html#method-c-popen3) · [Ruby process groups / `kill`](https://docs.ruby-lang.org/en/3.2/Process.html#method-c-kill) · [Ruby `Kernel#at_exit`](https://docs.ruby-lang.org/en/3.2/Kernel.html#method-i-at_exit)

8. **Graceful shutdown should be owned at the level that spawned the process (high confidence).** A worker-owned child should be stopped from Puma’s worker shutdown lifecycle; a master-owned child from the master’s shutdown/restart lifecycle; a broker from its own signal handlers. Closing stdin and allowing a bounded graceful exit precedes group termination/reap. Never rely on Rails reload completion to kill it: reload can occur while requests run, and it is unrelated to Puma shutdown. Puma hook names are public configuration surface, but the exact ordering/coverage for every signal should be integration-tested against the deployed Puma version rather than inferred from a Rails engine. [Puma DSL source, v6.4.2](https://github.com/puma/puma/blob/v6.4.2/lib/puma/dsl.rb) · [Puma launcher source, v6.4.2](https://github.com/puma/puma/blob/v6.4.2/lib/puma/launcher.rb)

9. **Test the lifecycle behind injected boundaries (high confidence).** Unit-test an owner with injected spawner, clock/sleeper, endpoint store, and transport: idempotent ensure; simultaneous ensure; EOF/abnormal exit; backoff; cancellation; TERM→KILL deadline; and stale PID/token. Use a dummy Rails app to assert `to_prepare` does not spawn twice across a reload. Run Puma integration fixtures in (a) no-workers threaded, (b) workers, (c) `preload_app!`, (d) phased restart where supported, and (e) normal shutdown; assert child PIDs/process groups and socket instance token, not log messages. Ruby’s standard library supports running a controlled fixture child through `Open3`/`Process`; no real Pi binary should be required for these tests. [Rails reloader source](https://github.com/rails/rails/blob/v7.1.3/activesupport/lib/active_support/reloader.rb) · [Puma test/config fixture patterns](https://github.com/puma/puma/tree/v6.4.2/test)

## Documented API vs. implementation detail

- **Documented/public:** Rails `to_prepare` and autoload-once guidance; Ruby `Process`, `File#flock`, `Open3`, `at_exit`; Puma configuration hook DSL and worker/preload configuration.
- **Use with version-pinned verification:** exact Puma hook ordering, whether a particular hook executes in master versus worker, and signal/restart sequencing. The cited `v6.4.2` source is evidence for that release, not a Rails-level contract.
- **Do not depend on:** Rails reloader internals/callback ordering beyond the public callback intent; object retention caused incidentally by constant loading; Ruby process globals after fork; or PID existence as liveness/identity.

## Confidence and unresolved gaps

**Confidence:** high that Rails reload cannot be the sole lifecycle owner and that a Ruby process-local singleton cannot cross Puma workers; high for Ruby spawn/lock/reap mechanics; medium for a particular Puma hook matrix until the project pins its Puma version and tests it.

**Gaps / verification needed:**
1. Pi’s RPC specification was not supplied. Confirm framing, concurrency/multiplexing, protocol-level cancel/quit, session persistence, and whether a Unix-socket proxy is permissible before selecting a proxy/broker shape.
2. Identify the project’s exact Puma version and launch paths (`bin/dev`, `rails server`, `puma`, Docker) and verify hook execution with a fixture. Puma 6.4.2 links above are durable evidence, not a guarantee for another version.
3. Define project identity/runtime-directory permissions and policy for stale broker recovery after crashes, laptop sleep, or two checkouts sharing a directory.
4. Decide desired behavior when Pi is absent, upgrade changes protocol, or restart backoff is exhausted; these are product policy rather than framework facts.

## Sources

- Kept: Rails 7.1.3 reloader source (https://github.com/rails/rails/blob/v7.1.3/activesupport/lib/active_support/reloader.rb) — primary lifecycle callback behavior.
- Kept: Rails 7.1.3 autoloading/reloading guide (https://guides.rubyonrails.org/v7.1.3/autoloading_and_reloading_constants.html) — documented reload/idempotence and autoload-once constraints.
- Kept: Puma 6.4.2 DSL/cluster/launcher source (https://github.com/puma/puma/tree/v6.4.2/lib/puma) — version-pinned master/worker/hook evidence.
- Kept: Ruby 3.2 Process, File, Kernel API (https://docs.ruby-lang.org/en/3.2/Process.html) — primary spawn, signal, reap primitives.
- Kept: Ruby 3.2 Open3 API (https://ruby-doc.org/3.2.2/stdlibs/open3/Open3.html) — primary stdio child-process interface.
- Dropped: generic Rails/Puma blog posts — secondary and commonly omit fork/phased-restart boundaries.

## Acceptance report

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Concrete lifecycle, ownership, duplicate-prevention, cancellation, shutdown, and test findings are recorded in docs/research/rails-pi-rpc-ownership.md (artifact path below), with severity/confidence and primary-source URLs."
    }
  ],
  "changedFiles": [
    "/home/davelens/Repositories/davelens/recollect-elixir/.pi-subagents/artifacts/outputs/4578bd92-69e0-4120-a44c-35ec9ef0d38c/docs/research/rails-pi-rpc-ownership.md",
    "/home/davelens/Repositories/davelens/recollect-elixir/.pi-subagents/artifacts/progress/4578bd92-69e0-4120-a44c-35ec9ef0d38c/progress.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "not run (research-only artifact task; no shell execution tool available)",
      "result": "not-run",
      "summary": "No implementation or test suite was changed."
    }
  ],
  "validationOutput": [
    "Required research artifact written to the authoritative output path.",
    "Brief includes durable Rails 7.1.3, Puma 6.4.2, and Ruby primary-source URLs."
  ],
  "residualRisks": [
    "Pi RPC protocol/cancellation/session behavior remains unverified because no primary Pi RPC specification was supplied.",
    "Puma hook ordering and restart behavior must be fixture-tested against the project-pinned Puma version and launch configuration.",
    "An in-process owner cannot meet project-wide singleton semantics across workers or separate server processes."
  ],
  "noStagedFiles": true,
  "diffSummary": "Added research artifact and progress update only; no implementation code modified.",
  "reviewFindings": [
    "high: Rails reload callbacks are not process-lifecycle hooks; spawning unconditionally in to_prepare causes duplicate-risk.",
    "high: per-process Ruby state cannot enforce one Pi child across Puma workers/phased overlap.",
    "medium: Puma hook ordering is version/configuration-sensitive and requires integration verification."
  ],
  "manualNotes": "This is evidence gathering only and intentionally makes no product architecture decision."
}
```
