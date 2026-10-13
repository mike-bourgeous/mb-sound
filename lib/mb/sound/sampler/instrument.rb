module MB
  module Sound
    module Sampler
      # Samples mapped to keys, velocities, and round robins (SFZ's
      # regions), played by GraphNode::SamplerVoice: each note-on plays the
      # first region whose keys, velocities, and round-robin slot match.
      # Also holds chop regions (slices addressed by Sampler.chop_note
      # numbers; see Sample::Slices#chop).
      #
      #     inst = Sampler::Instrument.new { |i|
      #       i.region soft, keys: C1..B3, vel: 0..63, root: C3
      #       i.region hard, keys: C1..B3, vel: 64..127, root: C3
      #       i.region snare1, keys: D2, seq: [1, 2]           # round robin 1 of 2
      #       i.region snare2, keys: D2, seq: [2, 2]
      #     }
      #     synth(midi) { |v| inst.play(v) * v.env(0.002, 0.2, 0.8, 0.3) }
      class Instrument
        # One region: a Sample with where and how it plays (see #region).
        Region = Struct.new(:sample, :keys, :vel, :seq, :rand, :root, :keytrack, :veltrack, :tune, :gain, :offset, keyword_init: true)

        # The keyboard regions (in match order) and the chop regions (Samples).
        attr_reader :regions, :chops

        # [attack, decay, sustain, release] for #play to multiply in (from
        # SFZ ampeg_*), or nil.
        attr_reader :envelope

        attr_reader :name, :lineage

        # Creates an instrument from +regions+ (Regions) and +chops+ (Samples),
        # then calls the block (if any) with the instrument to add regions
        # (#region) before it is frozen.
        def initialize(regions = [], chops: [], envelope: nil, name: nil, lineage: nil)
          @regions = regions.dup
          @chops = chops.dup
          @envelope = envelope&.map(&:to_f)&.freeze
          @name = name
          @lineage = lineage
          @building = true
          yield self if block_given?
          @building = false
          @regions.freeze
          @chops.freeze
          raise ArgumentError, 'An instrument needs at least one region or chop' if @regions.empty? && @chops.empty?
        end

        # Adds a region playing +sample+ (while building; see .new):
        # - keys: a Range of keys (Notes or numbers) or one key
        # - vel: a Range of MIDI velocities (0..127) or of 0..1 Floats
        # - seq: [position, count] sequential round robin (SFZ seq_position,
        #   seq_length; counted per key and voice)
        # - rand: a Range within 0...1 (SFZ lorand/hirand; one random draw
        #   per note-on, seeded per voice)
        # - root: the key playing the sample at its own pitch (the sample's
        #   #root by default)
        # - keytrack: semitones of pitch per key (1; 0 for drums and slices)
        # - veltrack: 0 (velocity doesn't change the level) to 1 (level
        #   (velocity)², SFZ's amp_veltrack 100)
        # - tune: semitones added; gain: linear gain; offset: a start
        #   position into the sample (see Sample#position)
        def region(sample, keys: 0..127, vel: 0..127, seq: nil, rand: nil, root: nil, keytrack: 1, veltrack: 0, tune: 0, gain: 1.0, offset: 0)
          raise FrozenError, 'Add regions while building the instrument (in its block)' unless @building
          sample = Sample[sample]
          keys = keys..keys unless keys.is_a?(Range)
          lo = keys.begin.nil? ? 0 : Sample.note_number(keys.begin).round
          hi = keys.end.nil? ? 127 : Sample.note_number(keys.end).round - (keys.exclude_end? ? 1 : 0)
          vel = vel..vel unless vel.is_a?(Range)
          vlo, vhi = [vel.begin || 0, vel.end || 127].map { |v| v.is_a?(Float) && v <= 1 ? (v * 127).round : Integer(v) }
          vhi -= 1 if vel.exclude_end? && vel.end
          if seq
            seq = Array(seq).map { |x| Integer(x) }
            raise ArgumentError, "seq: is [position, count] with 1 <= position <= count (got #{seq.inspect})" unless seq.length == 2 && seq[0] >= 1 && seq[0] <= seq[1]
          end
          if rand
            raise ArgumentError, "rand: is a Range within 0..1 (got #{rand.inspect})" unless rand.is_a?(Range)
            rand = [(rand.begin || 0).to_f, (rand.end || 1).to_f]
          end
          @regions << Region.new(
            sample: sample, keys: [lo.clamp(0, 127), hi.clamp(0, 127)], vel: [vlo.clamp(0, 127), vhi.clamp(0, 127)], seq: seq, rand: rand,
            root: root.nil? ? nil : Sample.note_number(root), keytrack: keytrack.to_f, veltrack: veltrack.to_f,
            tune: Interval.semitones(tune).to_f, gain: gain.to_f, offset: sample.position(offset).to_f
          ).freeze
          self
        end

        # Every Sample the instrument plays (regions and chops).
        def samples
          (@regions.map(&:sample) + @chops).uniq
        end

        # The most channels of any sample.
        def channel_count
          samples.map(&:channel_count).max
        end

        # True if every sample is a one-shot (voices stay busy until the
        # sample ends; see Sample::LOOP_MODES).
        def one_shot?
          samples.all?(&:one_shot?)
        end

        # True if any sample loops only while its note is held.
        def release_loop?
          samples.any? { |s| s.loop_mode == :release }
        end

        # [specs, regions DFloat] for the kernel for channel +c+ at
        # +sample_rate+ (see FastSampler.play), with level spacing +mips+ and
        # +interpolation+.
        def kernel_tables(c, sample_rate, mips: :default, interpolation: :optimal)
          tables = []
          index = {}.compare_by_identity
          spec_of = ->(s) {
            t = s.audio.table(c % s.channel_count, mips)
            index[t] ||= (tables << t.kernel_spec(sample_rate, interpolation)).length - 1
          }

          rows = @regions.map { |r|
            s = r.sample
            row(s, spec_of.(s), sample_rate, keys: r.keys, vel: r.vel, seq: r.seq, rand: r.rand, root: r.root || s.root, keytrack: r.keytrack,
                veltrack: r.veltrack, tune: r.tune, gain: r.gain, offset: r.offset)
          }
          rows += @chops.map { |s| row(s, spec_of.(s), sample_rate, keys: [-1, -1], vel: [0, 127], root: s.root, keytrack: 0.0) }
          [tables, Numo::DFloat.cast(rows)]
        end

        # A voice playing this instrument (GraphNode::SamplerVoice; a
        # Channels bundle of one per channel for stereo samples).  +source+
        # is a Notes (a synth's `v`), giving the trigger, note number,
        # frequency (bends and glides), and gate; or give +trigger+ and
        # +number+ (nodes or numbers) yourself.  A MIDI source that isn't a
        # Notes (a Clip, Stream, file) makes a synth (#sampler).
        #
        # Options: +transpose+ (semitones), +start+ (a 0..1 fraction of the
        # region, a number or node read at each note-on), +declick+ (samples
        # a re-struck note fades over; Sampler::DECLICK), +interpolation+
        # (:optimal; :none for the classic aliasing read), +mips+
        # (:default; false for no band-limited levels), +seed+ (round
        # robins), +freq+ (a node of Hz or a Pitch, instead of the Notes'
        # frequency), +gate+.
        #
        # With an #envelope (SFZ), the voice is multiplied by
        # `source.env(*envelope)`.
        def play(source = nil, trigger: nil, number: nil, freq: :auto, gate: :auto, start: nil, transpose: 0, declick: DECLICK,
                 interpolation: :optimal, mips: :default, seed: nil)
          if source && !source.is_a?(MB::Sound::Notes)
            raise ArgumentError, "Play a sampler from a synth voice (v), trigger:/number:, or a MIDI source (got #{source.inspect})" unless midi_source?(source)
            return sampler(source, transpose: transpose, start: start, declick: declick, interpolation: interpolation, mips: mips)
          end

          if source
            trigger ||= source.trigger
            number ||= source.number
            freq = @regions.empty? ? nil : source.freq if freq == :auto
            gate = release_loop? ? source.gate : nil if gate == :auto
          else
            raise ArgumentError, 'Give a synth voice (v) or trigger: and number:' unless trigger && number
            freq = nil if freq == :auto
            gate = nil if gate == :auto
          end
          freq = freq.oscillator_frequency if freq.is_a?(MB::Sound::Pitch)

          seed = seed.nil? ? MB::Sound.next_seed : Integer(seed)
          nodes = Array.new(channel_count) { |c|
            GraphNode::SamplerVoice.new(
              self, channel: c, trigger: trigger, number: number, freq: freq, gate: gate, start: start, transpose: transpose,
              declick: declick, interpolation: interpolation, mips: mips, seed: seed
            )
          }
          nodes.each { |n| source.register(n) } if source && one_shot?
          out = nodes.length == 1 ? nodes[0] : MB::Sound.channels(*nodes)
          out = out * source.env(*@envelope) if source && @envelope
          out
        end

        # A synth playing MIDI +source+ (a Clip, Stream, Notes, file) on
        # this instrument with +voices+ (1 by default: a new note cuts the
        # last, the classic chop); the block, if given, gets each voice's
        # Notes and sampler output and returns the voice (add an envelope,
        # a filter, ...).
        #
        #     amen.sampler(brk) { |v, s| s * v.env(0.0005, 0.01, 1, 0.006) }
        def sampler(source, voices: 1, **options, &block)
          inst = self
          MB::Sound.synth(source, voices: voices) { |v|
            s = inst.play(v, **options)
            block ? block.call(v, s) : s
          }
        end

        # A node playing the instrument's first region once from its start
        # at its own pitch (see Sample#node).
        def node(**options)
          GraphNode::SamplerVoice.new(self, channel: 0, once: true, seed: 0, **options).then { |n|
            next n if channel_count == 1
            MB::Sound.channels(n, *Array.new(channel_count - 1) { |c| GraphNode::SamplerVoice.new(self, channel: c + 1, once: true, seed: 0, **options) })
          }
        end

        def to_s
          "#{@name || 'Instrument'} (#{@regions.length} region#{'s' if @regions.length != 1}#{", #{@chops.length} chops" unless @chops.empty?})"
        end

        def inspect
          "#<#{self.class.name} #{self}>"
        end

        private

        def midi_source?(source)
          source.is_a?(Sequence::Clip) || source.is_a?(MIDI::Stream) || source.respond_to?(:to_midi_stream) || source.is_a?(String)
        end

        def row(s, table, sample_rate, keys:, vel:, root:, keytrack:, seq: nil, rand: nil, veltrack: 0.0, tune: 0.0, gain: 1.0, offset: 0.0)
          lp = s.loop_points || [0.0, 0.0]
          [
            table, keys[0], keys[1], vel[0], vel[1], seq ? seq[1] : 1, seq ? seq[0] : 1, rand ? rand[0] : 0.0, rand ? rand[1] : 1.0,
            root, keytrack, s.tune + tune, s.level * gain, s.start, s.stop, lp[0], lp[1], LOOP_MODES.fetch(s.loop_mode),
            s.reversed? ? 1 : 0, s.fade_in, s.fade_out, veltrack, s.sample_rate / sample_rate.to_f, offset,
          ]
        end
      end
    end
  end
end
