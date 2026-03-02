#!/bin/bash

if docker ps 2>&1 | grep -q mb-sound; then
	echo "Attaching"
	docker exec -it mb-sound /bin/bash
elif docker ps -a 2>&1 | grep -q mb-sound; then
	echo "Resuming"
	docker restart mb-sound
	docker attach mb-sound
else
	echo "Creating"
	docker run --name mb-sound -it mb-sound /bin/bash
fi
