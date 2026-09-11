#!/usr/bin/env bash
# Bring the bench described by apps.json into existence, then get out of the way.
#
# Runs on every boot. Everything is guarded, so a second run is cheap and a run
# after a half-finished first attempt continues rather than starting over.
#
# Two rules shape the whole script:
#   - Never prompt. `bench get-app` asks for confirmation when the app directory
#     already exists, and a prompt in a non-interactive boot hangs forever.
#   - Bootstrap failures are reported clearly and the caller is responsible for
#     keeping the container alive. See entrypoint.sh.
#
# HOST_OS:
#   linux   - enforce UID/GID ownership on the bind mount
#   windows - do not enforce Linux UID/GID ownership because Docker Desktop
#             presents Windows bind mounts with synthetic Linux ownership.

set -euo pipefail

BENCH=/home/frappe/frappe-bench
MANIFEST=/opt/apps.json
STATE=/home/frappe/.bootstrap

die() {
	echo >&2
	echo "  BOOTSTRAP FAILED: $*" >&2
	echo >&2
	exit 1
}

step() {
	echo
	echo "==> $*"
}

# ------------------------------------------------------------------ ownership

check_workspace_ownership() {
	# Native Linux bind mounts preserve Unix ownership.
	#
	# Windows bind mounts through Docker Desktop/WSL do not necessarily expose
	# the Windows user's identity as a meaningful Linux UID. They commonly
	# appear as UID 0 even though the Windows user is not root.
	#
	# Therefore HOST_UID/HOST_GID ownership validation only makes sense on
	# native Linux hosts.
	if [ "${HOST_OS:-linux}" = "windows" ]; then
		echo "    workspace ownership check: skipped for Windows bind mount"
		return 0
	fi

	local owner group container_uid container_gid

	owner=$(stat -c %u "$BENCH")
	group=$(stat -c %g "$BENCH")
	container_uid=$(id -u)
	container_gid=$(id -g)

	if [ "$owner" != "$container_uid" ] || [ "$group" != "$container_gid" ]; then
		die "./workspace is owned by uid:gid $owner:$group but this container runs as $container_uid:$container_gid.
  Files written here may not be editable from your IDE.

  Fix .env:
      HOST_UID=$owner
      HOST_GID=$group

  Then:
      docker compose build
      docker compose up"
	fi
}

# ----------------------------------------------------------------------- redis

# new-site, install-app and migrate all talk to redis_queue (11000) and
# redis_cache (13000). Those are started by `bench start` via the Procfile, which
# the container deliberately does not run -- so bootstrap starts just those two
# itself and stops them when it is done. Starting the whole Procfile instead
# would also start `bench watch`, which tries to build assets for apps that are
# still being installed.

REDIS_PIDS=""

start_redis() {
	[ -f "$BENCH/config/redis_cache.conf" ] || return 0

	step "starting redis (cache 13000, queue 11000) for the install"

	cd "$BENCH"

	redis-server config/redis_cache.conf --daemonize no >/dev/null 2>&1 &
	REDIS_PIDS="$REDIS_PIDS $!"

	redis-server config/redis_queue.conf --daemonize no >/dev/null 2>&1 &
	REDIS_PIDS="$REDIS_PIDS $!"

	local waited=0

	while [ "$waited" -lt 30 ]; do
		if redis-cli -p 11000 ping >/dev/null 2>&1 \
			&& redis-cli -p 13000 ping >/dev/null 2>&1; then
			return 0
		fi

		sleep 1
		waited=$((waited + 1))
	done

	die "redis did not come up on 11000/13000 within 30s"
}

stop_redis() {
	[ -n "$REDIS_PIDS" ] || return 0

	# shellcheck disable=SC2086
	kill $REDIS_PIDS 2>/dev/null || true
	wait $REDIS_PIDS 2>/dev/null || true

	REDIS_PIDS=""
}

# Leaving redis running after a failed bootstrap would make the next attempt
# fail on "address already in use".
trap stop_redis EXIT

# ---------------------------------------------------------------- heartbeat

# Frappe's progress bars hide themselves when stdout is not a TTY, so new-site
# and migrate can sit silent for minutes. Print elapsed time next to the command
# still running, so `docker compose logs -f` shows the boot is alive rather than
# wedged. $! is the command; this dies with it.

with_heartbeat() {
	local label="$1"
	shift

	"$@" &

	local pid=$!
	local elapsed=0

	while kill -0 "$pid" 2>/dev/null; do
		sleep 30

		kill -0 "$pid" 2>/dev/null || break

		elapsed=$((elapsed + 30))

		printf \
			'    ... %s still running (%dm%02ds)\n' \
			"$label" \
			$((elapsed / 60)) \
			$((elapsed % 60))
	done

	wait "$pid"
}

