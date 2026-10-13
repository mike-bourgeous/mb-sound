module MB
  module Sound
    module Help
      # Runs topic examples ("try it") through the background Session: the
      # code is printed, run as if typed (in MB::Sound), and the players it
      # started stop (short fade) after the example's bars, counted from the
      # bar where they land.  Knobs, tracks, and scenes it defines stay
      # (their names start with try so they don't clash with yours).
      #
      # Examples play near the level check tone's loudness, so the monitor
      # trim (Help::Level, Session::MonitorTrim) brings them to the
      # listening level, like everything else played live.
      module Try
        module_function

        # Runs +example+ (a Topic::Example) and returns its result.
        def run(example, out: $stdout)
          out.puts Text.c(:dim, "# #{example.title}")
          example.source.each_line { |l| out.puts Text.code(l.chomp) }
          before = MB::Sound.players.keys
          result = MB::Sound.instance_exec(&example.block)
          started = MB::Sound.players.keys - before
          unless started.empty?
            MB::Sound.after(example.bars + 1) {
              left = started & MB::Sound.players.keys
              MB::Sound.stop(*left, fade: 0.25) unless left.empty?
            }
            out.puts Text.c(:dim, "# stops #{started.map(&:inspect).join(', ')} after #{example.bars} bars (or `stop #{started.first.inspect}`)")
          end
          result
        end
      end
    end
  end
end
