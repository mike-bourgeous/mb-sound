require 'fileutils'
require 'json'

# Code coverage for Ruby subprocesses started by specs (mostly bin/ scripts).
#
# Subprocesses load spec/subprocess_coverage_helper.rb through RUBYOPT,
# which records plain Ruby Coverage and writes it to a small JSON file of its
# own in DIR at exit.  This process reads those files after the suite and
# adds them to its own SimpleCov result, so the report covers both.
#
# This replaced running SimpleCov in every subprocess, which merged each
# result into coverage/.resultset.json under a lock with a unique command
# name.  That file was never pruned, so every script run read and rewrote a
# file that grew by ~0.7MB per run (seconds per script after a few suite
# runs), and concurrent spec processes waited on its lock.
module SubprocessCoverage
  DIR = File.join(SpecTmp::ROOT, 'subprocess_coverage')
  FileUtils.mkdir_p(DIR)

  ENV['MB_SOUND_SUBPROCESS_COVERAGE'] = DIR
  ENV['RUBYOPT'] = "-r#{File.expand_path('../subprocess_coverage_helper.rb', __dir__)}"

  @results = []

  class << self
    # Coverage results written by subprocesses, in SimpleCov's resultset
    # format (string keys; see #collect).
    attr_reader :results

    # Reads the subprocess results.  Called after the suite, because DIR is
    # removed (with SpecTmp::ROOT) before SimpleCov builds its result at exit.
    def collect
      @results = Dir[File.join(DIR, '*.json')].sort.filter_map do |f|
        JSON.parse(File.read(f))
      rescue JSON::ParserError => e
        warn "Ignoring unreadable subprocess coverage #{f}: #{e}"
        nil
      end
    end
  end

  # Prepended to SimpleCov's singleton class to add subprocess results to
  # this process's result before SimpleCov stores and reports it.
  module ResultHook
    private

    def process_coverage_result
      result = super
      return result if SubprocessCoverage.results.empty?

      # JSON round trip for the same key format as the subprocess files
      # (SimpleCov::Result does this per file anyway).
      own = JSON.parse(JSON.dump(@result.original_result))
      combined = SubprocessCoverage.results.reduce(own) { |a, b|
        SimpleCov::Combine.combine(SimpleCov::Combine::ResultsCombiner, a, b)
      }

      @result = SimpleCov::Result.new(combined)
    end
  end

  SimpleCov.singleton_class.prepend(ResultHook)
end

RSpec.configure do |config|
  config.after(:suite) do
    SubprocessCoverage.collect
  end
end
