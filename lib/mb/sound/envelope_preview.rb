module MB
  module Sound
    class Envelope
      # What the inspector and the envelope preview read of an envelope
      # (envelope-view-1; design/notes/sound_design_ui.md, The envelope
      # preview): its settings as plain values (#param_info, #preview_data)
      # and where a sounding note is (#playhead_state), all read without
      # sampling, so a poll thread may call them.
      module Preview
        # The unit #param_info gives times.
        SECONDS_UNIT = 's'.freeze

        # The parameters by name (see GraphNode::Traversable#param_info):
        # every segment's time in seconds (:attack, :decay, :release, or
        # :t1, :t2, ...; a knob's value with its name, or the node), the
        # levels that aren't fixed (:sustain, or :t1_level, ...), then the
        # node inputs (gate, trigger, velocity, curve nodes, ...).  Times
        # given as numbers or lengths show as seconds, so the inspector can
        # list (and bind) them.
        def param_info
          tr = GraphNode::Traversable
          info = {}
          @names.each_with_index do |name, i|
            src = preview_time_source(name)
            info[name] =
              case src
              when Numeric, Length, Sequence::Duration
                tr::ParamValue.new(value: preview_seconds(src), type: :control, unit: SECONDS_UNIT, range: nil, label: nil, detail: nil)
              else
                tr.describe_param(src)
              end
            next if !multi? && i != @release_node - 1
            key = level_key(name)
            info[key] = tr.describe_param(@levels[name])
          end
          super.each { |k, v| info[k] = v unless info.key?(k) || @names.include?(k) }
          info.freeze
        end

        # Settings for the envelope preview (Plot::Panels::EnvelopeView): a
        # Hash of plain values (Floats, or nil where a node gives the value
        # and its current value isn't known).
        #
        # +:names+ the segment names, +:times+ seconds (Durations at the
        # current tempo; knobs at their values; the GM2-unscaled time of a
        # Notes envelope), +:levels+ relative to the peak, +:curves+ dB,
        # +:shapes+ (:exp or :s), +:release_node+, +:loop_node+, +:gated+
        # (a gate input: the sustain holds while the key is down), +:hold+
        # (seconds to the release without a gate, false for never),
        # +:velocity+ [low, high, :linear or :db], +:octaves+ (a cutoff
        # envelope's depth, or nil), +:hold_last+, +:multi+.
        def preview_data
          roles = self.class.curve_values(:analog, nil, names: @names, release_node: @release_node)
          {
            kind: :envelope,
            names: @names.dup,
            times: @names.map { |n| preview_number(preview_time_source(n), seconds: true) },
            levels: @names.map { |n| preview_number(@levels[n]) },
            curves: @names.map { |n| preview_number(@curves[n]) || roles[n].to_f },
            shapes: @names.map { |n| @shapes[n] },
            release_node: @release_node,
            loop_node: @loop_node,
            gated: !@gate.nil?,
            hold: @hold == false ? false : (one_shot? || @gate.nil? ? preview_number(@hold ? @hold.length : default_hold.length, seconds: true) : nil),
            velocity: [@velocity_low, @velocity_high, @velocity_scale],
            octaves: @octaves.is_a?(Numeric) ? @octaves : nil,
            hold_last: @hold_last,
            multi: multi?,
          }
        end

        # Where the envelope is now, for a playhead: [stage, segment, samples
        # into the segment, samples since the note started, peak level,
        # sample rate] (stage :segment, :sustain, :idle, :ended, :choke, or
        # :pending).  Read from the state the render thread writes (fused
        # or not: plans keep it in the node), without the render lock: a
        # display value, one buffer old at most.
        def playhead_state
          st = @state
          stage = case st[STATE_STAGE].to_i
                  when STAGE_SEGMENT then :segment
                  when STAGE_SUSTAIN then :sustain
                  when STAGE_ENDED then :ended
                  when STAGE_CHOKE then :choke
                  when STAGE_PENDING then :pending
                  else :idle
                  end
          [stage, st[STATE_SEGMENT].to_i, st[STATE_POSITION], st[STATE_NOTE_POSITION], st[STATE_PEAK], @sample_rate]
        end

        private

        # The time of segment +name+ as the patch gave it (NoteEnvelope:
        # before GM2 scaling).
        def preview_time_source(name)
          @times[name].length
        end

        # Seconds for a time as given (a number of seconds, a Length, a
        # Duration at the current tempo).
        def preview_seconds(t)
          return t.to_f if t.is_a?(Numeric) && !t.is_a?(Length)
          Length.seconds(t, sample_rate: @sample_rate).to_f
        rescue StandardError
          nil
        end

        # A number for value +v+ (a number, a length with +seconds+, or a
        # knob or constant at its current value), or nil for other nodes.
        def preview_number(v, seconds: false)
          return preview_seconds(v) if seconds && (v.is_a?(Length) || v.is_a?(Sequence::Duration))
          return v.to_f if v.is_a?(Numeric)
          return nil if v.nil? || v == false
          d = GraphNode::Traversable.describe_param(v)
          d.value.is_a?(Numeric) ? d.value.to_f : nil
        end
      end

      include Preview

      # A gate that is 1 for the first +on+ samples, then 0: the one note
      # of the envelope preview's copy (Plot::Panels::EnvelopeView).
      class PreviewGate
        include GraphNode
        node_traits memory: :short, fresh: 'the sound screen\'s envelope preview, rebuilt with its preview'

        def initialize(on, sample_rate)
          @on = on
          @pos = 0
          @sample_rate = sample_rate.to_f
        end

        attr_reader :sample_rate

        def sources = {}

        def sample(count)
          buf = Numo::SFloat.zeros(count)
          n = (@on - @pos).clamp(0, count)
          buf[0...n] = 1 if n > 0
          @pos += count
          buf
        end
      end
    end
  end
end
