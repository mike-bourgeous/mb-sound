# Examples that leave set state (tracks, scenes, players, names, scheduled
# blocks) in the default Session (omnibus12: render_window_script_spec's
# song left the tracks :lead and :hum, so pane_keys_spec's tracks pane
# showed "○ lead stopped no clip" instead of "nothing playing" whenever it
# ran later in the same process).  spec_helper closes a default Session
# holding any of it before every example (the next use makes a fresh one),
# as it closes a running one, so leftovers can't reach the next example;
# this guard names the example that left them, like
# support/transport_guard.rb does for the default transport.
#
# MB_SOUND_SESSION_CHECK:
# - unset or "fail" (default): an example that leaves set state in the
#   default Session fails, naming what it left (close the Session, or the
#   context's, in an `after` block, which runs before this config-level
#   hook);
# - "report": such examples are listed after the run instead;
# - "off": no check.
module SessionGuard
  MODES = %w[report fail off].freeze

  @records = []

  class << self
    attr_reader :records

    def mode
      m = ENV.fetch('MB_SOUND_SESSION_CHECK', 'fail')
      raise ArgumentError, "MB_SOUND_SESSION_CHECK is one of #{MODES.join(', ')} (got #{m.inspect})" unless MODES.include?(m)
      m
    end

    # The set state +session+ holds that a fresh Session doesn't, as text
    # ("tracks :lead, :hum; scenes :intro"), or nil.  Doesn't create the
    # session's arrangement.
    def leftovers(session)
      return nil if session.nil? || session.closed?

      out = []
      set = session.instance_variable_get(:@arrangement)
      if set
        out << "tracks #{set.tracks.keys.map(&:inspect).join(', ')}" unless set.tracks.empty?
        out << "scenes #{set.scenes.keys.map(&:inspect).join(', ')}" unless set.scenes.empty?
      end
      names = session.names.to_h
      out << "names #{names.map { |n, k| "#{n.inspect} (#{k})" }.join(', ')}" unless names.empty?
      players = session.players
      out << "players #{players.keys.map(&:inspect).join(', ')}" unless players.empty?
      stopped = session.stopped
      out << "stopped players #{stopped.keys.map(&:inspect).join(', ')}" unless stopped.empty?
      scheduled = session.scheduled
      out << "#{scheduled.length} scheduled blocks" unless scheduled.empty?
      out.empty? ? nil : out.join('; ')
    end
  end
end

unless SessionGuard.mode == 'off'
  RSpec.configure do |config|
    config.after(:each) do |example|
      what = SessionGuard.leftovers(MB::Sound::Session.existing)
      next unless what
      if SessionGuard.mode == 'fail'
        raise "the example left set state in the default Session (#{what}): close it in an after block " \
              '(spec/support/session_guard.rb)'
      end
      SessionGuard.records << { 'example' => example.location, 'leftovers' => what }
    end

    config.after(:suite) do
      list = SessionGuard.records
      unless list.empty?
        puts "\nExamples leaving set state in the default Session (#{list.length}; closed before each example, so only a convention; " \
             'MB_SOUND_SESSION_CHECK=fail fails them):'
        list.first(40).each { |r| puts "  #{r['example']}  #{r['leftovers']}" }
        puts "  ... #{list.length - 40} more" if list.length > 40
      end
    end
  end
end
