#!/bin/bash
# MB - Claude code container environment
# Used with Podman on Ubuntu Linux

APPNAME=rootly_slack_app

set -eu

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
	docker run --name $APPNAME -it -p 3000:3000 -v .:/app $APPNAME /bin/bash
fi
