module MB
  module Sound
    module Sampler
      # Samples mapped to keys, velocities, and round robins (SFZ's
      # regions), played by GraphNode::SamplerVoice: each note-on plays the
      # first region whose keys, velocities, and round-robin slot match,
      # pitched by its note's pitch mark too (Seq::Step#pitch: chop hits).
      # With a +split+ key, notes from it up play the region last played
      # below it, chromatically from the split key (a split keyboard:
      # slices on the low keys, the last slice played as an instrument
      # above; see Sample::Slices#keymap).
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
        Region = Struct.new(:sample, :keys, :vel, :seq, :rand, :root, :keytrack, :veltrack, :tune, :gain, :offset, :pan, keyword_init: true)

        # The regions, in match order.
        attr_reader :regions

        # The split key (a note number) or nil (see the class description).
        attr_reader :split

        # The level spacing voices read the samples' tables with by default
        # (Wavetable mips: :default, :octave, ...; sfz instruments :octave).
        attr_reader :mips

        # The envelope #play multiplies in: [attack, decay, sustain,
        # release] (from SFZ ampeg_*), a Hash of Notes#env options (SF2
        # volume envelopes: segments:, release_at:, sensitivity:), or nil.
        attr_reader :envelope

        # A lowpass #play applies after the envelope ({ cutoff: Hz,
        # quality: }; SF2 initialFilterFc/Q), or nil.
        attr_reader :filter

        # The Instruments layered (each note plays a region of every layer;
        # see .layered), or nil.
        attr_reader :layers

        # Per-voice modulation for SoundFont-style instruments, or nil: a
        # Hash of +sources:+ ({ name => { env: Notes#env options } (0..1) or
        # { lfo: Hz, delay: s, depth: d, wheel: w, pressure: p } (a key-synced
        # triangle, -d..d, plus mod wheel × w and aftertouch × p) }), and
        # destinations +pitch:+ and +cutoff:+ ([[source name, cents per unit
        # of the source], ...]) and +volume:+ ([[source name, centibels of
        # attenuation per unit]]).  Any value may be a ZoneMap.  Cutoff
        # modulation needs a #filter.
        attr_reader :modulation

        attr_reader :name, :lineage

        # Creates an instrument from +regions+ (Regions), then calls the
        # block (if any) with the instrument to add regions (#region) before
        # it is frozen.  +split+: a key (Note or number) for a split
        # keyboard, or nil; +mips+: the voices' default table level spacing.
        def initialize(regions = [], split: nil, mips: :default, envelope: nil, filter: nil, modulation: nil, name: nil, lineage: nil, layers: nil)
          @layers = layers&.dup&.freeze
          raise ArgumentError, 'Layers are Sampler::Instruments' if @layers && !@layers.all?(Instrument)
          regions = @layers.flat_map(&:regions) if @layers
          @regions = regions.dup
          @split = split.nil? ? nil : Sample.note_number(split).round
          raise ArgumentError, "The split key must be 0 to 127 (got #{@split})" if @split && !@split.between?(0, 127)
          @mips = mips
          @envelope = case envelope
                      when nil then nil
                      when Hash then envelope.dup.freeze
                      else envelope.map(&:to_f).freeze
                      end
          @filter = filter.nil? ? nil : { cutoff: setting(filter[:cutoff]), quality: setting(filter[:quality] || 0.7071067811865476) }.freeze
          @modulation = modulation.nil? ? nil : deep_freeze(modulation)
          @coverage = nil
          if @modulation
            unknown = @modulation.keys - %i[sources pitch cutoff volume]
            raise ArgumentError, "Unknown modulation keys #{unknown.inspect} (sources, pitch, cutoff, volume)" unless unknown.empty?
            missing = %i[pitch cutoff volume].flat_map { |d| Array(@modulation[d]).map(&:first) } - (@modulation[:sources] || {}).keys
            raise ArgumentError, "Modulation names unknown sources #{missing.uniq.inspect}" unless missing.empty?
          end
          @name = name
          @lineage = lineage
          @building = true
          yield self if block_given?
          @building = false
          @regions.freeze
          raise ArgumentError, 'An instrument needs at least one region' if @regions.empty?
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
        # - pan: -1 (left) to 1 (right), equal power with 0 dB in the
        #   middle for mono samples, a balance for stereo ones; any pan
        #   makes the instrument stereo
        def region(sample, keys: 0..127, vel: 0..127, seq: nil, rand: nil, root: nil, keytrack: 1, veltrack: 0, tune: 0, gain: 1.0, offset: 0, pan: 0)
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
            tune: Interval.semitones(tune).to_f, gain: gain.to_f, offset: sample.position(offset).to_f, pan: Float(pan).clamp(-1.0, 1.0)
          ).freeze
          self
        end

        # Every Sample the instrument plays.
        def samples
          @regions.map(&:sample).uniq
        end

        # The most channels of any sample (2 if any region is panned).
        def channel_count
          n = samples.map(&:channel_count).max
          n < 2 && @regions.any? { |r| r.pan.to_f != 0 } ? 2 : n
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
        # +interpolation+ for every region, or (nil) each sample's own
        # (Sample#read_as: the lofi presets read drop-sample with no levels),
        # else #mips and :optimal.
        def kernel_tables(c, sample_rate, mips: nil, interpolation: nil)
          raise ArgumentError, 'A layered instrument plays through its layers (see #play)' if @layers
          stereo = channel_count == 2
          tables = []
          index = {}
          spec_of = ->(s, m, interp) {
            t = s.audio.table(c % s.channel_count, m)
            index[[t.object_id, interp]] ||= (tables << t.kernel_spec(sample_rate, interp)).length - 1
          }

          rows = @regions.map { |r|
            s = r.sample
            interp = (interpolation || s.interpolation || :optimal).to_sym
            code = Wavetable::INTERPOLATIONS.fetch(interp) { raise ArgumentError, "Unknown interpolation #{interp.inspect}" }
            m = mips.nil? ? (s.mips.nil? ? @mips : s.mips) : mips
            row(s, spec_of.(s, m, interp), sample_rate, keys: r.keys, vel: r.vel, seq: r.seq, rand: r.rand, root: r.root || s.root, keytrack: r.keytrack,
                veltrack: r.veltrack, tune: r.tune, gain: r.gain * (stereo ? Instrument.pan_gain(r.pan.to_f, c, s.channel_count) : 1.0), offset: r.offset, interp: code)
          }
          [tables, Numo::DFloat.cast(rows)]
        end

        # A voice playing this instrument (GraphNode::SamplerVoice; a
        # Channels bundle of one per channel for stereo samples).  +source+
        # is a Notes (a synth's `v`), giving the trigger, note number,
        # frequency (bends and glides), gate, and pitch marks; or give
        # +trigger+ and +number+ (nodes or numbers) yourself.  A MIDI source that isn't a
        # Notes (a Clip, Stream, file) makes a synth (#sampler).
        #
        # Options: +transpose+ (semitones), +start+ (a 0..1 fraction of the
        # region, a number or node read at each note-on), +declick+ (samples
        # a re-struck note fades over; Sampler::DECLICK), +interpolation+
        # (:optimal; :none for the classic aliasing read), +mips+
        # (#mips by default; false for no band-limited levels), each nil
        # for each sample's own read (Sample#read_as; the lofi presets read
        # drop-sample with no levels, else :optimal and #mips), +seed+
        # (round robins), +freq+ (a node of Hz or a Pitch, instead of the
        # Notes' frequency), +gate+, +shift+ (semitones read at each
        # note-on, instead of the Notes' #pitch_mark).
        #
        # With an #envelope (SFZ, SF2), the voice is multiplied by
        # `source.env(*envelope)` (or `source.env(**envelope)`), then
        # lowpassed by the #filter, if any.  A layered instrument (.layered)
        # sums its layers' voices (the same seed for each).
        def play(source = nil, trigger: nil, number: nil, freq: :auto, gate: :auto, shift: :auto, start: nil, transpose: 0, declick: DECLICK,
                 interpolation: nil, mips: nil, seed: nil)
          if source && !source.is_a?(MB::Sound::Notes)
            raise ArgumentError, "Play a sampler from a synth voice (v), trigger:/number:, or a MIDI source (got #{source.inspect})" unless midi_source?(source)
            return sampler(source, transpose: transpose, start: start, declick: declick, interpolation: interpolation, mips: mips)
          end

          if source
            trigger ||= source.trigger
            number ||= source.number
            freq = source.freq if freq == :auto
            gate = release_loop? ? source.gate : nil if gate == :auto
            shift = source.pitch_mark if shift == :auto
          else
            raise ArgumentError, 'Give a synth voice (v) or trigger: and number:' unless trigger && number
            freq = nil if freq == :auto
            gate = nil if gate == :auto
            shift = nil if shift == :auto
          end
          freq = freq.oscillator_frequency if freq.is_a?(MB::Sound::Pitch)

          seed = seed.nil? ? MB::Sound.next_seed : Integer(seed)
          voice(source, trigger: trigger, number: number, freq: freq, gate: gate, shift: shift, start: start, transpose: transpose, declick: declick,
                        interpolation: interpolation, mips: mips, seed: seed, shared: {})
        end

        # The voice for #play's resolved inputs; +shared+ keeps modulation
        # nodes that layers with the same settings share (one vibrato LFO
        # per note, not one per layer).
        #
        # A +layer+'s envelopes (the volume and modulation envelopes) ignore
        # notes its regions don't cover (gate and trigger masked by a
        # coverage ZoneValue), so an uncovered note-on doesn't attack again
        # over the last note's declick tail.
        def voice(source, trigger:, number:, freq:, gate:, shift:, start:, transpose:, declick:, interpolation:, mips:, seed:, shared:, layer: false)
          if @layers
            n = channel_count
            outs = @layers.map { |l|
              o = l.send(:voice, source, trigger: trigger, number: number, freq: freq, gate: gate, shift: shift, start: start, transpose: transpose,
                                         declick: declick, interpolation: interpolation, mips: mips, seed: seed, shared: shared, layer: true)
              o.is_a?(GraphNode::Channels) ? o.to_a : [o]
            }
            sums = Array.new(n) { |c| outs.map { |o| o[c % o.length] }.reduce(:+) }
            return n == 1 ? sums[0] : MB::Sound.channels(*sums)
          end

          mask = layer && source ? per_note(coverage, source, shared) : nil
          mods = @modulation && source ? modulators(source, shared, mask) : nil
          if mods && mods[:pitch]
            freq = shared[[:pitch, freq, mods[:keys][:pitch]]] ||= shift_by((freq || source.freq).then { |f| f.respond_to?(:sample) ? f : f.constant }, mods, :pitch)
          end

          nodes = Array.new(channel_count) { |c|
            GraphNode::SamplerVoice.new(
              self, channel: c, trigger: trigger, number: number, freq: freq, gate: gate, shift: shift, start: start, transpose: transpose,
              declick: declick, interpolation: interpolation, mips: mips, seed: seed
            )
          }
          nodes.each { |n| source.register(n) } if source && one_shot?
          out = nodes.length == 1 ? nodes[0] : MB::Sound.channels(*nodes)
          if source && @envelope
            opts = mask ? { mask: mask } : {}
            out = out * (@envelope.is_a?(Hash) ? source.env(**per_note(@envelope, source, shared), **opts) : source.env(*@envelope, **opts))
          end
          if @filter
            f = per_note(@filter, source || { number: number, velocity: 1.constant }, shared) # (ZoneMaps read velocity 127 without Notes)
            cutoff = f[:cutoff]
            cutoff = shift_by(cutoff.respond_to?(:sample) ? cutoff : cutoff.constant, mods, :cutoff).aclip(5, 20000) if mods && mods[:cutoff]
            out = out.filter(:lowpass, cutoff: cutoff, quality: f[:quality])
          end
          out = out * (10.constant ** (mods[:volume] * (-1 / 200.0))) if mods && mods[:volume]
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
          return @layers[0].node(**options) if @layers

          GraphNode::SamplerVoice.new(self, channel: 0, once: true, seed: 0, **options).then { |n|
            next n if channel_count == 1
            MB::Sound.channels(n, *Array.new(channel_count - 1) { |c| GraphNode::SamplerVoice.new(self, channel: c + 1, once: true, seed: 0, **options) })
          }
        end

        # This instrument with lineage +lineage+ (how it prints; see
        # GraphNode::Recipe::RubyWriter).
        def with_lineage(lineage)
          return Instrument.new(layers: @layers, mips: @mips, name: @name, lineage: lineage) if @layers
          Instrument.new(@regions, split: @split, mips: @mips, envelope: @envelope, filter: @filter, modulation: @modulation, name: @name, lineage: lineage)
        end

        # An instrument playing +instruments+ together: each note plays the
        # matching region of every layer (SF2 zones that overlap; a layer's
        # own envelope and filter apply to its voice).  Each layer costs a
        # sampler voice per note.
        def self.layered(*instruments, name: nil, mips: :default, lineage: nil)
          instruments = instruments.flatten
          return instruments[0].with_lineage(lineage) if instruments.length == 1 && lineage
          new(layers: instruments, mips: mips, name: name, lineage: lineage)
        end

        # The gain of channel +c+ (of 2) for a region panned to +pan+ (-1..1)
        # playing a sample of +sample_channels+: equal power with 0 dB in the
        # middle for mono samples (+3 dB at the side it's panned to), a
        # balance (the far channel turned down) for stereo samples.
        def self.pan_gain(pan, c, sample_channels)
          return 1.0 if pan == 0
          if sample_channels == 1
            angle = (pan + 1) * Math::PI / 4
            Math.sqrt(2) * (c == 0 ? Math.cos(angle) : Math.sin(angle))
          else
            c == 0 ? 1.0 - [pan, 0.0].max : 1.0 + [pan, 0.0].min
          end
        end

        def to_s
          "#{@name || 'Instrument'} (#{@regions.length} region#{'s' if @regions.length != 1}#{", #{@layers.length} layers" if @layers}#{", split at #{Sample.note_name(@split)}" if @split})"
        end

        def inspect
          "#<#{self.class.name} #{self}>"
        end

        private

        # The modulation sums for the notes of +source+: { pitch:, cutoff:,
        # volume: } nodes (cents, cents, centibels) for the destinations
        # #modulation names (see #modulation).
        # Sums and sources are made once per +shared+ Hash for the same
        # settings (ZoneMaps compare by their zones), so layers share them;
        # +keys+ holds each sum's settings for the caller's own sharing.
        def modulators(source, shared = {}, mask = nil)
          raw = @modulation
          node = ->(name) {
            spec = raw[:sources].fetch(name)
            # (masked envelopes belong to their layer)
            shared[[:source, spec, spec[:env] && mask ? object_id : nil]] ||= begin
              s = per_note(spec, source, shared)
              if s[:env]
                source.env(**{ sensitivity: nil, gm: false }.merge(s[:env]), **(mask ? { mask: mask } : {}))
              else
                source.lfo(s[:lfo], depth: s[:depth] || 1.0, delay: s[:delay] || 0, wheel: s[:wheel], pressure: s[:pressure])
              end
            end
          }
          keys = {}
          out = %i[pitch cutoff volume].each_with_object({}) { |dest, h|
            list = Array(raw[dest]).reject { |_, amount| amount == 0 }
            next if list.empty?
            key = list.map { |name, amount| [raw[:sources][name], amount] }
            keys[dest] = key
            key += [object_id] if mask && list.any? { |name, _| raw[:sources][name][:env] }
            h[dest] = shared[[:sum, dest, key]] ||= list.map { |name, amount|
              a = per_note(amount, source, shared)
              a == 1 ? node.(name) : node.(name) * a
            }.reduce(:+)
          }
          out.merge(keys: keys)
        end

        # +hz+ (a node) shifted by +mods+[+dest+] cents: hz × 2^(cents /
        # 1200), with a Constant base so the plan layer fuses it (its
        # vectorized 2^x; a SemitoneShift was a plan boundary in Ruby).
        def shift_by(hz, mods, dest)
          hz * (2.constant ** (mods[dest] * (1 / 1200.0)))
        end

        def deep_freeze(v)
          case v
          when Hash then v.transform_values { |x| deep_freeze(x) }.freeze
          when Array then v.map { |x| deep_freeze(x) }.freeze
          else v
          end
        end

        # A ZoneMap of 1 where a region plays and 0 elsewhere (see #voice).
        def coverage
          @coverage ||= ZoneMap.new(@regions.map { |r| [r.keys, r.vel, 1.0] }, default: 0.0)
        end

        # A number, or a ZoneMap (a per-note value; see #per_note).
        def setting(v)
          v.is_a?(ZoneMap) ? v : Float(v)
        end

        # +value+ with every ZoneMap in it (Hashes and Arrays are searched)
        # made a GraphNode::ZoneValue for the notes of +source+ (a Notes, or
        # a Hash of number: and velocity: nodes).
        def per_note(value, source, shared)
          case value
          when ZoneMap
            # one index (number and velocity read once per buffer) for every
            # zone value of the voice, across layers
            index = shared[:zone_index] ||= source.is_a?(Hash) ? GraphNode::ZoneValue::Index.new(source[:number], source[:velocity]) :
                                                                   GraphNode::ZoneValue::Index.new(source.number, source.velocity)
            value.node(index: index)
          when Hash then value.transform_values { |v| per_note(v, source, shared) }
          when Array then value.map { |v| per_note(v, source, shared) }
          else value
          end
        end

        def midi_source?(source)
          source.is_a?(Sequence::Clip) || source.is_a?(MIDI::Stream) || source.respond_to?(:to_midi_stream) || source.is_a?(String)
        end

        def row(s, table, sample_rate, keys:, vel:, root:, keytrack:, seq: nil, rand: nil, veltrack: 0.0, tune: 0.0, gain: 1.0, offset: 0.0, interp: -1)
          lp = s.loop_points || [0.0, 0.0]
          [
            table, keys[0], keys[1], vel[0], vel[1], seq ? seq[1] : 1, seq ? seq[0] : 1, rand ? rand[0] : 0.0, rand ? rand[1] : 1.0,
            root, keytrack, s.tune + tune, s.level * gain, s.start, s.stop, lp[0], lp[1], LOOP_MODES.fetch(s.loop_mode),
            s.reversed? ? 1 : 0, s.fade_in, s.fade_out, veltrack, s.sample_rate / sample_rate.to_f, offset, interp,
          ]
        end
      end
    end
  end
end
