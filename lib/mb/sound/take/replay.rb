require 'optparse'

module MB
  module Sound
    class Take
      # Replays a take (see Take#save and Take#replay): evaluates each
      # console line again at the time it was typed, with every change it
      # makes forced to land where it landed live (see
      # Session::Changes#change), starting from the take's tempo, master
      # gain, default fades, and random generator state.
      #
      # Lines are evaluated a little ahead of their time on the scheduler
      # (see Session::Scheduler), so building graphs doesn't hold up the
      # render thread; decisions that depend on time (undo cancelling
      # changes that haven't landed, launch points) use the line's recorded
      # time (Session#now), so the replay matches the performance.
      #
      # The session's own timing (launches, swaps, stops, fades, mutes,
      # undo) is exact at any buffer size.  Not reproduced exactly: tempo
      # and master gain changes (they apply at buffer starts and when the
      # line runs), anything nondeterministic in the code, and live MIDI.
      # Oscillators accumulate their phase per buffer, so tones differ
      # between buffer sizes by about 1e-12 (naive shapes like aramp can
      # move an edge by a sample).
      class Replay
        Line = Struct.new(:issued, :lands, :code, :epoch, keyword_init: true)

        # The last Replay created (for loading a saved take from code).
        class << self
          attr_accessor :last
        end

        attr_reader :lines, :ends

        def initialize(bpm:, bar_length:, master_gain:, fade_in:, fade_out:, rng:, meters: [], ends: nil, ends_epoch: 0)
          @start = { bpm: bpm, bar_length: bar_length, meters: meters, master_gain: master_gain, fade_in: fade_in, fade_out: fade_out, rng: rng }
          @ends = ends&.to_r
          @ends_epoch = ends_epoch
          @lines = []
          yield self if block_given?
          self.class.last = self
        end

        # Adds a console line typed at +issued+ (whole notes) whose changes
        # landed at +lands+, after +epoch+ seeks had landed (the line runs in
        # that pass over the timeline; see Session#epoch).
        def line(issued, lands, code, epoch: 0)
          @lines << Line.new(issued: issued.to_r, lands: lands.map(&:to_r), code: code, epoch: epoch)
          self
        end

        # Sets up +session+ (fresh, with its timeline at the start) to play
        # the take: restores the start state and schedules every line.
        def schedule(session)
          t = session.transport
          t.bar_length = @start[:bar_length]
          (@start[:meters] || []).each { |pos, len| t.meter(len, at: pos) }
          t.bpm = @start[:bpm]
          session.master_gain = @start[:master_gain]
          session.fade_in = @start[:fade_in]
          session.fade_out = @start[:fade_out]
          MB::Sound.instance_variable_set(:@root_rng, Marshal.load(@start[:rng].unpack1('m0'))) if @start[:rng]

          binding = Take.console_binding
          @base_epoch = session.epoch
          @lines.each_with_index do |l, i|
            eval_at = [l.issued, *l.lands].min
            session.schedule(eval_at, description: "take line #{i + 1}", epoch: @base_epoch + l.epoch.to_i) do
              run_line(session, binding, l, i)
            end
          end
          session
        end

        # Renders the take to +output+ (a filename or an output object) in
        # buffers of +buffer_sizes+ (cycled, e.g. [367, 368]), until the
        # take's end (+:finish+ whole notes; see Take#save), then stops
        # everything and adds +:tail+ seconds for master effects tails.
        # Yields each buffer of the mix if a block is given.  Returns the
        # frames rendered.
        def render(output, buffer_sizes: [800], finish: @ends, tail: 2, channels: 2, &tap)
          raise ArgumentError, 'Pass finish: (whole notes) for a take without an end' if finish.nil?

          output = MB::Sound.file_output(output, channels: channels, overwrite: true) if output.is_a?(String)
          transport = Sequence::Transport.new(bpm: @start[:bpm], bar_length: @start[:bar_length])
          session = Session.new(output: output, transport: transport, channels: channels, buffer_size: buffer_sizes.first, realtime: false, raise_errors: false)
          session.add_tap(&tap) if tap
          live = MB::Sound.live?
          MB::Sound.live = true
          schedule(session)

          frames = 0
          sizes = buffer_sizes.cycle
          until transport.position >= finish && session.epoch >= @base_epoch + @ends_epoch
            n = sizes.next
            session.process_buffer(n)
            frames += n
          end

          if tail && tail > 0
            session.remove(fade: 0)
            left = (tail * output.sample_rate).round
            while left > 0
              n = [sizes.next, left].min
              session.process_buffer(n)
              frames += n
              left -= n
            end
          end

          frames
        ensure
          MB::Sound.live = live unless live.nil?
          session&.close
        end

        # Plays the take in the background session until its end, then
        # fades out and waits for the tails.
        def play
          session = Session.default
          raise 'Stop the background players first (e.g. panic)' unless session.idle?
          MB::Sound.rewind
          live = MB::Sound.live?
          MB::Sound.live = true
          schedule(session)
          session.add(0.constant, name: :take_clock, on: :now) # keeps the timeline moving between lines
          sleep 0.1 until session.transport.position >= (@ends || 0) && session.epoch >= @base_epoch + @ends_epoch
          MB::Sound.outro
          MB::Sound.wait
        ensure
          MB::Sound.live = live unless live.nil?
        end

        # Command-line entry for saved takes: `-o file` renders, `-b
        # 367,368` picks buffer sizes; otherwise plays.  Only runs when
        # +file+ is the script being run.  Returns the Replay.
        def main(argv, file = nil)
          return self if file && File.expand_path(file) != File.expand_path($PROGRAM_NAME)

          out = nil
          sizes = [800]
          OptionParser.new do |o|
            o.banner = "Usage: #{$PROGRAM_NAME} [-o output.flac] [-b buffer_sizes]"
            o.on('-o', '--output FILE', 'Render to a file instead of playing') { |f| out = f }
            o.on('-b', '--buffer-sizes LIST', Array, 'Buffer sizes to cycle through (e.g. 367,368)') { |l| sizes = l.map { |x| Integer(x) } }
          end.parse!(argv)

          if out
            frames = render(out, buffer_sizes: sizes)
            puts "Rendered #{frames} frames to #{out}"
          else
            play
          end
          self
        end

        private

        def run_line(session, binding, line, index)
          Session.with_context(session: session, time: line.issued, source: :replay) do
            Session.with_perform(session: session, forced: line.lands.dup, now: line.issued, source: :replay) do
              binding.eval(line.code, "take line #{index + 1}")
            end
          end
        rescue => e
          warn "Take line #{index + 1} raised #{e.class}: #{e.message}"
        end
      end
    end
  end
end
