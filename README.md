# bizops-bench

A Frappe v16 bench blueprint for one project. A new engineer runs
`docker compose up` — the bench is created, every app in `apps.json` is cloned and
installed, and the container then idles. Apps are edited straight from the IDE on
the host.

One repo = one project = one bench = one database. For the next tenant, copy this
repo and change `.env` and `apps.json`.

## Getting started

```bash
cp .env.example .env
$EDITOR .env              # PROJECT_NAME, SITE_NAME, the port block
export GITHUB_TOKEN=...   # fine-grained PAT, read access to the org repos
docker compose up
```

The first boot takes a while — `bench init` plus every app. Leave it in the
foreground so you can watch the progress. It ends with a `BENCH READY` banner.

Then start a server yourself:

```bash
docker compose exec bench bench start
```

Open `http://<SITE_NAME>:<WEB_PORT>` and log in as `Administrator` / `admin`.
Use the site name, not `localhost` — Frappe picks the site from the Host header.

Later boots are `docker compose up -d`; bootstrap verifies in a few seconds.

## Why the container does not run `bench start`

A development server belongs in a terminal you control. You need to read its log,
restart it after a config change, and stop it while running a long migrate. A
server owned by PID 1 can only be restarted by restarting the container.

`bench start` also runs the esbuild watcher, so edits under `./workspace/apps`
rebuild without a restart. Run it in its own terminal and leave it there.

## apps.json

```json
[
  { "name": "erpnext", "url": "https://github.com/frappe/erpnext", "branch": "version-16" },
  { "name": "bizops_m365", "url": "https://github.com/bizops-dev/bizops-m365",
    "branch": "develop", "private": true, "ours": true }
]
```

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | The **module** name, not the repo name. Used by `install-app` and as the "already present" marker. |
| `url` | yes | Clean URL, **no token**. |
| `branch` | no | The project's stable branch. Engineers are free to `git checkout` afterwards. |
| `ours` | no | An app the team develops → cloned with full git history. |
| `private` | no | Used by preflight to fail early when the token is empty. |
| `install` | no | `false` for an app that lives in the bench but is not installed on the site. |

`frappe` is **not** listed — `bench init` installs it via `FRAPPE_BRANCH`. Array
order is installation order.

**`name` must be the module name.** `bench get-app` names the folder after the
repository, then renames it to the real app name. The repo `bizops-m365` becomes
`apps/bizops_m365`. If `name` is wrong, bootstrap stops with a list of the folders
that actually exist — once, rather than re-cloning on every boot.

**Why `ours` matters.** `bench` clones with `--depth 1` by default
(`shallow_clone` in `common_site_config`). That is fine for `erpnext` and harmful
for an app you develop: no `git log`, no branching off a base, and
`bench switch-to-branch` refuses to work. Mark your own apps with `"ours": true`.

**Do not confuse it** with `workspace/sites/apps.json`. That one belongs to bench
and is rewritten on every `bench get-app`. Ours lives in the repo root and is
mounted read-only at `/opt/apps.json`.

## Day to day

```bash
docker compose exec bench bash          # shell, already inside frappe-bench
docker compose exec bench bench start   # the dev server, in its own terminal
docker compose logs -f bench            # bootstrap output
docker compose restart bench            # after apps.json changed
docker compose down                     # stop; data survives
```

One-off commands without a shell need `--workdir`, because `.bashrc` is only read
by interactive shells:

```bash
docker compose exec -w /home/frappe/frappe-bench bench bench --site $SITE_NAME migrate
```

A useful alias:

```bash
alias dbench='docker compose exec -w /home/frappe/frappe-bench bench bench'
```

## Adding an app

Edit `apps.json`, commit, then:

```bash
docker compose restart bench
```

Bootstrap notices the digest changed, clones only what is new, installs it on the
site, then runs `bench build` and `migrate`. Other engineers just `git pull` and
`docker compose restart bench`.

`bench update` does **not** pick up new apps — it only pulls the ones already
present. For that:

```bash
dbench update --pull --patch --build --no-backup
docker compose restart bench
```

