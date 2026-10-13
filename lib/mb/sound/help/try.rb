module MB
  module Sound
    module Help
      # Runs topic examples ("try it") through the background Session: the
      # code is printed, run as if typed (in a Try::Context that forwards to
      # MB::Sound), and the players it started stop (short fade) after the
      # example's bars, counted from the bar where they land.  Knobs, tracks,
      # and scenes it defines stay (their names start with try so they don't
      # clash with yours).
      #
      # Sound plays at the listening level (Help::Level): the context
      # multiplies the graphs given to #bg, #play, and track patches by
      # Level.try_gain.  The first try before any level check runs one when
      # the console is interactive.
      module Try
        # The +self+ of a running example: every call goes to MB::Sound,
        # except those that start sound, which get the listening gain.
        # Blocks inside the example (scheduled blocks, track patches) keep
        # this +self+, so they get it too.
        class Context < BasicObject
          def initialize(gain)
            @gain = gain
          end

          attr_reader :gain

          def bg(name_or_sound, sound = nil, **opts)
            if sound.nil?
              ::MB::Sound.bg(scaled(name_or_sound), **opts)
            else
              ::MB::Sound.bg(name_or_sound, scaled(sound), **opts)
            end
          end

          def play(sound, *args, **opts)
            ::MB::Sound.play(scaled(sound), *args, **opts)
          end

          def track(*args, **opts, &patch)
            return ::MB::Sound.track(*args, **opts) unless patch
            gain = @gain
            ::MB::Sound.track(*args, **opts) { |*a, **kw| Context.scale(patch.call(*a, **kw), gain) }
          end

          def respond_to_missing?(name, include_private = false) = ::MB::Sound.respond_to?(name, include_private)

          def method_missing(name, *args, **opts, &block)
            ::MB::Sound.public_send(name, *args, **opts, &block)
          end

          def inspect = "#<Help::Try::Context gain=#{@gain}>"

          # Multiplies graphs (nodes, bundles, Arrays of them) by +gain+;
          # clips, kits, and other values pass through.
          def self.scale(sound, gain)
            return sound if gain == 1
            case sound
            when ::MB::Sound::GraphNode, ::MB::Sound::GraphNode::Channels then sound * gain
            when ::Array then sound.map { |s| scale(s, gain) }
            else sound
            end
          end

          private

          def scaled(sound) = Context.scale(sound, @gain)
        end

        module_function

        # Runs +example+ (a Topic::Example) at +gain+ (the listening level by
        # default) and returns its result.
        def run(example, out: $stdout, gain: nil, calibrate: $stdin.tty?)
          if gain.nil? && calibrate && example.sound && !Level.saved?
            out.puts Text.c(:dim, 'First, a level check so examples play at a comfortable level:')
            Level::Calibration.new(out: out).run
          end
          gain ||= Level.try_gain

          out.puts Text.c(:dim, "# #{example.title}")
          example.source.each_line { |l| out.puts Text.code(l.chomp) }
          before = MB::Sound.players.keys
          result = Context.new(gain).instance_exec(&example.block)
          started = MB::Sound.players.keys - before
          unless started.empty?
            MB::Sound.after(example.bars + 1) {
              left = started & MB::Sound.players.keys
              MB::Sound.stop(*left, fade: 0.25) unless left.empty?
            }
            out.puts Text.c(:dim, "# stops #{started.map(&:inspect).join(', ')} after #{example.bars} bars (or `stop #{started.first.inspect}`); level #{format('%+.0f', 20 * Math.log10(gain))} dB (help.level)")
          end
          result
        end
      end
    end
  end
end
