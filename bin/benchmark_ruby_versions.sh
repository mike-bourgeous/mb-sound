#!/bin/bash

set -e

VERSION_LIST="2.7 3.0 3.1 3.2 3.3 3.4"

if [ $# -ge "1" ]; then
	VERSION_LIST="$*"
fi

printf "\n\e[1mBenchmarking versions: \e[36m$VERSION_LIST\e[0m\n\n"

for version in $VERSION_LIST; do
	printf "\n\e[38;5;242m----------------\n Setup ruby ${version}\n----------------\e[0m\n\n"

	printf "\n\e[38;5;242mruby install\e[0m\n"
	rvm install ${version} > /dev/null
	rvm ${version} do rvm gemset create mb-sound > /dev/null

	printf "\n\e[38;5;242mbundle install\e[0m\n"
	rvm ${version}@mb-sound do bundle install > /dev/null

	printf "\n\e[38;5;242mrake clean compile\e[0m\n"
	rvm ${version}@mb-sound do rake clean compile > /dev/null

	printf "\n\e[1;33m------------------\nBenchmark ruby ${version}\n------------------\e[0m\n\n"

	# TODO: allow selecting script to run
	if false; then
		printf "\n\e[1mRunning node graph benchmark\e[0m\n\n"

		printf "\n\e[1mbenchmark \e[36m$version \e[31mwithout jit\e[0m\n"
		rvm ${version}@mb-sound do bin/node_graph_benchmark.rb --bench

		printf "\n\e[1mbenchmark \e[36m$version \e[32mwith jit\e[0m\n"
		RUBYOPT=--jit rvm ${version}@mb-sound do bin/node_graph_benchmark.rb --bench
	else
		printf "\n\e[1mRunning resampling benchmark\e[0m\n\n"

		printf "\n\e[1mbenchmark \e[36m$version \e[31mwithout jit\e[0m\n"
		rvm ${version}@mb-sound do bin/resample_benchmark.rb

		printf "\n\e[1mbenchmark \e[36m$version \e[32mwith jit\e[0m\n"
		RUBYOPT=--jit rvm ${version}@mb-sound do bin/resample_benchmark.rb
	fi
done
