# Environment badging

A staging deployment that looks exactly like production is where someone edits
the wrong site, files a bug against the wrong one, or shows a client a page
that is not real. Badging costs an hour and removes a whole class of confusion.

Three layers, each catching what the one before it misses.

## 1. A sticker on the logo

The visible one. Put it on the mark that appears in every page header, not in
a corner banner people learn to ignore.

Angle it. A tilted tag reads as something applied on top of the product; a
straight bar reads as part of the product and stops being noticed within a day.

```heex
<span class="relative inline-flex">
  <img src={~p"/images/logo.png"} alt="" width="36" height="36" class="size-9" />
  <span
    :if={MyApp.Environment.badged?()}
    class="pointer-events-none absolute -right-3 top-1/4 -translate-y-1/2
           rotate-[-12deg] rounded-[3px] px-1.5 py-0.5 text-[10px] font-black
           uppercase leading-none tracking-wide text-white shadow-sm"
    style={"background: #{MyApp.Environment.badge_colour()}"}
  >
    {MyApp.Environment.label()}
  </span>
</span>
```

Red for staging, blue for local. Staging is the one that looks like production,
so it gets the alarming colour.

## 2. A distinct favicon

The layer that matters when six tabs are open and only 16 pixels of each is
visible. Use the same angled sticker so the tab and the header read as one mark.

An SVG favicon needs no build step:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <!-- your logo -->
  <g transform="rotate(-12 32 20)">
    <rect x="-2" y="11" width="68" height="18" rx="2" fill="#b91c1c"/>
    <text x="32" y="24.5" font-family="Helvetica,Arial,sans-serif" font-size="13"
          font-weight="bold" fill="#ffffff" text-anchor="middle">STAGING</text>
  </g>
</svg>
```

### The part that will catch you

Browsers cache favicons hard, and a stale one is worse than none: the badge is
then confidently wrong. Reference it through the endpoint so it carries the
asset digest and changes whenever the file does.

```elixir
def favicon_path do
  MyAppWeb.Endpoint.static_path(favicon_file())
end
```

A bare `"/images/favicon-staging.svg"` skips the digest entirely. Note that
`static_path/1` only appends a version in production: `cache_static_manifest`
is set in `config/prod.exs` and `mix phx.digest` runs as part of
`mix assets.deploy`. Locally you will see a plain path and that is correct —
which also means you cannot verify the cache-busting in dev, only after a
deploy.

## 3. `X-Robots-Tag` at the edge

A review environment on a real domain can outrank the site it is a copy of.
The `web` role emits this automatically when `app_is_production` is false:

```yaml
# inventory/group_vars/staging/main.yml
app_is_production: false
```

Applied in nginx rather than in the application, so it covers every response —
JSON, PDFs, uploads — not only the HTML pages a template remembers to tag. Add
a `noindex` meta tag in the layout too if you like; belt and braces are cheap
here.

## Wiring it to the deployment

`phoenix_blue_green` already exports a display environment to the release, so
no new variable is needed:

```elixir
# config/runtime.exs
if display_env = System.get_env("MYAPP_DISPLAY_ENV") do
  config :my_app, :display_env, display_env
end
```

Use `if`, not a bare `config`. `runtime.exs` is evaluated after `dev.exs`, so
setting the value unconditionally overwrites whatever local development
established with `nil`, and the badge silently disappears in dev. The same trap
applies to any key both files touch.

Production should carry no badge at all. Treat an unset variable as production
so a forgotten configuration fails towards the quiet, correct default rather
than stamping STAGING across the real site.
