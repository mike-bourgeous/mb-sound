# Loaded through RUBYOPT (see spec_helper) into Ruby subprocesses started by
# specs, mostly bin/ scripts: records the warnings they print (with the
# :deprecated and :performance categories on, like the spec process;
# $VERBOSE stays as the script sets it) and writes them to WarningGuard.dir
# at exit, where the spec process finds them and fails the example that
# started the process (see spec/support/warning_guard.rb).
#
# Nothing else is loaded before the script, so gems are still activated by
# the script's own `require 'bundler/setup'`.
require_relative 'support/warning_guard'

WarningGuard.install!(subprocess: true)
