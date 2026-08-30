---
name: rodney-sandbox-setup
description: Provision and verify a working `rodney` (simonw/rodney — Go CLI that drives a persistent headless Chrome over the DevTools protocol) install inside this kind of network-sandboxed, container-based dev environment. Handles the Chrome for Testing download, the sandbox's TLS MITM proxy, the `--single-process` crash, and persisting env vars across sessions. Use before any task that scrapes or navigates a website with a piloted/headless browser from this sandbox, or whenever a `rodney` command fails with `ERR_CERT_AUTHORITY_INVALID`, `failed to list pages: EOF`, a missing `rodney`/Chrome binary, or a `Blocked by network policy` error while fetching Chrome.
---

# rodney in a sandboxed environment

`rodney` (<https://github.com/simonw/rodney>) is a Go CLI that launches a persistent headless
Chrome and drives it over the DevTools WebSocket protocol (navigate, extract, click, screenshot,
accessibility tree…). It isn't a system package — there's no apt/pip/npm install and no
precompiled binary, so it has to be built from source, and the Chrome it drives has to be
installed by hand in this kind of sandbox.

**What this skill covers**: getting `rodney` and a compatible Chrome running reliably in this
sandbox — nothing about any particular target site. **What it does not cover**: bypassing a target
site's own bot detection (e.g. a WAF flagging Chrome's `HeadlessChrome` User-Agent or
`navigator.webdriver`). That's a constraint of the site, not of the sandbox, and doesn't belong in
a sandbox-provisioning skill — it varies per target and stays documented at the project level
(e.g. `RODNEY_SETUP.md` in `intramuros`, if the project you're in has one).

## Usage

Run the setup script. It is idempotent — safe to call every time, even if `rodney` is already
installed in this sandbox:

```bash
bash ~/.claude/skills/rodney-sandbox-setup/scripts/setup.sh
```

On success, `rodney` and Chrome are installed at persistent locations, `ROD_CHROME_BIN` and `PATH`
are exported for the rest of this session (and written to the sandbox's persistent env file so
future commands and future sessions in this sandbox see them too), and a real smoke test has
confirmed Chrome launches and navigates. The script always leaves Chrome **stopped** afterward —
it hands back a *ready* environment, not a running session; start your own with:

```bash
rodney start --insecure     # --insecure is required in this sandbox, see below
rodney open "<url>"
rodney waitload
rodney text body            # or: rodney html
rodney stop
```

## Why each workaround is needed

- **`apt install chromium` / `chromium-browser` fail**: on Debian/Ubuntu images these are
  transitional packages pointing at a snap, and snap doesn't work in this kind of containerized
  sandbox.
- **`playwright install chromium` is blocked**: it pulls from `cdn.playwright.dev`, which the
  sandbox's default network policy denies. `storage.googleapis.com` (the actual Chrome for Testing
  hosting bucket) is reachable instead — that's what this skill's script downloads from directly.
- **`--insecure` (`-k`) is required for `rodney start`**: the sandbox intercepts all outbound HTTPS
  through a MITM proxy with a locally-generated CA that Chrome doesn't trust natively, so without
  it every navigation fails with `net::ERR_CERT_AUTHORITY_INVALID`. This is specific to this kind
  of sandbox — outside it, `rodney start` without `--insecure` is the normal, more secure default.
- **`--single-process` crashes Chrome**: `rodney` launches Chrome with `--single-process` (its own
  code comments this as "required for screenshots in gVisor/container environments"), but in this
  sandbox it instead makes Chrome die on a `SIGTRAP` during GPU/EGL init (ANGLE/Vulkan
  `VK_KHR_wayland_surface` unsupported). Removing it makes Chrome start in normal multi-process
  mode, which is stable here. The tradeoff, not yet verified either way: screenshots may be less
  reliable without `--single-process` in a gVisor-style sandbox — this skill's scope is text/HTML
  extraction, not screenshots, so it hasn't been a problem in practice.
- **Chrome version is resolved dynamically, not hardcoded**: which external hosts are reachable
  varies *between sandbox instances* (confirmed: `googlechromelabs.github.io` was blocked in one
  sandbox session and reachable in another) — a version pin alone doesn't protect against a stale
  download URL if Google reorganizes the bucket, so the script asks the live "known good versions"
  API first and only falls back to a hardcoded version if that call fails.
