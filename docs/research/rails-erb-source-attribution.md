# Research: reliable ERB source attribution on Rails 7.1+

## Summary
Rails 7.1 has a purpose-built, supported development switch for this: `config.action_view.annotate_rendered_view_with_filenames = true`. Its built-in ERB handler places begin/end HTML comments around rendered HTML template output, providing reliable *render-range-to-template-file* attribution for ERB layouts, templates, and partial invocations without replacing ERB or patching Action View; collection occurrence behavior still needs a fixture check. Rails notifications and template metadata are useful observability/correlation inputs, but cannot themselves put markers into the response or attribute every DOM element exactly.

**Confidence:** high for filename comment annotations and the documented notification payloads; medium for any design that consumes the non-public current-template stack or compiler internals.

## Findings

1. **Supported HTML-level mechanism: filename annotations (high confidence).** Rails documents `config.action_view.annotate_rendered_view_with_filenames`, defaulting to `false`; when enabled, rendered ERB HTML output is bracketed by filename comments. The implementation is in the built-in ERB handler: when the setting is enabled and `template.format == :html`, Rails compiles `<!-- BEGIN … -->` and `<!-- END … -->` writes around the template output using `template.short_identifier`. This covers ERB layouts, ordinary templates, and partial render invocations without replacing the handler; collection occurrence behavior should still be fixture-tested. It is appropriate for development/debugging, not a production response contract. [Config guide](https://guides.rubyonrails.org/v7.1/configuring.html#config-action-view-annotate-rendered-view-with-filenames) · [Rails 7.1 source: ERB handler](https://github.com/rails/rails/blob/v7.1.0/actionview/lib/action_view/template/handlers/erb.rb#L84-L87) · [Rails 7.1 source: Action View setting](https://github.com/rails/rails/blob/v7.1.0/actionview/lib/action_view/base.rb#L162-L163)

2. **Annotations identify a rendered range, not an exact originating element or ERB line (high confidence).** The comments delimit template-produced string output and can nest. They do not establish a one-to-one relation between DOM nodes and ERB expressions: one ERB template can emit many elements; helpers/components can emit HTML; a template can render only another template; and browser HTML parsing can move/repair nodes. Repeated collection renders have the same partial filename (although each occurrence/range can be observed); filename annotation has no documented collection index, local value, source line/column, or expression identifier. The practical fallback is therefore nearest enclosing annotation range, exposed as **template-level attribution**; show an “ambiguous/generated output” state for nodes outside a range or produced across boundaries.

3. **Documented render notifications provide reliable render-operation metadata, not response mutation (high confidence).** Rails documents `render_template.action_view` (`identifier`, `layout`, `locals`), `render_partial.action_view` (`identifier`, `layout`, `locals`), and `render_collection.action_view` (`identifier`, `count`, `cache_hits`). Subscribe through the supported `ActiveSupport::Notifications` API to collect timing/correlation data or verify what rendered. The renderer source shows these events are emitted at template/partial/collection renderer boundaries. A subscriber observes an event and its payload; it has no supported handle for inserting bytes into the already-produced template buffer. Thus notifications complement comments but cannot create exact HTML offsets by themselves. [Instrumentation guide](https://guides.rubyonrails.org/v7.1/active_support_instrumentation.html#action-view) · [Notifications API](https://api.rubyonrails.org/v7.1.0/classes/ActiveSupport/Notifications.html) · [template renderer](https://github.com/rails/rails/blob/v7.1.0/actionview/lib/action_view/renderer/template_renderer.rb) · [partial renderer](https://github.com/rails/rails/blob/v7.1.0/actionview/lib/action_view/renderer/partial_renderer.rb) · [collection renderer](https://github.com/rails/rails/blob/v7.1.0/actionview/lib/action_view/renderer/collection_renderer.rb)

4. **Template objects expose source identity, but using render-stack state is internal (medium confidence).** `ActionView::Template` exposes identifying metadata such as `identifier`, `virtual_path`, `format`, and `handler`; renderer notification payloads draw on that identity. These can form a server-side source registry, with `identifier` serving as the filesystem reference (avoid exposing absolute paths to an untrusted browser; map it to an application-relative ID). In contrast, relying on Action View's current-template/render-stack bookkeeping or `!render_template.action_view` is source-level/internal behavior, not a documented integration surface. Do not make it a compatibility requirement. [Template API](https://api.rubyonrails.org/v7.1.0/classes/ActionView/Template.html) · [Rails 7.1 source: template.rb](https://github.com/rails/rails/blob/v7.1.0/actionview/lib/action_view/template.rb)

5. **Replacing or further instrumenting the ERB handler is not a safe exact-attribution extension point (medium-high confidence).** Rails already uses the built-in ERB handler to add the documented template-range comments. Although Rails has public template-handler registration (`ActionView::Template.register_template_handler`), globally replacing `:erb` to gain finer attribution would have to reproduce escaping, trim mode, encoding, buffer, streaming, error-location, and Rails-version behavior. More importantly, the handler sees template source/compiled output, not a durable mapping from arbitrary ERB expressions to final browser DOM nodes. The built-in comments are a supported template-range mechanism; custom handler replacement for exact element mapping remains fragile. [Template handler registration source](https://github.com/rails/rails/blob/v7.1.0/actionview/lib/action_view/template.rb) · [ERB handler source](https://github.com/rails/rails/blob/v7.1.0/actionview/lib/action_view/template/handlers/erb.rb)

6. **Lifecycle/reloader implications: register observers once; make development setup idempotent (high confidence).** Notification subscribers are process-global registrations. Placing `subscribe` in a reloadable class body or an unguarded `to_prepare` callback can create duplicate subscriptions after reloads. Rails documents that `config.to_prepare` runs on boot and before each development reload, and advises idempotent preparation; use it only for reload-sensitive configuration/registry rebuilding, while keeping a global subscription single-shot (or explicitly unsubscribe/re-subscribe). Templates themselves are reloaded/recompiled by Action View in development, so cache any identifier-to-display mapping with invalidation/rebuild on reload rather than retaining template objects. [Autoloading/reloading guide](https://guides.rubyonrails.org/v7.1/autoloading_and_reloading_constants.html#to-prepare) · [Config guide: `to_prepare`](https://guides.rubyonrails.org/v7.1/configuring.html#config-to-prepare-block) · [Template source](https://github.com/rails/rails/blob/v7.1.0/actionview/lib/action_view/template.rb)

## Option comparison

| Option | Supported surface | HTML source refs | Granularity | Principal limitation |
|---|---|---:|---|---|
| `annotate_rendered_view_with_filenames` | Documented config | Yes | Template output range / occurrence | No ERB line/expression or guaranteed DOM-node identity |
| `*.action_view` notifications | Documented instrumentation + API | No | Render invocation; collection aggregate | Cannot alter response; cached/aggregate work limits occurrence detail |
| `ActionView::Template` metadata | Public object metadata | No | Template identity | Needs an independent supported insertion mechanism |
| Current template stack / `!render_*` | Internal source behavior | No | Potential nested render context | Version-sensitive; not suitable as contract |
| Replace ERB handler | Registration method exists; global replacement is invasive | Only if custom code adds it | Potential source-token level | Compiler/escaping compatibility and still no final DOM mapping |

## Sources
- **Kept:** Rails 7.1 configuration guide — documents the filename-annotation switch and its default. <https://guides.rubyonrails.org/v7.1/configuring.html#config-action-view-annotate-rendered-view-with-filenames>
- **Kept:** Rails 7.1 Active Support instrumentation guide — documents Action View event names and payloads. <https://guides.rubyonrails.org/v7.1/active_support_instrumentation.html#action-view>
- **Kept:** Rails v7.1.0 Action View source (`template/handlers/erb.rb`, `base.rb`, and renderer files) — release-tagged implementation evidence for annotation placement, setting ownership, and renderer instrumentation. <https://github.com/rails/rails/tree/v7.1.0/actionview/lib/action_view>
- **Kept:** Rails 7.1 API (`ActionView::Template`, `ActiveSupport::Notifications`) — public API boundary. <https://api.rubyonrails.org/v7.1.0/classes/ActionView/Template.html>
- **Kept:** Rails 7.1 autoloading/reloading guide — `to_prepare` lifecycle evidence. <https://guides.rubyonrails.org/v7.1/autoloading_and_reloading_constants.html#to-prepare>
- **Dropped:** third-party gems/blog posts — they may suggest DOM instrumentation, but do not establish Rails 7.1 supported behavior.

## Gaps
- This review did not execute a Rails 7.1 fixture application, so exact comment spelling, behavior through fragment/collection caching, and behavior after downstream HTML minification should be verified with representative layouts, nested partials, collection partials, and Turbo responses before relying on it operationally.
- Rails does not document a public source-map API from ERB byte/line/expression to final HTML/DOM. Exact element attribution remains unresolved by Rails APIs; use the template-range fallback above rather than infer certainty.
- The sources are pinned to the immutable `v7.1.0` release tag. Rails 7.1.x+ application versions should be smoke-tested because implementation details beyond the documented config/event contracts can change.

## Review findings
- **info — `docs/research/rails-erb-source-attribution.md`:** The documented annotation configuration is the viable no-monkey-patch development mechanism; retain its template-range limitation in any follow-on decision.
- **medium — `docs/research/rails-erb-source-attribution.md`:** Do not treat notification payload timing, internal bang events, or the current-template stack as an HTML attribution API.
- **medium — `docs/research/rails-erb-source-attribution.md`:** Avoid sending raw absolute `Template#identifier` filesystem paths to the browser; map identifiers to a safe project-relative reference.

## Acceptance report
```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Concrete findings and severity-tagged review findings are in docs/research/rails-erb-source-attribution.md; the report covers Rails config, notifications, source files, lifecycle, and fallback limits."
    }
  ],
  "changedFiles": [
    "docs/research/rails-erb-source-attribution.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "No shell/web runtime available in this research subagent",
      "result": "not-run",
      "summary": "Evidence is cited to Rails 7.1 official guides/API and immutable Rails v7.1.0 source URLs."
    }
  ],
  "validationOutput": [
    "Research brief written to the required artifact path.",
    "Primary Rails documentation, API pages, and release-tagged source URLs included."
  ],
  "residualRisks": [
    "Filename annotations provide template output ranges, not an exact ERB-expression-to-DOM-element map.",
    "Fragment caching, HTML minifiers, and browser DOM repair require fixture-app verification.",
    "Raw template identifiers can disclose filesystem paths unless mapped before browser delivery."
  ],
  "noStagedFiles": true,
  "diffSummary": "Added a concise Rails 7.1 source-attribution research brief only; no implementation code was changed.",
  "reviewFindings": [
    "info: docs/research/rails-erb-source-attribution.md - documented filename annotations are the supported no-patch option.",
    "medium: docs/research/rails-erb-source-attribution.md - notifications/internal render stack are not an HTML attribution contract.",
    "medium: docs/research/rails-erb-source-attribution.md - browser-visible raw template identifiers may disclose paths."
  ],
  "manualNotes": "No product decision or implementation code was made; a Rails fixture smoke test remains the recommended follow-up."
}
```
