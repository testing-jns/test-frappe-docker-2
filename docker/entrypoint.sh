#!/usr/bin/env bash
# Container entrypoint.
#
#   explicit command   run it (docker compose exec / run ... bash)
#   BOOTSTRAP=0        skip bootstrap, behave like a plain toolchain container
#   otherwise          bootstrap, then idle
#
# The container deliberately does NOT run `bench start`. Development servers
# belong in a terminal the engineer controls: they need to read the log, restart
# after a config change, and stop it while running a long migrate. A server
# owned by PID 1 can only be restarted by restarting the container.
#
# On bootstrap failure this idles too. The compose service uses
# restart: unless-stopped, so a non-zero exit would re-clone from GitHub every
# few seconds -- an expired token would quietly fill the disk overnight.

set -euo pipefail

BENCH_DIR=/home/frappe/frappe-bench

# Escape hatch first: an explicit command always wins.
if [ $# -gt 0 ]; then
	[ -d "$BENCH_DIR" ] && cd "$BENCH_DIR"
	exec "$@"
fi

if [ "${BOOTSTRAP:-1}" = "1" ]; then
	if ! /usr/local/bin/bootstrap.sh; then
		cat <<-MSG

		  The container stays up so you can inspect it.

		      docker compose logs bench          see what failed
		      docker compose exec bench bash     get a shell and fix it
		      docker compose restart bench       try again

		  Nothing is lost. Bootstrap resumes from the last step that
		  succeeded rather than starting over.

		MSG
		exec sleep infinity
	fi
fi

if [ ! -f "$BENCH_DIR/sites/common_site_config.json" ]; then
	echo "No bench yet and BOOTSTRAP=0. Get a shell with: docker compose exec bench bash"
fi

exec sleep infinity