# --------------------------------------------------------------- the manifest

# Emits one TAB-separated line per app:
#   name, url, branch, install, ours

read_manifest() {
	"$PYTHON_BIN" - "$MANIFEST" <<-'PY'
		import json
		import sys

		with open(sys.argv[1]) as handle:
		    apps = json.load(handle)

		if not isinstance(apps, list):
		    sys.exit("apps.json must be a JSON array")

		for index, app in enumerate(apps):
		    name = app.get("name")
		    url = app.get("url")

		    if not name:
		        sys.exit(f"apps.json entry {index} has no \"name\"")

		    if not url:
		        sys.exit(f"apps.json entry {index} ({name}) has no \"url\"")

		    if name == "frappe":
		        sys.exit(
		            "remove \"frappe\" from apps.json -- "
		            "bench init installs it"
		        )

		    install = "0" if app.get("install") is False else "1"

		    # Our own apps need real history; third-party ones do not.
		    ours = "1" if app.get("ours") else "0"

		    print(
		        "\t".join(
		            [
		                name,
		                url,
		                app.get("branch") or "",
		                install,
		                ours,
		            ]
		        )
		    )
	PY
}

manifest_names() {
	read_manifest | cut -f1
}

# ------------------------------------------------------------------ preflight

preflight() {
	# A directory here means the host file is missing and Docker invented a
	# mount point. Worth its own message -- the JSON error would be baffling.
	[ -d "$MANIFEST" ] && die "apps.json is a directory.
  The host file is missing, so Docker created a directory at the mount point.
  Create apps.json next to docker-compose.yml, then: docker compose up"

	[ -f "$MANIFEST" ] || die "apps.json not found at $MANIFEST"

	read_manifest >/dev/null \
		|| die "apps.json could not be read (see above)"

	# A full disk surfaces as `yarn install --check-files` failing with ENOSPC
	# several minutes in, buried under hundreds of lines of tarball errors.
	local free_gb

	free_gb=$(
		df -BG --output=avail "$BENCH" |
			tail -1 |
			tr -dc '0-9'
	)

	if [ "${free_gb:-0}" -lt "${MIN_FREE_GB:-10}" ]; then
		die "only ${free_gb}GB free where ./workspace lives; need at least ${MIN_FREE_GB:-10}GB.
  A bench with frappe + erpnext is roughly 4GB, and yarn needs room to unpack
  on top of that. Running out mid-install shows up as an unrelated-looking
  'yarn install --check-files' failure.

  Reclaim some first:
      docker system df
      docker builder prune
      docker image prune -a"
	fi

	check_workspace_ownership

	if read_manifest |
		cut -f2 |
		grep -q . &&
		grep -q '"private"[[:space:]]*:[[:space:]]*true' "$MANIFEST"; then

		[ -n "${GITHUB_TOKEN:-}" ] ||
			die "apps.json declares private repositories but GITHUB_TOKEN is empty.
  Put a fine-grained PAT with read access to your org in .env, then retry."
	fi
}

# ------------------------------------------------------------- git credentials

# A credential helper, not a token embedded in the URL and not url.insteadOf.
#
# The URL form writes the token into apps/<app>/.git/config, which lives in the
# bind mount and therefore in every engineer's working tree.
#
# insteadOf keeps the remote clean but passes the token in argv, where `ps aux`
# inside the container can read it.
#
# The helper reads it from the environment only when git asks.

setup_git_auth() {
	git config --global \
		--unset-all \
		'credential.https://github.com.helper' \
		2>/dev/null || true

	git config --global \
		--unset-all \
		'credential.https://github.com.username' \
		2>/dev/null || true

	[ -n "${GITHUB_TOKEN:-}" ] || return 0

	git config --global \
		'credential.https://github.com.username' \
		'x-access-token'

	git config --global \
		'credential.https://github.com.helper' \
		'!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$GITHUB_TOKEN"; }; f'
}

# -------------------------------------------------------------- database wait

# `docker compose restart` does not re-evaluate depends_on: service_healthy,
# so the database may not be up yet even though compose started it once.

wait_for_database() {
	local attempt

	for attempt in $(seq 1 60); do
		if mariadb-admin \
			--host="$DB_HOST" \
			--user=root \
			--password="$DB_ROOT_PASSWORD" \
			ping \
			--silent \
			2>/dev/null; then
			return 0
		fi

		sleep 2
	done

	die "MariaDB at $DB_HOST did not respond after two minutes."
}

