# File to be included via simplecov_runner.rb when testing standalone scripts from bin/
require 'securerandom'
require 'simplecov'

if RUBY_VERSION.start_with?('3.4')
  # FIXME: get simplecov working in Ruby 3.4 and subprocesses, instead of crashing
  #     munmap_chunk(): invalid pointer
  #     Aborted (core dumped)
  warn 'TEST_IGN: Skipping code coverage for external binaries because of a crash in Ruby 3.4.'
  warn 'TEST_IGN: See https://github.com/mike-bourgeous/mb-sound/pull/35'
else
  SimpleCov.start do
    SimpleCov.command_name "#{$0} #{$$} #{SecureRandom.uuid}"
    SimpleCov.formatter SimpleCov::Formatter::SimpleFormatter
    SimpleCov.minimum_coverage 0
  end

  # This require line makes sure the original script file is processed by simplecov
  require File.expand_path($0, '.')

  exit 0
end
