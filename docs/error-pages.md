# Application error pages

The application owns its error-page content, language and styling. Provide an
HTML 404 page with the application's visual identity and useful links back to
its home page or main content. Do not return HTTP 200 for a missing resource.
Keep JSON/API errors machine-readable; never replace them with an HTML shell.

Serve the error page when a router route is missing and when a controller
cannot find a requested resource. The page must not require a working database,
a signed-in account, or a successful application request to render. Avoid
exposing the failing path or exception details without escaping.

A reverse proxy should preserve the application's own error response. If an
infrastructure fallback is necessary, each app may supply a self-contained
static page matching its style. Do not intercept every app error to impose a
harness-branded page, and do not redirect a missing URL to the home page.

Verify an unknown URL and a missing domain resource, actual 404 status,
readable desktop/mobile rendering, useful working links, and the JSON error
representation. Keep sensitive routes and secrets out of captures.

Run `mix cd.update_agents` at initial adoption and after a package upgrade.
Its managed consumer block remains two short lines; this document holds the
implementation detail. Normal compilation/tests never inject guidance.