# ----------------------------------------------------------------- the bench

create_bench() {
	[ -f "$BENCH/sites/common_site_config.json" ] && return 0

	# bench init writes common_site_config.json very early, so its absence means
	# the previous attempt never got far enough for a site to exist.
	#
	# $BENCH is the bind mount itself and must not be removed -- deleting it
	# would break the mount. Empty it instead.
	if [ -n "$(ls -A "$BENCH" 2>/dev/null)" ]; then
		step "clearing an incomplete bench left by a failed init"

		find "$BENCH" \
			-mindepth 1 \
			-maxdepth 1 \
			-exec rm -rf {} +
	fi

	step "bench init ($FRAPPE_BRANCH, $($PYTHON_BIN --version))"

	cd "$(dirname "$BENCH")"

	bench init \
		--frappe-branch "$FRAPPE_BRANCH" \
		--python "$PYTHON_BIN" \
		--no-backups \
		--skip-assets \
		--ignore-exist \
		frappe-bench
}

configure_bench() {
	cd "$BENCH"

	bench set-config -g db_host "$DB_HOST" >/dev/null
	bench set-config -g developer_mode 1 >/dev/null
}

# Returns 0 if it cloned anything, so the caller knows whether to rebuild.
fetch_apps() {
	local cloned=1
	local name url branch install ours

	cd "$BENCH"

	while IFS=$'\t' read -r name url branch install ours; do
		# Never call bench get-app when the directory already exists because
		# bench may ask for confirmation.
		[ -d "$BENCH/apps/$name" ] && continue

		# bench clones with --depth 1 by default. Our own apps need full history.
		if [ "$ours" = 1 ]; then
			bench set-config -g shallow_clone false >/dev/null
		else
			bench set-config -g shallow_clone true >/dev/null
		fi

		local history_label=""

		if [ "$ours" = 1 ]; then
			history_label=" [full history]"
		fi

		step "get-app $name${branch:+ ($branch)}$history_label"

		bench get-app \
			--skip-assets \
			${branch:+--branch "$branch"} \
			"$url" \
			|| die "get-app failed for $name <$url>.
  Look further up for the real cause.

  Usual causes:
    'Repository not found'  -- GITHUB_TOKEN cannot read this repo
    'ENOSPC'                -- disk filled up during yarn install
    exit code 137           -- node was killed by the OOM killer

  Nothing else was lost; fix it and run:
      docker compose restart bench"

		[ -d "$BENCH/apps/$name" ] ||
			die "cloned $url but apps/$name does not exist.
  bench derives the directory from the app's real name; found:
$(ls -1 "$BENCH/apps" | sed 's/^/    /')
  Correct \"name\" in apps.json to match."

		cloned=0

	done < <(read_manifest)

	# Leave the bench on the safe default for anything an engineer clones later.
	bench set-config -g shallow_clone false >/dev/null

	assert_no_leaked_credentials

	return "$cloned"
}

# ---------------------------------------------------------- credential safety

# If a token ever reaches a remote URL it lands here, on the host, and survives
# image rebuilds and token rotation. Fail loudly rather than let it sit there.

