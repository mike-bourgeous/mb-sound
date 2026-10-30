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
      #
      # Multi-segment envelopes (see Envelope.segments) scale each segment
      # by its role (Envelope.segment_role): the first segment by the attack
      # time, the rest before the release by the decay time, and the
      # release segments by the release time.
      class NoteEnvelope < MB::Sound::Envelope
        # The Notes method for each segment role's GM2 time controller.
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
          @frames = 0
          @base_times = {}
          @gm_nodes = {}
          @start_time = nil
          @idle_at_start = nil
          @grid_buf = nil
          @plan_note_stream = nil
          super(**options)
          gm(gm)
        end

        # Turns GM2 time scaling on or off (see the class description).
        # Returns self.
        def gm(enabled = true)
          enabled = !!enabled
          return self if enabled == @gm

          @gm = enabled
          names.each { |seg| set_time(seg, @base_times[seg]) }
          self
        end

        # Returns +count+ samples, or a short buffer (then nil) where the
        # graph ends: at the first point of Notes::Node::END_GRID (every 800
        # samples of the envelope's own output, from its first sample) after
        # the Notes' stream has ended (a non-looping clip or a MIDI file has
        # played its last event) where every envelope of the Notes is idle
        # and the Notes' output is quiet (see Notes#grid_idle; Notes#quiet?
        # is a Synth lane's output under -90 dB), so e.g. `noise * clip.env`
        # ends with its clip like the Notes gate does, while an envelope
        # into a resonant filter lets the filter ring out.  Envelopes on
        # looping or live streams never end.  Waiting for every envelope
        # (not just this one) keeps a short envelope (e.g. Notes#cutoff's
        # filt_env) from ending a voice while a longer one (the amp_env) is
        # still releasing.
        #
        # Buffers crossing a grid point after the stream's last event render
        # in pieces split there, so each envelope knows its state on the
        # point and records it (the last envelope to reach a point in a
        # buffer decides; envelopes rendered before it in that buffer return
        # full buffers, which arithmetic cuts at the decider's short one, and
        # nil from their next buffer on).  The graph so ends on the same
        # sample at any buffer size, where 800-sample buffers ended it before
        # (fixes-13, 2026-10-14; before, it ended at the first buffer start
        # where every envelope was idle, so a resonant filter after
        # `saw * env` was cut -77 to -99 dB down, 0..799 samples earlier, at
        # other buffer sizes).
        #
        # The end is judged from stream time counted by the envelope and the
        # time of the stream's last event (MIDI::Stream#music_end), so it
        # doesn't depend on which other nodes of the stream exist or have
        # been sampled first in this buffer (Notes#ended? waits for every
        # reader of the stream, and skipped Synth lanes don't sample their
        # envelopes).
        def sample(count)
          count = count.round
          return lane_sample(count) unless @notes.envelope_grid?

          stream = @notes.note_stream
          e = @notes.grid_end_frame
          return nil if e && e <= @frames

          @start_time = @time
          @idle_at_start = idle?
          start = @frames
          @time = stream.advance(@time, count, @sample_rate)
          @frames += count
          cut = e && e < @frames ? e - start : nil
          last = stream.music_end
          return super if cut.nil? && (last.nil? || last >= @time)

          grid_sample(count, start, stream, last, cut)
        end

        # The frames this envelope has rendered (fused or not; see
        # Notes#grid_idle).
        def grid_frames
          @frames
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

        # Moves this envelope's stream time and frame count +count+ samples
        # on without rendering (the same bookkeeping as rendering an idle
        # buffer), for a Synth sub-lane that sleeps while the envelope is
        # idle (see GraphNode::SubLane).  Returns self.
        def advance(count)
          count = count.round
          @start_time = @time
          @idle_at_start = idle?
          @time = plan_note_stream.advance(@time, count, @sample_rate)
          @frames += count
          self
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

        # The segment times as given (a Hash of segment name to time; the
        # attack, decay, and release for ADSR envelopes), before GM2
        # scaling.
        def base_times
          @base_times.dup
        end

        # Sets segment +name+'s time (see Envelope#set_time), scaled by its
        # GM2 time controller if #gm is on.
        def set_time(name, time)
          name = segment_name(name)
          super(name, gm_time(name, time))
        end

        private

        # The time as the patch gave it, before GM2 scaling (see
        # Envelope::Preview).
        def preview_time_source(name)
          @gm && @base_times.key?(name) ? @base_times[name] : super
        end

        # #sample in a Synth lane (Notes#envelope_grid? is false): nil once
        # the stream ended before this buffer, every envelope of the Notes
        # is idle, and the lane is quiet (Notes#quiet?), so in-lane filters
        # ring out below -90 dB first; the Synth ends on its own grid (see
        # Synth#check_end).
        def lane_sample(count)
          return nil if idle? && stream_over? && @notes.envelopes_idle? && @notes.quiet?

          @start_time = @time
          @idle_at_start = idle?
          @time = @notes.note_stream.advance(@time, count, @sample_rate)
          @frames += count
          run(count)
        end

        # #sample for a buffer from frame +start+ that may hold the graph's
        # end: rendered in pieces split at the END_GRID points after the
        # stream's last event (+last+), recording this envelope's idle state
        # on each (see Notes#grid_idle), and cut where the graph ends (or at
        # +cut+, where another envelope ended it).
        def grid_sample(count, start, stream, last, cut)
          @grid_buf = Numo::SFloat.zeros(count) if @grid_buf.nil? || @grid_buf.length != count
          out = @grid_buf
          grid = Notes::Node::END_GRID
          limit = cut || count
          g = (start / grid + 1) * grid
          o = 0
          while o < limit
            stop = MB::M.min(g - start, limit)
            piece = run(stop - o)
            return o == 0 ? nil : out[0...o] if piece.nil?

            out[o...(o + piece.length)] = piece
            return out[0...(o + piece.length)] if piece.length < stop - o

            o = stop
            next unless o == g - start

            if !last.nil? && last < stream.advance(@start_time, o, @sample_rate) && idle? && @notes.grid_idle(self, g)
              return out[0...o]
            end
            g += grid
          end

          o < count ? out[0...o] : out
        end

        # Records +time+ as the base time of +segment+ and returns it scaled
        # if #gm is on.  Lets go of the scaling node made for the previous
        # time, if any.
        def gm_time(segment, time)
          @base_times[segment] = time
          drop_gm_node(segment)
          return time unless @gm

          # A zero time scaled is zero for any (finite) GM factor: no node,
          # so the planner has no 0 * x to fold (2026-10-10)
          return time if time.is_a?(Numeric) && time == 0
          return time if time.is_a?(Length) && !(time.respond_to?(:node) && time.node) &&
            Length.seconds(time, sample_rate: @sample_rate).to_f == 0

          role = self.class.segment_role(names.index(segment), release_node)
          factor = @notes.public_send(GM_TIMES.fetch(role))
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
        # number while the controller holds still) with Kernels.notes_fast?.
        def read_length(key, source, count)
          gm = @gm_nodes[key]
          return super unless gm.is_a?(GmTime) && Kernels.notes_fast?
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

            # The same frozen buffer as last time with the same generation
            # (e.g. a Notes controller's constant buffer passed through a
            # Tee; see GraphNode::FrozenView) holds the same values
            key = (@steady_buf ||= GraphNode::FrozenView::Key.new)
            return @steady_samples if sample_rate == @steady_rate && key.match?(f)
            key.clear

            if f.length == count && (v = f[0]) == f.max && v == f.min
              if v != @steady_factor || sample_rate != @steady_rate
                @steady_factor = v
                @steady_rate = sample_rate
                @steady_samples = (scale(Numo::SFloat.zeros(1), Numo::SFloat[v]) * sample_rate)[0]
              end
              key.set(f)
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
