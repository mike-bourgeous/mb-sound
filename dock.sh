#!/bin/bash
# MB - Claude code container environment
# Used with Podman on Ubuntu Linux
#
# Usage: ./dock.sh [options] [-- docker run arguments...]
#   --build              rebuild the image (and remove the old container)
#   --recreate           remove the container and create it again (options
#                        below only apply when the container is created)
#   --ro HOST:CONTAINER  mount a host folder read-only (repeatable), e.g.
#                        --ro /mnt/windows/Music/Projects:/music
#   --mount HOST:CONTAINER
#                        mount a host folder read-write (repeatable)
#   -h, --help           this help
# Arguments after `--` go to `docker run` as they are (only when creating).

APPNAME=mb-sound

set -eu

# Claude Code's config is split in two so two machines can share one /app
# (e.g. the Mac's checkout, sshfs-mounted on Linux):
# - LOCAL_CLAUDE (per machine, never shared): credentials, .claude.json,
#   sessions, daemon sockets and PIDs, history, transcripts, caches.  Mounted
#   at /claude, which is CLAUDE_CONFIG_DIR in the container.
# - SHARED_CLAUDE (in the repo, gitignored): memory, skills, plans, rules,
#   commands, agents, output-styles, and workflows, bind-mounted over those
#   folders inside /claude.  Directories only (single files like
#   settings.json, keybindings.json, and the user CLAUDE.md stay per machine;
#   put shared personal instructions in rules/ instead).  plugins/ stays per
#   machine too: it holds install caches and paths.
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_CLAUDE="${LOCAL_CLAUDE:-$HOME/.mb-sound-claude}"
SHARED_CLAUDE="${SHARED_CLAUDE:-$REPO_DIR/.claude-shared}"
SHARED_DIRS="memory:projects/-app/memory skills:skills plans:plans rules:rules commands:commands agents:agents output-styles:output-styles workflows:workflows"
# GitHub CLI config (gh's login token and settings), per machine and never
# shared, like LOCAL_CLAUDE: mounted at /gh, which is GH_CONFIG_DIR in the
# container.  It used to live in the repo's gitignored .gh-user (visible to
# every machine sharing /app); a new LOCAL_GH starts as a copy of it.
LOCAL_GH="${LOCAL_GH:-$HOME/.mb-sound-gh}"

usage()
{
	sed -n '4,14p' "$0" | sed 's/^# \{0,1\}//'
}

build=0
recreate=0
extra_mounts=()
run_args=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--build) build=1 ;;
		--recreate) recreate=1 ;;
		--ro|--mount)
			if [[ $# -lt 2 || "$2" != *:* ]]; then
				echo "$1 needs HOST:CONTAINER"
				exit 1
			fi
			[[ "$1" = --ro ]] && extra_mounts+=("$2:ro") || extra_mounts+=("$2")
			shift ;;
		--ro=*) extra_mounts+=("${1#--ro=}:ro") ;;
		--mount=*) extra_mounts+=("${1#--mount=}") ;;
		--) shift; run_args=("$@"); break ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Unknown option: $1"; echo; usage; exit 1 ;;
	esac
	shift
done

trap echo EXIT

hl()
{
	msg="$*"
	printf "\n\033[1;33m%s\n" "$msg"
	printf "=%.0s" `seq 1 ${#msg}`
	printf "\033[0m\n\n"
}

if [[ $build = 1 ]]; then
	hl "Building"
	# (from the repo, not the current directory: run from elsewhere, `.` built
	# the wrong context; mb-landscape's note, 2026-11-04)
	docker build "$REPO_DIR" -f "$REPO_DIR/Dockerfile" -t $APPNAME \
		--build-arg GIT_USER_NAME="$(git -C "$REPO_DIR" config user.name || true)" \
		--build-arg GIT_USER_EMAIL="$(git -C "$REPO_DIR" config user.email || true)"
	recreate=1
fi

if [[ $recreate = 1 ]] && docker ps -a 2>&1 | grep -q $APPNAME; then
	hl "Removing old container"
	docker rm -f $APPNAME
fi

if docker ps -a 2>&1 | grep -q $APPNAME && [[ ${#extra_mounts[@]} -gt 0 || ${#run_args[@]} -gt 0 ]]; then
	echo "The container exists, so --ro/--mount/-- arguments don't apply; add --recreate."
	exit 1
fi

if docker ps 2>&1 | grep -q $APPNAME; then
	hl "Attaching"
	docker exec -it $APPNAME /bin/bash

elif docker ps -a 2>&1 | grep -q $APPNAME; then
	hl "Resuming"
	docker restart $APPNAME
	docker attach $APPNAME

else
	hl "Creating"

	if [[ -d "$REPO_DIR/.claude-user" && ! -e "$LOCAL_CLAUDE" ]]; then
		echo "Found the old $REPO_DIR/.claude-user but no $LOCAL_CLAUDE."
		echo "Move its shared folders into $SHARED_CLAUDE and the rest to"
		echo "$LOCAL_CLAUDE first (see the comment at the top of dock.sh)."
		exit 1
	fi

	if [[ ! -e "$LOCAL_GH" ]]; then
		if [[ -d "$REPO_DIR/.gh-user" ]]; then
			echo "Copying $REPO_DIR/.gh-user to $LOCAL_GH (gh's config is per machine now;"
			echo "delete the old folder once every machine has its own copy)."
			cp -a "$REPO_DIR/.gh-user" "$LOCAL_GH"
		else
			mkdir -p "$LOCAL_GH"
		fi
		chmod 700 "$LOCAL_GH"
	fi

	# Create the mount points ourselves so they belong to this user, not
	# root.  Nested bind mounts: the shared folders cover their mount points
	# inside the local config.
	mounts=(-v "$REPO_DIR":/app -v "$LOCAL_CLAUDE":/claude -v "$LOCAL_GH":/gh)
	for pair in $SHARED_DIRS; do
		src="$SHARED_CLAUDE/${pair%%:*}"
		dst="${pair#*:}"
		mkdir -p "$src" "$LOCAL_CLAUDE/$dst"
		mounts+=(-v "$src":"/claude/$dst")
	done
	# --ro/--mount folders: a missing host folder stops here (an unmounted
	# disk would otherwise mount as an empty directory)
	for spec in ${extra_mounts[@]+"${extra_mounts[@]}"}; do
		src="${spec%%:*}"
		if [[ ! -d "$src" ]]; then
			echo "$src is not a directory (is the disk mounted?)"
			exit 1
		fi
		mounts+=(-v "$spec")
	done

	# --shm-size: every JACK2 server maps ~40 MB of /dev/shm, and Docker's
	# default 64 MB holds only one, so a second dummy server (another
	# session's specs, a benchmark) died with SIGBUS (2026-10-14).  Applies
	# when the container is created; an existing container keeps its size.
	# --cap-add SYS_NICE: lets the render and latency probe threads get
	# SCHED_FIFO/nice priority (maintainer's OK, 2026-10-25); also only for
	# new containers.
	# -p 127.0.0.1:3000:3000: a port for a future web interface, reachable
	# from this machine only (the maintainer, 2026-11-04); never mount the
	# Docker or Podman socket into the container.
	docker run --name $APPNAME -it -p 127.0.0.1:3000:3000 \
		--shm-size=512m \
		--cap-add SYS_NICE \
		"${mounts[@]}" \
		-e CLAUDE_CONFIG_DIR=/claude \
		-e GH_CONFIG_DIR=/gh \
		${run_args[@]+"${run_args[@]}"} \
		$APPNAME /bin/bash
fi
