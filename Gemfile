# frozen_string_literal: true
source "https://rubygems.org"

git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }

gemspec

# Comment this out if you don't want to use Jack via FFI or don't want to
# install FFI.
gem 'mb-sound-jackffi', '>= 0.1.0.usegit', github: 'mike-bourgeous/mb-sound-jackffi.git'

gem 'mb-math', github: 'mike-bourgeous/mb-math.git', branch: 'wavetable' # XXX do not merge without removing branch
gem 'mb-util', github: 'mike-bourgeous/mb-util.git'
