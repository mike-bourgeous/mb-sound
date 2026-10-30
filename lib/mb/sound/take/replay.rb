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
      # line runs), and anything nondeterministic in the code.  MIDI read
      # by the session's inputs (Session::MidiInput) replays on the same
      # timeline positions (see #midi).
      # Oscillators accumulate their phase per buffer, so tones differ
      # between buffer sizes by about 1e-12 (naive shapes like asaw can
      # move an edge by a sample).
      class Replay
        Line = Struct.new(:issued, :lands, :code, :epoch, :choices, keyword_init: true)

        # The last Replay created (for loading a saved take from code).
        class << self
          attr_accessor :last
        end

        # The longest a replay of a take without a recorded length (see
        # +:seconds+ in #initialize) renders or plays before stopping with a
        # warning; pass +max_seconds:+ to #render or #play for longer takes.
        MAX_SECONDS = 3600

        # How much longer than the live take (its +:seconds+) a replay may
        # run before it stops with a warning (a replay that never reaches
        # the take's end, e.g. code that changed since the take).
        EXTRA_SECONDS = 60

        attr_reader :lines, :ends

        # The take's length in seconds as performed (nil for takes saved
        # before it was recorded).
        attr_reader :seconds

        # +:master_gain_post+ is where the master gain applied (see
        # Session#master_gain_post?); takes saved before it existed (before
        # 2026-10-13) don't give it, and played it after the master chain.
        # +:replace_declick+ likewise (see Session#replace_declick): takes
        # saved before 2026-10-17 don't give it, and switched replacements
        # with a hard cut, so they replay exactly.
        def initialize(bpm:, bar_length:, master_gain:, master_gain_post: true, fade_in:, fade_out:, rng:, replace_declick: false, meters: [], key: nil, ends: nil, ends_epoch: 0, seconds: nil, run_frame: 0, odometer: 0)
          @start = { bpm: bpm, bar_length: bar_length, meters: meters, key: key, master_gain: master_gain, master_gain_post: master_gain_post, fade_in: fade_in, fade_out: fade_out, replace_declick: replace_declick, rng: rng, run_frame: run_frame, odometer: odometer }
          @ends = ends&.to_r
          @ends_epoch = ends_epoch
          @seconds = seconds
          @lines = []
          @midi = {}
          @decisions = []
          @gestures = []
          yield self if block_given?
          self.class.last = self
        end

        # Adds a console line typed at +issued+ (whole notes) whose changes
        # landed at +lands+ (each a position, or [position, time] for a
        # change made for a time already past, e.g. a lead: track's
        # launch), after +epoch+ seeks had landed (the line runs in that
        # pass over the timeline; see Session#epoch).  +choices+ are the
        # answers the line got live ([kind, key, choice]; see
        # Take.note_choice), given again instead of asking.
        def line(issued, lands, code, epoch: 0, choices: [])
          lands = lands.map { |t| t.is_a?(Array) ? t.map(&:to_r) : t.to_r }
          @lines << Line.new(issued: issued.to_r, lands: lands, code: code, epoch: epoch, choices: choices)
          self
        end

        # Adds MIDI the session's input named +input+ read during the take:
        # [epoch, pos, bytes] rows (see Take#midi), played again on the
        # same timeline positions (see Session::MidiInput#replay).
        def midi(rows, input: nil)
          (@midi[input] ||= []).concat(rows.map { |epoch, pos, bytes| [epoch, pos.to_r, bytes] })
          self
        end

        # Adds decisions made during the take by params read ahead of time
        # (knobs read for a future position: [name, epoch, pos, value]
        # rows; see Session::Decisions), answered again instead of decided
        # anew.
        def decisions(rows)
          @decisions.concat(rows.map { |name, epoch, pos, value| [name, epoch, pos.to_r, value] })
          self
        end

        # The recorded decisions (see #decisions).
        # Raw steps of knob gestures (see Take#gestures).
        def gestures(rows)
          @gestures.concat(rows.map { |name, epoch, pos, steps| [name, epoch, pos.to_r, steps] })
          self
        end

        # The recorded MIDI (a Hash from input name to rows; see #midi).
        def midi_events
          @midi
        end

        # Sets up +session+ (fresh, with its timeline at the start) to play
        # the take: restores the start state and schedules every line.
        def schedule(session)
          t = session.transport
          t.bar_length = @start[:bar_length]
          (@start[:meters] || []).each { |pos, len| t.meter(len, at: pos) }
          # The session key the take started in (takes saved before
          # midi-consol-2 start in C major, the only key there was)
          root, mode = @start[:key] || ['C', :major]
          t.reset_key(MusicalKey.default.with_root(root).with_mode(mode))
          t.bpm = @start[:bpm]
          session.master_gain = @start[:master_gain]
          session.master_gain_post = !!@start[:master_gain_post]
          session.fade_in = @start[:fade_in]
          session.fade_out = @start[:fade_out]
          session.replace_declick = @start[:replace_declick]
          session.restore_run(@start[:run_frame], @start[:odometer]) if @start[:run_frame].to_i > 0
          MB::Sound::Internal.restore_rng(Marshal.load(@start[:rng].unpack1('m0'))) if @start[:rng]

          binding = Take.console_binding
          @base_epoch = session.epoch

          # MIDI plays from the take, never from live input
          session.replay_midi!(@base_epoch)
          @midi.each { |name, rows| session.midi_in(name).replay(rows, base_epoch: @base_epoch) }
          session.replay_decisions!(@decisions, base_epoch: @base_epoch) unless @decisions.empty?
          session.replay_gestures!(@gestures, base_epoch: @base_epoch) unless @gestures.empty?
          @lines.each_with_index do |l, i|
            eval_at = [l.issued, *l.lands.map { |t| Array(t).first }].min
            session.schedule(eval_at, description: "take line #{i + 1}", epoch: @base_epoch + l.epoch.to_i, owner: :take, exact: true) do
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
        #
        # The render also ends (before the tail) when the session has gone
        # quiet for good short of +:finish+: nothing playing or due, so the
        # timeline has stopped (see Session; a take's end is where the live
        # timeline was when it was saved).  It stops with a warning after
        # +:max_seconds+ (the live take's length plus EXTRA_SECONDS, or
        # MAX_SECONDS for takes without a recorded length), so a replay that
        # never reaches its end can't run forever.
        def render(output, buffer_sizes: [800], finish: @ends, tail: 2, channels: 2, max_seconds: nil, overwrite: true, &tap)
          raise ArgumentError, 'Pass finish: (whole notes) for a take without an end' if finish.nil?

          output = MB::Sound.file_output(output, channels: channels, overwrite: overwrite) if output.is_a?(String)
          transport = Sequence::Transport.new(bpm: @start[:bpm], bar_length: @start[:bar_length])
          session = Session.new(output: output, transport: transport, channels: channels, buffer_size: buffer_sizes.first, realtime: false, raise_errors: false)
          session.exact_lanes = true # the same lanes at any buffer size (Synth#exact_lanes?)
          session.add_tap(&tap) if tap
          live = MB::Sound.live?
          MB::Sound.live = true
          schedule(session)

          max_seconds ||= default_max_seconds
          max_frames = (max_seconds * output.sample_rate).round
          frames = 0
          sizes = buffer_sizes.cycle
          until transport.position >= finish && session.epoch >= @base_epoch + @ends_epoch
            if frames >= max_frames
              warn "Stopped replaying the take after #{max_seconds.round(3)} seconds without reaching its end (#{stamp(session, finish)}; at #{stamp(session, transport.position)}); pass max_seconds: to render longer"
              break
            end

            # Recorded MIDI still to come means the live timeline was moving
            # (something not in the take, like the keyboard's default patch,
            # kept it going), so it keeps moving here until the last row
            # plays, then pauses when idle as it would live
            session.advance_idle = midi_pending?(session)

            before = transport.position
            n = [sizes.next, max_frames - frames].min
            session.process_buffer(n)
            frames += n

            # The timeline stops when nothing plays; with nothing playing or
            # due, it never moves again
            break if transport.position == before && session.idle? && !session.schedule_due? && ended_short(session, finish)
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
        # fades out and waits for the tails.  Gives up with a warning after
        # +:max_seconds+ (see #render).
        def play(max_seconds: nil)
          session = Session.default
          raise 'Stop the background players first (e.g. panic)' unless session.idle?
          MB::Sound.rewind
          live = MB::Sound.live?
          MB::Sound.live = true
          exact = session.exact_lanes
          session.exact_lanes = true # as #render (Synth#exact_lanes?)
          schedule(session)
          session.add(0.constant, name: :take_clock, on: :now) # keeps the timeline moving between lines
          max_seconds ||= default_max_seconds
          deadline = MB::U.clock_now + max_seconds
          until session.transport.position >= (@ends || 0) && session.epoch >= @base_epoch + @ends_epoch
            if MB::U.clock_now > deadline
              warn "Stopped playing the take after #{max_seconds.round(3)} seconds without reaching its end (#{stamp(session, @ends || 0)}); pass max_seconds: to play longer"
              break
            end
            Internal.wait_audio(session, 0.1)
          end
          MB::Sound.outro
          MB::Sound.wait
        ensure
          session&.end_replay_midi!
          session.exact_lanes = exact if session && !exact.nil?
          MB::Sound.live = live unless live.nil?
        end

        # Command-line entry for saved takes: `-o file` renders, `-b
        # 367,368` picks buffer sizes; otherwise plays.  Only runs when
        # +file+ is the script being run.  Returns the Replay.
        def main(argv, file = nil)
          return self if file && File.expand_path(file) != File.expand_path($PROGRAM_NAME)

          out = nil
          sizes = [800]
          force = false
          rest = OptionParser.new do |o|
            o.banner = "Usage: #{$PROGRAM_NAME} [-o output.flac] [-f] [-b buffer_sizes]"
            o.on('-o', '--output FILE', 'Render to a file instead of playing') { |f| out = f }
            o.on('-f', '--force', '--overwrite', 'Overwrite the output file') { force = true }
            o.on('-b', '--buffer-sizes LIST', Array, 'Buffer sizes to cycle through (e.g. 367,368)') { |l| sizes = l.map { |x| Integer(x) } }
          end.parse!(argv)
          # An audio file name alone renders to it, as in song scripts
          out ||= rest.find { |a| a.match?(ScriptRunner::AUDIO_EXTENSIONS) }

          if out
            frames = render(out, buffer_sizes: sizes, overwrite: force ? true : :prompt)
            puts "Rendered #{frames} frames to #{out}"
          else
            play
          end
          self
        end

        private

        # The default +:max_seconds+ (see #render).
        def default_max_seconds
          @seconds ? @seconds + EXTRA_SECONDS : MAX_SECONDS
        end

        # True if any MIDI input of +session+ has recorded rows left to play.
        def midi_pending?(session)
          @midi.each_key.any? { |name| session.midi_in(name).replay_pending? }
        end

        # A timeline position for messages: bar:beat and whole notes.
        def stamp(session, pos)
          "#{session.stamp(pos)}, #{pos.to_f.round(4)} whole notes"
        end

        # Called when the replay's timeline has stopped for good short of
        # +finish+ (see #render): warns if take lines never ran (they were
        # typed further along the timeline, so the replay went quiet where
        # the performance didn't).  Returns true.
        def ended_short(session, finish)
          left = session.scheduled.count { |h| h.owner == :take }
          if left > 0
            warn "The take's replay went quiet at #{stamp(session, session.transport.position)} with #{left} take line#{left == 1 ? '' : 's'} left to run (the take ends at #{stamp(session, finish)})"
          end
          true
        end

        def run_line(session, binding, line, index)
          Session.with_context(session: session, time: line.issued, source: :replay) do
            Session.with_perform(session: session, forced: line.lands.dup, now: line.issued, source: :replay) do
              old = Thread.current[:mb_sound_replay_choices]
              Thread.current[:mb_sound_replay_choices] = line.choices
              begin
                binding.eval(line.code, "take line #{index + 1}")
              ensure
                Thread.current[:mb_sound_replay_choices] = old
              end
            end
          end
        rescue => e
          warn "Take line #{index + 1} raised #{e.class}: #{e.message}"
        end
      end
    end
  end
end
