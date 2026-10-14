require 'fileutils'
require 'json'

# RSpec side of WarningGuard (support/warning_guard.rb): fails each example
# that printed a warning (its own or a Ruby subprocess's), and the run for
# warnings printed outside examples.
#
# MB_SOUND_WARNINGS_REPORT=path (set by rake spec:parallel) also writes
# every stray warning of the run to that JSON file for the summary.
module WarningGuard
  # Raised (from an after hook) in an example that printed warnings.
  class StrayWarning < StandardError; end

  # Raised after the suite for warnings printed outside examples.
  class StrayWarningsOutsideExamples < StandardError; end

  # Subprocesses write here (see WarningGuard.dir).
  ENV['MB_SOUND_WARNINGS_DIR'] = File.join(SpecTmp::ROOT, 'warnings')
  FileUtils.mkdir_p(ENV['MB_SOUND_WARNINGS_DIR'])

  HELPER = File.expand_path('../subprocess_warning_helper.rb', __dir__)

  # The RUBYOPT option that loads the subprocess helper.
  def self.rubyopt
    "-r#{HELPER}"
  end

  ENV['RUBYOPT'] = [rubyopt, ENV['RUBYOPT']].compact.join(' ') unless ENV['RUBYOPT'].to_s.include?(HELPER)

  @outside = []
  @all = []
  @reported = []

  class << self
    # Warnings printed outside examples so far.
    attr_reader :outside

    # Every stray warning of the run (for MB_SOUND_WARNINGS_REPORT).
    attr_reader :all

    # Report-only warnings (REPORT_ONLY categories) of the run.
    attr_reader :reported

    # Splits +records+ into failing ones (returned) and report-only ones
    # (added to #reported).
    def sort_out(records)
      report, fail = records.partition(&:report_only)
      @reported.concat(report)
      fail
    end

    def message_for(records, intro)
      lines = records.map(&:to_s).tally.map { |text, n| n > 1 ? "  #{text} (#{n} times)" : "  #{text}" }
      <<~MSG.chomp
        #{intro}
        #{lines.join("\n")}
        Fix the code, or expect a deliberate warning with `expect { ... }.to output(/.../).to_stderr`
        (`expect_script_warnings(/.../)` for a script's); see spec/support/warning_guard.rb.
      MSG
    end
  end

  # Included in example groups.
  module Helpers
    # Lets this example's Ruby subprocesses (bin/ scripts, fork_script)
    # print warnings matching any of +patterns+; the spec checks them in the
    # script's output itself.
    def expect_script_warnings(*patterns)
      (@expected_script_warnings ||= []).concat(patterns)
    end
  end
end

RSpec.configure do |config|
  config.include WarningGuard::Helpers

  config.around(:each) do |example|
    # Anything recorded before the example started (loading files,
    # before(:context) hooks, a thread from an earlier example) belongs to
    # no example.
    WarningGuard.outside.concat(WarningGuard.sort_out(WarningGuard.take))
    WarningGuard.example = example.location
    example.run
  ensure
    WarningGuard.example = nil
  end

  # Registered here, so it runs after the example's own after hooks.
  config.after(:each) do |example|
    expected = @expected_script_warnings || []
    subprocess = WarningGuard.take_subprocess.reject { |r| expected.any? { |pat| pat.match?(r.message) } }
    stray = WarningGuard.sort_out(WarningGuard.take + subprocess)
    WarningGuard.reported.each { |r| r.example ||= example.location }
    stray.each { |r| r.example ||= example.location }

    unless stray.empty?
      WarningGuard.all.concat(stray)
      raise WarningGuard::StrayWarning, WarningGuard.message_for(stray, "#{example.location} printed #{stray.length == 1 ? 'a warning' : "#{stray.length} warnings"}:")
    end
  end

  config.after(:suite) do
    outside = WarningGuard.outside + WarningGuard.sort_out(WarningGuard.take + WarningGuard.take_subprocess)
    WarningGuard.all.concat(outside)

    if (path = ENV['MB_SOUND_WARNINGS_REPORT'])
      File.write(path, JSON.pretty_generate((WarningGuard.all + WarningGuard.reported).map(&:to_h)) + "\n")
    elsif WarningGuard.reported.any?
      # (spec:parallel lists them from the report files instead)
      texts = WarningGuard.reported.map { |r| r.to_s.sub(/\A\S+:\d+: /, '') }.uniq
      puts "\nRuby #{WarningGuard::REPORT_ONLY.map { |c| ":#{c}" }.join('/')} warnings (reported, not failing; see spec/support/warning_guard.rb):"
      texts.each { |t| puts "  #{t.lines.first.chomp}" }
    end

    unless outside.empty?
      raise WarningGuard::StrayWarningsOutsideExamples,
        WarningGuard.message_for(outside, "#{outside.length} #{outside.length == 1 ? 'warning was' : 'warnings were'} printed outside examples:")
    end
  end
end
