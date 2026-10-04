# frozen_string_literal: true
source "https://rubygems.org"

git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }

gemspec

gem 'readline', require: true

gem 'numo-narray', github: 'mike-bourgeous/numo-narray-compat.git', branch: 'compat-9-2-x'

gem 'mb-math', github: 'mike-bourgeous/mb-math.git'
gem 'mb-util', github: 'mike-bourgeous/mb-util.git'

group :development, :test do
  # Runs specs under Valgrind memcheck, filtering Ruby's own noise
  # (`rake memcheck`; see Rakefile).  Not required by the library.
  gem 'ruby_memcheck', require: false
end