assert_no_leaked_credentials() {
	local hits

	hits=$(
		grep -rlE '(@github\.com|ghp_|gho_|github_pat_)' \
			"$BENCH"/apps/*/.git/config \
			2>/dev/null || true
	)

	[ -z "$hits" ] && return 0

	die "a credential was written into a git remote:
$(echo "$hits" | sed 's/^/    /')
  apps.json must carry token-free URLs -- auth comes from the credential helper.
  Rotate that token now, then fix the URL in apps.json."
}

# ------------------------------------------------------------ site database

# True when the site's own credentials can open its database.

site_database_reachable() {
	local cfg="$BENCH/sites/$SITE_NAME/site_config.json"
	local name user pass

	[ -f "$cfg" ] || return 1

	name=$(
		python3 -c \
			"import json,sys;print(json.load(open(sys.argv[1])).get('db_name',''))" \
			"$cfg" \
			2>/dev/null
	) || return 1

	user=$(
		python3 -c \
			"import json,sys;d=json.load(open(sys.argv[1]));print(d.get('db_user') or d.get('db_name',''))" \
			"$cfg" \
			2>/dev/null
	) || return 1

	pass=$(
		python3 -c \
			"import json,sys;print(json.load(open(sys.argv[1])).get('db_password',''))" \
			"$cfg" \
			2>/dev/null
	) || return 1

	[ -n "$name" ] && [ -n "$pass" ] || return 1

	mariadb \
		-h "$DB_HOST" \
		-u"$user" \
		-p"$pass" \
		-D "$name" \
		-e "SELECT 1" \
		>/dev/null \
		2>&1
}

create_site() {
	# site_config.json alone is not proof the site exists because dropping the
	# mariadb volume leaves the bench filesystem intact while the database and
	# its user are gone.

	if [ -f "$BENCH/sites/$SITE_NAME/site_config.json" ]; then
		if site_database_reachable; then
			return 0
		fi

		step "site config exists but its database is gone -- recreating $SITE_NAME"

		rm -rf "$BENCH/sites/$SITE_NAME"
	fi

	step "bench new-site $SITE_NAME"

	cd "$BENCH"

	with_heartbeat \
		"new-site" \
		bench new-site "$SITE_NAME" \
			--db-root-username "$DB_ROOT_USERNAME" \
			--db-root-password "$DB_ROOT_PASSWORD" \
			--admin-password "$ADMIN_PASSWORD" \
			--mariadb-user-host-login-scope='%' \
			--verbose \
		|| die "bench new-site failed"

	bench --site "$SITE_NAME" set-config developer_mode 1 >/dev/null
	bench --site "$SITE_NAME" set-config server_script_enabled 1 >/dev/null
	bench --site "$SITE_NAME" enable-scheduler >/dev/null
}

# --------------------------------------------------------------- install apps

# Returns 0 if it installed anything.

install_apps() {
	local installed changed=1
	local name url branch install ours

	cd "$BENCH"

	installed=$(
		bench --site "$SITE_NAME" list-apps 2>/dev/null |
			awk '{print $1}'
	)

	while IFS=$'\t' read -r name url branch install ours; do
		[ "$install" = 1 ] || continue
		grep -qx "$name" <<<"$installed" && continue

		step "install-app $name"

		with_heartbeat \
			"install-app $name" \
			bench --verbose --site "$SITE_NAME" install-app "$name" \
			|| die "install-app $name failed"

		changed=0

	done < <(read_manifest)

	return "$changed"
}

# -------------------------------------------------------------- report state

report_untracked_apps() {
	local dir app

	for dir in "$BENCH"/apps/*/; do
		app=$(basename "$dir")

		[ "$app" = frappe ] && continue

		grep -qx "$app" <(manifest_names) && continue

		echo "    note: apps/$app is in the bench but not in apps.json"
	done
}

# ----------------------------------------------------------------------- main

preflight
setup_git_auth

# Fast path. Engineers restart this container constantly; a five second boot
# matters more than re-verifying a bench that has not changed.

if [ -f "$STATE/ok" ] \
	&& [ -f "$STATE/manifest.sha256" ] \
	&& sha256sum --status -c "$STATE/manifest.sha256" 2>/dev/null \
	&& [ -f "$BENCH/sites/$SITE_NAME/site_config.json" ]; then
	exit 0
fi

wait_for_database

create_bench
configure_bench
start_redis

changed=1

fetch_apps || changed=0
create_site
install_apps || changed=0

if [ "$changed" = 0 ]; then
	step "bench build"

	cd "$BENCH"

	with_heartbeat \
		"bench build" \
		bench build \
		|| die "bench build failed"

	with_heartbeat \
		"migrate" \
		bench --verbose --site "$SITE_NAME" migrate \
		|| die "bench migrate failed"
fi

report_untracked_apps

stop_redis

mkdir -p "$STATE"

(
	cd "$(dirname "$MANIFEST")"
	sha256sum "$(basename "$MANIFEST")" > "$STATE/manifest.sha256"
)

touch "$STATE/ok"

# A loud, unmistakable banner. The steps above scroll past in a wall of git and
# yarn output; an engineer watching `docker compose logs -f` needs one line they
# can search for to know the boot is done.

cat <<-EOF

	════════════════════════════════════════════════════════════════
	  BENCH READY

	  Site        : $SITE_NAME
	  URL         : http://$SITE_NAME:${WEB_PORT:-8000}
	  Login       : Administrator / $ADMIN_PASSWORD
	  Apps        : $(cd "$BENCH" && bench --site "$SITE_NAME" list-apps 2>/dev/null | awk '{printf "%s ", $1}')
	  Bench (host): ./workspace

	  The container does not start a server. Run one yourself:

	      docker compose exec bench bench start

	  That includes the esbuild file watcher, so edits under
	  ./workspace/apps rebuild without a restart.
	════════════════════════════════════════════════════════════════

EOF