- **Chrome for Testing needs system shared libraries the base image doesn't have**: unlike a distro
  `chromium` package, the Chrome for Testing zip ships only the browser itself — no dependency
  metadata, so nothing pulls in `libglib2.0-0`, `libatk1.0-0`, `libnss3`, `libgbm1`, `libx11-6`, and
  a dozen others (`ldd` on the binary shows exactly which). Confirmed by direct testing: a fresh
  sandbox with no prior Chrome/Playwright install is missing every one of them and Chrome fails
  immediately with `error while loading shared libraries`. The script installs them via `apt`
  (candidate package names covering Ubuntu's `t64` SONAME-transition renaming, since the exact name
  varies by release) and re-checks with `ldd` afterward — the real pass/fail signal, not the apt
  package name.
- **The smoke-test target had to be a real `http(s)://` URL, not `about:blank`**: verified directly
  — this rodney/go-rod/Chrome combination rejects `about:blank` and `data:` URIs at page-creation
  time with CDP error `-32000 Cannot navigate to invalid URL`, before any navigation happens. A real
  URL (`https://example.com`) works. This does reintroduce an external dependency, but a
  network-policy block doesn't break the test: the sandbox's proxy answers a blocked request with an
  HTML page instead of failing the connection, so navigation still completes and still proves
  Chrome/rodney/the patch all work — a blocked body is logged as a note, not treated as failure.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `net::ERR_CERT_AUTHORITY_INVALID` | Chrome doesn't trust the sandbox's MITM proxy CA | Make sure `rodney start` was called with `--insecure` (`-k`) |
| `error: failed to list pages: EOF`, Chrome process disappears after `rodney open` | `--single-process` regression (rebuilt binary without the patch, or upstream `rodney` changed) | Re-run `scripts/setup.sh`; if it still fails, the patch may no longer apply cleanly — see "If the patch stops applying" below |
| `rodney`/Chrome binary missing, or `command not found: rodney` | Never installed in this sandbox, or `PATH`/`ROD_CHROME_BIN` not loaded in this shell | Run `scripts/setup.sh`; if it was already run in a *previous* session of the same persistent sandbox, check `/etc/sandbox-persistent.sh` is actually being sourced |
| `Blocked by network policy: domain <host>` (while downloading Chrome, cloning rodney, or navigating a real target site) | The sandbox's outbound firewall denies that host by default | Ask the user to run, **on the host** (not in the sandbox): `sbx policy allow network <host>`. For rodney/Chrome setup itself this should only ever be `github.com` or `storage.googleapis.com` — a blocked *target site* during actual scraping is a separate, expected per-project ask |
| Chrome for Testing download 404s | The resolved version doesn't exist at that path in the bucket | Re-run — the script re-resolves the version each time; if the live version API itself is unreachable, it falls back to a known-good hardcoded version instead |
| `error while loading shared libraries: lib*.so.*: cannot open shared object file` | Chrome for Testing's zip has no dependency metadata — a fresh base image is missing the system libraries it needs (glib, atk, cairo, pango, X11, nss…) | Re-run `scripts/setup.sh` — it runs `ldd` on the Chrome binary and `apt install`s whatever's missing. If it's still missing after that, `sudo` may not be available/passwordless in this sandbox; install the libraries `ldd` lists manually |
| `panic: {-32000 Cannot navigate to invalid URL}` | `about:blank` / `data:` URIs aren't accepted as a CDP navigation target by this rodney/go-rod/Chrome combination | Use a real `http(s)://` URL instead — this is what the script's own smoke test does |

### If the patch stops applying

`scripts/setup.sh` pins `rodney` to a specific commit and applies
`patches/remove-single-process.patch` with `git apply`, which fails loudly (not silently) if
upstream's `main.go` has changed around `launcher.New()` in `cmdStart`. If that happens:

1. Clone `simonw/rodney` fresh and look at `cmdStart` in `main.go` for the `launcher.New()...Set(...)` chain.
2. Regenerate the patch with `Set("single-process")` removed (keep every other flag).
3. Update `RODNEY_COMMIT` in `scripts/setup.sh` to the new pinned commit and overwrite
   `patches/remove-single-process.patch`.