Changing `branch` for an app that already exists has no effect either: the
per-app guard skips anything already cloned. Switch branches yourself in
`./workspace/apps/<app>/`.

## Removing an app

Bootstrap never removes anything. An app present in the bench but absent from
`apps.json` is only reported:

```
note: apps/bizops_scratch is in the bench but not in apps.json
```

Removal is a human decision — `bench remove-app` drops DocTypes and their data.

## What is committed

Committed: `docker/`, `docker-compose.yml`, `.env.example`, `apps.json`,
`README.md`, `.gitignore`.

Not: `.env` (it holds the token) and all of `workspace/`.

`workspace/` is ignored **entirely**, and carries a second `.gitignore` containing
`*`. That is not belt-and-braces: every folder under `apps/` is its own git repo,
and `git add` on a nested repo produces a gitlink with no `.gitmodules` entry —
which clones as an empty folder for everyone else, without a warning.

## Token handling

The token never appears in a URL. Bootstrap installs a credential helper in
`/home/frappe/.gitconfig`, which lives in the image layer, not the bind mount:

```sh
git config --global 'credential.https://github.com.helper' \
  '!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$GITHUB_TOKEN"; }; f'
```

So `remote.origin.url` stays clean, the token never touches `.git/config` in the
working tree, never shows up in `ps aux`, and is never written to
`frappe-bench/logs/bench.log` — which records the argv of every bench command.

After all clones, bootstrap re-checks and stops if it finds a credential in any
remote.

Prefer keeping the token in your shell profile (`export GITHUB_TOKEN=...`) over
`.env` in every project. Compose gives the shell environment priority.

## When it fails

A failed bootstrap does **not** kill the container — it idles so you can inspect
it. That is deliberate: with `restart: unless-stopped`, a non-zero exit becomes a
crash loop that re-clones from GitHub every few seconds.

```bash
docker compose logs bench          # see what failed
docker compose exec bench bash     # get a shell and fix it
docker compose restart bench       # resume
```

Bootstrap resumes from the last step that succeeded.

| Message | Cause | Action |
|---|---|---|
| `apps.json is a directory` | File missing on the host, Docker created a mount point | Create `apps.json` next to `docker-compose.yml` |
| `declares private repositories but GITHUB_TOKEN is empty` | Preflight | Set `GITHUB_TOKEN` |
| `cloned ... but apps/<name> does not exist` | `name` is not the module name | Fix `name` using the printed list |
| `./workspace is owned by uid N` | `HOST_UID` mismatch | Fix `.env`, then `docker compose build` |
| `only NGB free ... need at least 10GB` | Thin disk | `docker builder prune`, `docker image prune -a` |
| `address already in use` | Port taken | `ss -ltn \| grep :8000`, change the port block in `.env` |
| `ENOSPC` during `yarn install` | Disk filled up mid-install | As above, then `docker compose restart bench` |
| `bench build` killed with 137 | OOM during esbuild | Give Docker more memory, or run `bench build` by hand later |

A bench with frappe + erpnext is around **4 GB**, and yarn needs extra room to
unpack. Preflight refuses to run below 10 GB free; that threshold is
`MIN_FREE_GB`.

`BOOTSTRAP=0` in `.env` disables the automation entirely — the container stays up
and you run `bench init` yourself. For when the automation is the broken thing.

## Notes

**WSL2**: keep the checkout on the Linux filesystem, not `/mnt/c`. A bind mount
across filesystems makes `bench watch` painfully slow.

**Ports**: `BIND_HOST` defaults to `127.0.0.1`. This bench runs with
`developer_mode` on, which means Server Scripts can execute arbitrary Python. Do
not expose it to the office network without a reverse proxy.

**Redis** is not a compose service. The Procfile written by `bench init` already
starts `redis_cache` and `redis_queue` itself.

**Frappe pins the versions**, they are not preferences:

```
apps/frappe/pyproject.toml   requires-python = ">=3.14,<3.15"
apps/frappe/package.json     "engines": {"node": ">=24"}
```

That Python range is strict. Ubuntu 22.04 only ships 3.10, so the interpreter
comes from the deadsnakes PPA — verified available for jammy as `3.14.6-1+jammy1`.
