#!/bin/bash
# MB - Claude code container environment
# Used with Podman on Ubuntu Linux

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

trap echo EXIT

hl()
{
	msg="$*"
	printf "\n\033[1;33m%s\n" "$msg"
	printf "=%.0s" `seq 1 ${#msg}`
	printf "\033[0m\n\n"
}

if [[ "${1-}" = "--build" ]]; then
	hl "Building"
	docker build . -f Dockerfile -t $APPNAME

	if docker ps -a 2>&1 | grep -q $APPNAME; then
		hl "Removing old container"
		docker rm -f $APPNAME
	fi
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

	# Create the mount points ourselves so they belong to this user, not
	# root.  Nested bind mounts: the shared folders cover their mount points
	# inside the local config.
	mounts=(-v "$REPO_DIR":/app -v "$LOCAL_CLAUDE":/claude)
	for pair in $SHARED_DIRS; do
		src="$SHARED_CLAUDE/${pair%%:*}"
		dst="${pair#*:}"
		mkdir -p "$src" "$LOCAL_CLAUDE/$dst"
		mounts+=(-v "$src":"/claude/$dst")
	done

	docker run --name $APPNAME -it -p 3000:3000 \
		"${mounts[@]}" \
		-e CLAUDE_CONFIG_DIR=/claude \
		$APPNAME /bin/bash
fi
