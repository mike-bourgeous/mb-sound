module MB
  module Sound
    class Notes
      # An Envelope made through a Notes instance (Notes#env, #amp_env,
      # #fm_env, #filter_env): its gate, trigger, velocity, and choke inputs
      # come from the Notes, it registers with the Notes for Notes#idle?,
      # and with #gm (on by default) its attack, decay, and release times
      # are multiplied by the GM2 sound controllers CC 73 (Notes#attack_time),
      # CC 75 (#decay_time), and CC 72 (#release_time): x1/8 at 0, x1 at 64,
      # x8 at 127, exponentially, read through nodes so knobs act at once.
      #
      # Times given as numbers or lengths in seconds are scaled as they are;
      # musical lengths (Durations) and sample counts are converted to
      # seconds when set, so with #gm they no longer follow the tempo.  Times
      # given as nodes are multiplied by the factor nodes.
      class NoteEnvelope < MB::Sound::Envelope
        # The Notes method for each segment's GM2 time controller.
        GM_TIMES = { attack: :attack_time, decay: :decay_time, release: :release_time }.freeze

        # The Notes instance this envelope belongs to.
        attr_reader :notes

        # Takes the Envelope options, plus the +:notes+ it belongs to and
        # whether +:gm+ scaling is on (see the class description).
        def initialize(notes:, gm: true, **options)
          @notes = notes
          start = notes.note_stream.reader
          @time = start.cursor # stream time of the next buffer (see #sample)
          start.close
          @gm = false
          @base_times = {}
          @gm_nodes = {}
          super(**options)
          gm(gm)
        end

        # Turns GM2 time scaling on or off (see the class description).
        # Returns self.
        def gm(enabled = true)
          enabled = !!enabled
          return self if enabled == @gm

          @gm = enabled
          GM_TIMES.each_key { |seg| public_send(:"#{seg}=", @base_times[seg]) }
          self
        end

        # Returns +count+ samples, or nil once the Notes' stream has ended
        # (a non-looping clip or a MIDI file has played its last event)
        # before this buffer, every envelope of the Notes is idle (see
        # Notes#envelopes_idle?), and the Notes' output is quiet (see
        # Notes#quiet?; a Synth lane's output under -90 dB), so e.g.
        # `noise * clip.env` ends with its clip like the Notes gate does,
        # while an envelope into a resonant filter lets the filter ring out.  Envelopes on looping or live
        # streams never end.  Waiting for every envelope (not just this one)
        # keeps a short envelope (e.g. Notes#cutoff's filt_env) from ending
        # a voice while a longer one (the amp_env) is still releasing.
        #
        # The end is judged from the stream time where this buffer starts
        # (counted by the envelope) and the time of the stream's last event
        # (MIDI::Stream#music_end), so it doesn't depend on which other
        # nodes of the stream exist or have been sampled first in this
        # buffer (Notes#ended? waits for every reader of the stream, and
        # skipped Synth lanes don't sample their envelopes).
        def sample(count)
          count = count.round
          return nil if idle? && stream_over? && @notes.envelopes_idle? && @notes.quiet?
          @start_time = @time
          @idle_at_start = idle?
          @time = @notes.note_stream.advance(@time, count, @sample_rate)
          super
        end

        # True if this envelope was sounding (not #idle?) at stream time
        # +time+, the start of a buffer, whether or not it has rendered that
        # buffer yet: its state before the buffer that starts at +time+ if
        # it has (kept from before rendering it), else its current state.
        # Notes::KeyTrigger asks this to tell re-strikes of a sounding
        # voice from fresh notes regardless of which node of the graph is
        # sampled first (see Notes#adding_at?).  An envelope that lags
        # behind +time+ (e.g. in a skipped Synth lane) is idle, so it gives
        # its current state too.
        def sounding_at?(time)
          if @start_time && @start_time <= time && time < @time
            !@idle_at_start
          else
            !idle?
          end
        end

        # True if the stream's last event was before the start of the next
        # buffer (never for looping and live streams).
        def stream_over?
          last = @notes.note_stream.music_end
          !last.nil? && last < @time
        end

        # True if GM2 time scaling is on (see #gm).
        def gm?
          @gm
        end

        # The attack, decay, and release times as given, before GM2 scaling.
        def base_times
          @base_times.dup
        end

        def attack=(time)
          super(gm_time(:attack, time))
        end
        alias attack_time= attack=

        def decay=(time)
          super(gm_time(:decay, time))
        end
        alias decay_time= decay=

        def release=(time)
          super(gm_time(:release, time))
        end
        alias release_time= release=

        private

        # Records +time+ as the base time of +segment+ and returns it scaled
        # if #gm is on.  Lets go of the scaling node made for the previous
        # time, if any.
        def gm_time(segment, time)
          @base_times[segment] = time
          drop_gm_node(segment)
          return time unless @gm

          factor = @notes.public_send(GM_TIMES.fetch(segment))
          node = case time
                 when Numeric
                   GmTime.new(factor, time.to_f, sample_rate: @sample_rate)
                 when Length
                   return time if time.respond_to?(:node) && time.node # node lengths stay unscaled
                   GmTime.new(factor, Length.seconds(time, sample_rate: @sample_rate).to_f, sample_rate: @sample_rate)
                 else
                   return time unless time.respond_to?(:sample)
                   time * factor
                 end

          @gm_nodes[segment] = node
          node
        end

        # Reads GM-scaled fixed times through GmTime#length_samples (a
        # number while the controller holds still) with Notes.fast_paths.
        def read_length(key, source, count)
          gm = @gm_nodes[key]
          return super unless gm.is_a?(GmTime) && Notes.fast_paths
          fit(key, gm.length_samples(count, @sample_rate), count)
        end

        # Destroys the Tee branches of a scaling node that is no longer used
        # (see #gm_time), so the shared controller's Tee stops feeding it.
        def drop_gm_node(segment)
          node = @gm_nodes.delete(segment)
          return unless node

          node.sources.each_value do |src|
            src.destroy if src.is_a?(GraphNode::Tee::Branch)
          end
        end

        # A fixed time in seconds scaled by a GM2 time controller (see
        # NoteEnvelope#gm): the controller's buffer times the time, in
        # single precision like a Multiplier.  NoteEnvelope reads it through
        # #length_samples, which gives the length in samples as one number
        # (computed once per controller value) when the controller's buffer
        # is constant, skipping a buffer multiply per segment per buffer.
        class GmTime
          include GraphNode
          include GraphNode::SampleRateHelper

          # The controller node (a sampler branch).
          attr_reader :factor

          # The time in seconds before scaling.
          attr_reader :time

          def initialize(factor, time, sample_rate: 48000)
            @factor = factor.get_sampler
            @time = time.to_f
            @sample_rate = sample_rate.to_f
            @buf = nil
            @node_type_name = 'GM time'
          end

          # Returns +count+ samples of the scaled time in seconds, or nil if
          # the controller ended.
          def sample(count)
            f = @factor.sample(count)
            return nil if f.nil?

            @buf = Numo::SFloat.zeros(f.length) if @buf.nil? || @buf.length != f.length
            scale(@buf, f)
          end

          # Returns the scaled time in samples at +sample_rate+ for the next
          # +count+ samples: a Float when the controller's buffer is
          # constant, else an SFloat (the same values #sample gives, times
          # the rate in single precision, as Length::Source#samples
          # computes), or nil if the controller ended.
          def length_samples(count, sample_rate)
            f = @factor.sample(count)
            return nil if f.nil?

            # The same frozen buffer as last time (e.g. a Notes controller's
            # constant buffer passed through a Tee) holds the same values
            return @steady_samples if f.equal?(@steady_buf) && sample_rate == @steady_rate
            @steady_buf = nil

            if f.length == count && (v = f[0]) == f.max && v == f.min
              if v != @steady_factor || sample_rate != @steady_rate
                @steady_factor = v
                @steady_rate = sample_rate
                @steady_samples = (scale(Numo::SFloat.zeros(1), Numo::SFloat[v]) * sample_rate)[0]
              end
              @steady_buf = f if f.frozen?
              return @steady_samples
            end

            @buf = Numo::SFloat.zeros(f.length) if @buf.nil? || @buf.length != f.length
            scale(@buf, f) * sample_rate
          end

          def sources
            { factor: @factor }
          end

          def to_s
            "GM time #{MB::M.sigfigs(@time, 4)} s"
          end

          private

          # Fills +buf+ with the time times +f+ (Multiplier's operations).
          def scale(buf, f)
            buf.fill(@time)
            buf.inplace * f
            buf.not_inplace!
          end
        end
      end
    end
  end
end
