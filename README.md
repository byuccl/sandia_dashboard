# BYU CCL Radiation Test Dashboards

This repo publishes the lab's radiation test dashboards on the web, behind a login, from the lab machine `ccl1`. Each dashboard lives in its own data repository, included here as a git submodule:

| Submodule | Dashboard | Public URL | Local port |
|---|---|---|---|
| (this repo, `picker/`) | Picker page linking to each dashboard | https://test-results.byuccl.org/ | 8080 |
| `sandia_sram_data_2026_10` | SRAM, TAMU October 2026 | https://tamu-sram-2026.byuccl.org/ | 8051 |
| `sandia_stc_data_2026` | STC, TAMU May 2026 | https://tamu-stc-2026.byuccl.org/ | 8052 |
| `sandia_combined_data_2026_06_sanitized` | SRAM, STC and STM32, LMTF Medusa June 2026 (dose rate) | https://lmtf-combined-2026.byuccl.org/ | 8053 |

To add another, see [Adding a dashboard](#adding-a-dashboard).

## Day-to-day use

Everything runs as systemd services. They start at boot and restart if they crash, so nothing needs to be left open in tmux.

```bash
make status    # service state, plus a local and public check of each site
make restart   # restart everything, e.g. after pulling dashboard code changes
make logs      # follow the logs of all services
```

In `make status`, each site should show `LOCAL 200` (the server is answering on this machine) and `PUBLIC 302` (the public URL redirects to the Cloudflare login page).

Where each dashboard gets its data:

- **SRAM** reads the tester data committed in the submodule's `sram/` folder: `sram/data.csv`, `sram/golden_mem/`, and `sram/shot_mem/`. `shot_mem/` holds the decoded shot captures; it is git-ignored and about 5 GB. After pulling new data into the submodule, decode the new shots. Only shots without a `.mem` are decoded, and the dashboard picks them up without a restart:

  ```bash
  make -C sandia_sram_data_2026_10 decode_shots
  ```

  Decoding needs the `main` branch of `sandia-dynamic-tester` installed in the SRAM virtualenv. On `ccl1` that's a separate worktree at `~/sandia-dynamic-tester-main`, so the regular checkout can stay on any branch. Create the virtualenv with `make -C sandia_sram_data_2026_10 env DVT_REPO_PATH=~/sandia-dynamic-tester-main`.
- **STC** reads the submodule's `from_remote/` folder, as written by its `otv_sync`.
- **June (combined)** is one dashboard for all three boards. It finds each run's board by which folder holds its `.mem`: `sram/post_mem/`, `stc/mem/` or `stm32/mem/`. Those are decoded from the committed `.otv` snapshots (git-ignored, 1.7 GB, about a minute with `-j8`). The decode scripts expect the repo to sit inside `sandia-dynamic-tester`, so pass the Python and the STM32 parser explicitly:

  ```bash
  make -C sandia_combined_data_2026_06_sanitized -j8 generate_mems \
      VENV_PYTHON=$PWD/sandia_combined_data_2026_06_sanitized/.venv/bin/python \
      STM32_OTV_PARSER=$HOME/sandia-dynamic-tester-main/test_vectors/stm32/sram_parse.py
  make -C sandia_combined_data_2026_06_sanitized unzip_characterization   # for "split by preference bins"
  ```

  Its saved configurations live in the git-ignored `dashboard/db/configs.sqlite3`, so a fresh setup starts with none.

Don't also run `make dashboard` in a submodule: the service already serves it.

To change who can log in, see [Login](#2-login-cloudflare-access).

## Getting the submodules

The submodules use SSH URLs, so you need GitHub SSH access to the `byuccl` organization.

```bash
make submodules         # check out the commits recorded in this repo
make update_submodules  # move each submodule to the tip of its tracked branch
```

## How it works

```
browser ──https──▶ Cloudflare (login via Access) ──tunnel──▶ cloudflared on ccl1 ──▶ 127.0.0.1:<port>
```

- **Domain.** `byuccl.org` is registered through Cloudflare. The bare domain and `www` redirect to https://ccl.byu.edu/.
- **Cloudflare Tunnel.** `cloudflared` on `ccl1` makes an outbound connection to Cloudflare, so no inbound ports or firewall changes are needed. The tunnel `byuccl-dashboards` sends each hostname to a local port, as set in `cloudflared/config.yml`. That file is generated from `cloudflared/config.yml.in` and is git-ignored.
- **Cloudflare Access.** Every `*.byuccl.org` hostname requires a login: visitors enter their email and receive a one-time code. Access replaces the shared basic-auth password used with ngrok. It matters because the dashboards have no login of their own and let viewers edit configs.
- **Local only.** The services start the dashboards with `--host 127.0.0.1`, so they're reachable only through the tunnel, not directly from the network.
- **Services.** Each systemd unit is generated from a template in `systemd/`:
  - `byuccl-tunnel`
  - `byuccl-picker` (serves `picker/` with Python's built-in web server)
  - `byuccl-tamu-sram-2026`
  - `byuccl-tamu-stc-2026`
  - `byuccl-lmtf-combined-2026`

  Each dashboard unit runs `make dashboard_serve` in its submodule, using that submodule's `.venv`.

Hostnames stay one level below `byuccl.org` (`tamu-sram-2026.byuccl.org`, not `sram.tamu.byuccl.org`). Cloudflare's free certificate covers only `byuccl.org` and `*.byuccl.org`. A deeper name needs the paid Advanced Certificate Manager.

The dashboard repos keep their own `ngrok_up` and `funnel_up` targets, which still work as a fallback. Those serve the dashboard on its default port 8050, separately from these services.

## Setup from scratch

Steps 1 and 2 are done once in the Cloudflare dashboard. Steps 3 to 5 are done on the machine that serves the dashboards.

### 1. Domain redirect

In the Cloudflare dashboard for `byuccl.org`:

**DNS → Records**, add:

| Type | Name | Content | Proxy status |
|---|---|---|---|
| A | `@` | `192.0.2.1` | Proxied |
| CNAME | `www` | `byuccl.org` | Proxied |

`192.0.2.1` is a reserved dummy address that no request ever reaches, because the redirect rule answers first. Both records must stay **Proxied** (orange cloud), or the rule never runs.

**Rules → Redirect Rules**, rule `Apex to CCL`:

- Match: Hostname is in `byuccl.org`, `www.byuccl.org`
- Type: Static
- URL: `https://ccl.byu.edu/`
- Status: 301
- Preserve query string: off

Browsers cache a 301 indefinitely. If the bare domain will ever be used for something else, switch to 302 first.

### 2. Login (Cloudflare Access)

In the Cloudflare dashboard, open **Zero Trust**. It uses the Free plan, which allows up to 50 users. Set the organization name (shown on the login page) to `BYU CCL Radiation Test Dashboards` under **Settings → Custom pages** or **Team & Resources → Team name**.

**Login method.** Under **Integrations → Identity providers** (press Ctrl+K and search "identity providers"), add **One-time PIN**. It needs no settings.

**Policies** (**Access controls → Policies**):

- `Allowed people`, action **Allow**, with these includes (a visitor needs to match only one):
  - Emails ending in `@byu.edu`
  - Emails ending in `@sandia.gov`
- `public`, action **Bypass**, include **Everyone**

**Applications** (**Access controls → Applications → Create new application → Self-hosted**):

| Application | Public hostname | Policy |
|---|---|---|
| `BYU CCL Radiation Test Dashboards` | `*.byuccl.org` | `Allowed people` |
| `www` | `www.byuccl.org` | `public` |

In that application's login methods, turn off **Accept all available identity providers** and select only **One-time PIN**. Turn on **Instant Auth** if it's offered.

The `www` application keeps the redirect public, since the wildcard would otherwise cover it. Cloudflare applies the more specific hostname. The bare `byuccl.org` isn't covered by `*`, so it needs no exception.

Anyone with a `@byu.edu` or `@sandia.gov` address can log in. To let someone in with a different address, add an **Emails** include with that address to `Allowed people`.

Access doesn't support a shared username and password. We chose emailed codes over a basic-auth proxy: they need no passwords to hand out, and access can be granted per person.

### 3. Install and authorize cloudflared

Install from Cloudflare's apt repository (Ubuntu), so `apt upgrade` keeps it up to date:

```bash
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt-get update && sudo apt-get install -y cloudflared
```

On `ccl1`, `cloudflared` was installed to `/usr/local/bin` instead, and isn't updated by apt.

Authorize the machine once:

```bash
cloudflared tunnel login
```

This prints a URL. Open it in any browser and select `byuccl.org`. It writes `~/.cloudflared/cert.pem`.

### 4. Create the tunnel

```bash
make tunnel_setup
```

This command:

1. Creates the tunnel `byuccl-dashboards`. Its credentials go to `~/.cloudflared/<tunnel-id>.json`; keep them private.
2. Adds a DNS record for each hostname, pointing it at the tunnel.
3. Writes `cloudflared/config.yml`.

It's safe to run again.

### 5. Install the services

Each dashboard needs its virtualenv first:

```bash
git -C ~/sandia-dynamic-tester worktree add --detach ~/sandia-dynamic-tester-main origin/main
make -C sandia_sram_data_2026_10 env DVT_REPO_PATH=~/sandia-dynamic-tester-main
make -C sandia_sram_data_2026_10 decode_shots   # about 9 minutes for 5,278 shots
make -C sandia_stc_data_2026 env
make -C sandia_combined_data_2026_06_sanitized env DVT_REPO_PATH=~/sandia-dynamic-tester-main
# then decode the June data, as described under "Where each dashboard gets its data"
make install_services   # asks for your sudo password
```

`install_services` copies the units to `/etc/systemd/system`, enables them at boot, (re)starts them and prints `make status`. Rerun it after changing ports, hostnames or templates. `make uninstall_services` removes everything.

## Adding a dashboard

1. Add the data repo as a submodule. Make sure its Makefile has a `dashboard_serve` target that takes `DASHBOARD_HOST` and `DASHBOARD_PORT`, like the existing ones.
2. In the `Makefile`, add a key (e.g. `X`) to `DASHBOARDS` and set `X_NAME` (the subdomain), `X_SUBMODULE`, `X_PORT` (next free port, e.g. 8054) and `X_ARGS` (extra variables for its `dashboard_serve`, often empty). The service, tunnel rule, DNS record and status line are all derived from these.
3. Add a card to `picker/index.html`.
4. Run `make -C <submodule> env`, then `make tunnel_setup`, then `make install_services`.

The new hostname is covered by the `*.byuccl.org` login automatically.

## Troubleshooting

**A site shows a Cloudflare "Bad gateway" (502) page after login.** The tunnel is up but the dashboard isn't. Run `make status`, then `journalctl -u byuccl-tamu-sram-2026 -n 50` (or the relevant service) for the error.

**`PUBLIC` shows `000` in `make status`.** This machine can't resolve or reach the hostname. Check `systemctl status byuccl-tunnel`, and test DNS with `dig +short tamu-sram-2026.byuccl.org @1.1.1.1`.

**`Could not resolve host` right after creating a hostname.** Your local resolver may have cached a "not found" answer from before the record existed, for up to an hour. Query `@1.1.1.1` directly to check.

**The redirect from `byuccl.org` doesn't happen.** Confirm the `@` and `www` DNS records are **Proxied**, not "DNS only".
