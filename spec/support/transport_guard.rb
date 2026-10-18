require 'json'
# Examples that leave the default transport moved (ux-r4 item 4, proposed
# by ux-r3-layout after debug_methods_spec failed only after an inspection
# spec that had played a Session on it).  spec_helper resets the default
# transport before every example (position 0, 120 BPM, 4/4), so a moved
# transport can't leak into the next example any more; what is left is the
# convention in CLAUDE.md ("Specs that run a Session on the shared
# transport must MB::Sound.rewind afterwards"), which matters in the
# console and in scripts, where nothing resets it.
#
# MB_SOUND_TRANSPORT_CHECK:
# - unset or "fail" (default): an example that leaves it moved fails,
#   naming what moved (rewind in an `after` block, which runs before this
#   config-level hook; an `around` hook's ensure runs too late);
# - "report": such examples are listed after the run instead (rake
#   spec:parallel collects each process's list through
#   MB_SOUND_TRANSPORT_REPORT, a JSON path, and prints them with the
#   slowest examples);
# - "off": no check.
#
# Failing by default: measured 2026-10-18 in report mode, only 2 of 9089
# examples left it moved (rack_documents_spec, channels_spec's play), both
# fixed, so the convention costs almost nothing to keep and a new offender
# is named where it is written.  spec_helper's reset before each example
# still keeps results independent of the order either way.
module TransportGuard
  MODES = %w[report fail off].freeze

  @records = []

  class << self
    attr_reader :records

    def mode
      m = ENV.fetch('MB_SOUND_TRANSPORT_CHECK', 'fail')
      raise ArgumentError, "MB_SOUND_TRANSPORT_CHECK is one of #{MODES.join(', ')} (got #{m.inspect})" unless MODES.include?(m)
      m
    end

    # What differs from the reset state of the default transport, as text
    # ("position 3/2, bpm 126"), or nil.
    def moved(t = MB::Sound::Sequence.transport)
      out = []
      out << "position #{t.position}" unless t.position.zero?
      out << "bpm #{t.bpm}" unless t.bpm == 120
      out << "meter #{t.meters.map { |m| m.respond_to?(:to_h) ? m.to_h : m }.inspect}" unless t.meters.length == 1 && t.bar_length(0) == 1
      out.empty? ? nil : out.join(', ')
    end
  end
end

unless TransportGuard.mode == 'off'
  RSpec.configure do |config|
    config.after(:each) do |example|
      what = TransportGuard.moved
      next unless what
      if TransportGuard.mode == 'fail'
        raise "the example left the default transport moved (#{what}): MB::Sound.rewind (and reset bpm/meter) in an after block " \
              '(spec/support/transport_guard.rb)'
      end
      TransportGuard.records << { 'example' => example.location, 'description' => example.full_description, 'moved' => what }
    end

    config.after(:suite) do
      list = TransportGuard.records
      if (path = ENV['MB_SOUND_TRANSPORT_REPORT'])
        File.write(path, JSON.generate(list))
      elsif !list.empty?
        puts "\nExamples leaving the default transport moved (#{list.length}; reset before each example, so only a convention; " \
             'MB_SOUND_TRANSPORT_CHECK=fail fails them):'
        list.first(20).each { |r| puts "  #{r['example']}  #{r['moved']}" }
        puts "  ... #{list.length - 20} more" if list.length > 20
      end
    end
  end
end
