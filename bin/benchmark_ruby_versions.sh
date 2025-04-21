#!/bin/bash

set -e

for version in 2.7 3.0 3.1 3.2 3.3 3.4; do
	printf "\n\e[1;33m----------------\nRuby ${version}\n----------------\e[0m\n\n"

	printf "\n\e[1mruby install\e[0m\n"
	rvm install ${version}
	rvm ${version} do rvm gemset create mb-sound

	printf "\n\e[1mbundle install\e[0m\n"
	rvm ${version}@mb-sound do bundle install

	printf "\n\e[1mrake clean compile\e[0m\n"
	rvm ${version}@mb-sound do rake clean compile
	
	printf "\n\e[1mbenchmark\e[0m\n"
	rvm ${version}@mb-sound do bin/node_graph_benchmark.rb --bench
done
