module MB
  module Sound
    module Drums
      # A drum machine design: named voices, each a block building its
      # sound from a Drums::Hit (layers played by the voice's trigger), with
      # knobs, General MIDI notes, aliases, and choke groups.  #kit plays it
      # from a grid, clip, or any MIDI source, as a Drums::Kit (or separate
      # outputs).  Made by DrumMethods#kit (`kit { voice ... }`) or
      # Drums.machine; TR909 is one.
      #
      #     zap = kit do
      #       voice :kick, tune: 48, decay: 0.6 do |h|
      #         h.body(h.tune, decay: h.decay, sweep: 3) + h.click(0.3)
      #       end
      #       voice :snare, tune: 190, snappy: 0.6 do |h|
      #         h.body(h.tune, decay: 0.12) * 0.5 + h.noise(decay: 0.18, highpass: 1500) * h.snappy
      #       end
      #       voice :hat, decay: 0.05, gm: [42, 44] do |h|
      #         h.metal.filter(:highpass, cutoff: 7000) * h.env(h.decay) * 3
      #       end
      #       voice :open_hat, decay: 0.4 do |h|
      #         h.metal.filter(:highpass, cutoff: 7000) * h.env(h.decay) * 2
      #       end
      #       choke :open_hat, by: :hat
      #     end
      #     bg :beat, zap.kit(grid(16, kick: 'X...x...', snare: '....X...', hat: 'x.x.x.x.', oh: '..x...x.').loop)
      #
      # Every voice also has a +level+ knob (1 unless its defaults say
      # otherwise), applied after its block, and takes +accent:+,
      # +velocity_curve:+, and +flam:+ in its knob Hash (see #kit).
      class Machine
        # One voice of a design.
        VoiceSpec = Struct.new(:name, :defaults, :block, :gm, :aliases, keyword_init: true)

        # Knobs every voice takes besides its own (see #kit).
        COMMON_KNOBS = [:accent, :velocity_curve, :flam].freeze

        # Kit output modes (see #kit).
        OUTPUTS = [:mix, :separate, :individual].freeze

        # How loud the first stroke of a flam is, relative to the second.
        FLAM_GRACE = 0.6

        # The default flam spacing (seconds).
        DEFAULT_FLAM = 0.018

        # The machine's name (e.g. :tr909, or :kit).
        attr_reader :name

        # The voices (VoiceSpecs by name, in definition order).
        attr_reader :voices

        # Chokes: the voices whose hits cut each voice off, by voice name.
        attr_reader :chokes

        # Creates a design named +name+; the block defines voices and chokes
        # (see Builder).  A block without parameters runs on the Builder.
        def initialize(name = :kit, &block)
          @name = name.to_sym
          @voices = {}
          @chokes = Hash.new { |h, k| h[k] = [] }
          @aliases = {}
          if block
            b = Builder.new(self)
            block.arity == 0 ? b.instance_exec(&block) : block.call(b)
          end
          raise ArgumentError, "A #{@name} needs at least one voice" if @voices.empty?
          @chokes.default_proc = nil
          @chokes.each_value(&:freeze)
          @chokes.freeze
          @voices.freeze
          @aliases.freeze
        end

        # Adds a voice (see Builder#voice).
        def add_voice(name, defaults, block, gm: nil, aliases: [])
          name = name.to_sym
          raise ArgumentError, "The #{@name} already has a #{name.inspect} voice" if @voices.key?(name)
          bad = defaults.keys & Hit::METHODS
          raise ArgumentError, "Knob #{bad.first.inspect} of the #{name} has the name of a Hit method; pick another" unless bad.empty?
          bad = defaults.keys & COMMON_KNOBS
          raise ArgumentError, "#{bad.first.inspect} is set per kit or per voice when playing, not as a knob default" unless bad.empty?
          raise ArgumentError, "The #{name} needs a block that builds its sound" unless block

          gm = gm.nil? ? default_gm(name) : Array(gm).map { |n| Sequence::Grid.row_value(n) }
          defaults = { level: 1.0 }.merge(defaults)
          @voices[name] = VoiceSpec.new(name: name, defaults: defaults.freeze, block: block, gm: gm.freeze, aliases: Array(aliases).map(&:to_sym).freeze)
          Array(aliases).each { |a| @aliases[a.to_sym] = name }
          self
        end

        # Makes every voice of +names+ cut off the others (or with +by+,
        # makes +by+'s hits cut off +names+).
        def add_choke(names, by: nil)
          names = names.map { |n| key!(n) }
          if by
            Array(by).map { |n| key!(n) }.each { |b| names.each { |n| @chokes[n] |= [b] unless n == b } }
          else
            raise ArgumentError, 'A choke group needs two or more voices (or by:)' if names.length < 2
            names.each { |n| @chokes[n] |= names - [n] }
          end
          self
        end

        # Copies voices +names+ (all if empty) of +other+ (a Machine) with
        # their chokes among the copied voices; +knobs+ changes defaults by
        # voice name (see Builder#tr909).
        def add_from(other, names, knobs = {})
          keys = names.empty? ? other.names : names.map { |n|
            other.voice_name(n) || raise(ArgumentError, "Unknown #{other.name} voice #{n.inspect} (voices: #{other.names.map(&:inspect).join(', ')})")
          }.uniq
          knobs = knobs.to_h { |n, k|
            key = other.voice_name(n)
            raise ArgumentError, "No #{n.inspect} among the #{other.name} voices added (#{keys.join(', ')})" unless keys.include?(key)
            raise ArgumentError, "Knobs for the #{key} must be a Hash (got #{k.inspect})" unless k.is_a?(Hash)
            [key, k]
          }
          keys.each do |k|
            spec = other.voices.fetch(k)
            changed = knobs.fetch(k, {})
            Drums.knobs(k, spec.defaults, changed)
            add_voice(k, spec.defaults.merge(changed), spec.block, gm: spec.gm, aliases: spec.aliases.reject { |a| @aliases.key?(a) || @voices.key?(a) })
          end
          keys.each do |k|
            (other.chokes[k] || []).each { |by| add_choke([k], by: by) if keys.include?(by) }
          end
          keys
        end

        # A grid (see MB::Sound#grid) whose rows may also name this
        # machine's own voices and aliases (`zap: 'x...'`), not only GM
        # drums: rows play the voice they name in #kit.
        #
        #     m = kit { voice(:zap) { |h| h.fm(800, index: 3, decay: 0.1) } }
        #     bg :zaps, m.kit(m.grid(16, zap: 'x..x..x.').loop)
        def grid(division, map: {}, **rows)
          map = rows.keys.to_h { |r|
            next [r, map[r]] if map.key?(r)
            v = voice_name(r)
            [r, v ? (gm_notes(v).first || 0) : nil]
          }.compact
          MB::Sound.grid(division, map: map, **rows)
        end

        # The voice names.
        def names
          @voices.keys
        end

        # The voice name for +name+ (a voice, an alias, or a GM drum name or
        # note number playing one of the voices), or nil.
        def voice_name(name)
          case name
          when Symbol
            return name if @voices.key?(name)
            return @aliases[name] if @aliases.key?(name)
            gm = Sequence::Grid::GM_DRUMS[name] || Sequence::Grid::ROW_ALIASES[name]
            gm && gm_voice(gm)
          when Numeric
            gm_voice(name)
          end
        end

        # A Drums::Kit of this machine's voices played by +source+:
        # - a grid Kit (`grid(16, kick: 'x...', snare: '....x...')`): each
        #   row plays the voice it names (a voice, an alias, or a GM drum
        #   name), each row keeping its own loop;
        # - anything else MIDI (a Clip or Seq, a Notes such as `midi`, a
        #   MIDI file or Stream): notes go to voices by their +gm:+ notes
        #   (+map:+ adds or replaces voice => notes entries); every voice
        #   with notes unless +only:+ lists some (for a clip, only the voices
        #   its notes play).
        #
        # Knobs per voice as Hashes (`kick: { tune: 45 }`; aliases work;
        # numbers, Lengths, or nodes), each voice's own knobs plus +level+,
        # +accent+, +velocity_curve+, and +flam+.  For the whole kit:
        # - +accent:+ dB louder for a grid X than an x (or MIDI 127 than 64;
        #   see Drums.accented), +velocity_curve:+ :grid or :midi (by
        #   default from the source);
        # - +shuffle:+ swing for grid and clip sources: 0..6 like a TR-909
        #   (each step delays every second 16th by 1/48 of a beat; 4 is
        #   about a triplet feel) or a Float swing amount (see Clip#swing);
        # - +flams:+ a second source (grid, clip, ...) whose hits play as
        #   flams: a grace stroke (FLAM_GRACE of the velocity) then the hit
        #   +flam:+ later (seconds or a Length; DEFAULT_FLAM, 18 ms);
        # - +outputs:+ :mix (a Kit) or :separate (alias :individual: a
        #   Channels bundle of the voices, named, in definition order,
        #   adding up to the mix exactly);
        # - +seed:+ the random seed (voice i, in definition order, is built
        #   in MB::Sound.with_seed(seed + 1 + i));
        # - +skip_idle:+ as for Voice.
        def kit(source, accent: DEFAULT_ACCENT, velocity_curve: nil, only: nil, map: {}, skip_idle: true, outputs: :mix, seed: nil,
                shuffle: nil, flam: DEFAULT_FLAM, flams: nil, **settings)
          unless OUTPUTS.include?(outputs)
            raise ArgumentError, "Unknown outputs: #{outputs.inspect} (outputs: #{OUTPUTS.map(&:inspect).join(', ')})"
          end

          settings = settings.to_h { |name, k|
            raise ArgumentError, "Knobs for the #{name} must be a Hash (got #{k.inspect})" unless k.is_a?(Hash)
            [key!(name), k]
          }

          source = Machine.shuffled(source, shuffle) if shuffle
          flams = Machine.shuffled(flams, shuffle) if flams && shuffle
          sources = voice_sources(source, only: only, map: map)
          flam_sources = flams ? voice_sources(flams, only: only, map: map) : {}
          if sources.empty? && flam_sources.empty?
            raise ArgumentError, "Nothing in #{source} plays a #{@name} voice (voices: #{names.join(', ')})"
          end

          all_sources = [source, flams].compact
          seed = seed.nil? ? MB::Sound.next_seed : Integer(seed)
          voices = {}
          @voices.each_value.with_index do |spec, idx|
            next unless sources.key?(spec.name) || flam_sources.key?(spec.name)

            knobs = settings.fetch(spec.name, {})
            chokers = (@chokes[spec.name] || []).flat_map { |c| [sources[c], flam_sources[c]].compact.flatten }
            voices[spec.name] = MB::Sound.with_seed(seed + 1 + idx) {
              build_voice(
                spec, sources[spec.name], flam_sources[spec.name], chokers,
                accent: accent, velocity_curve: velocity_curve || Drums.velocity_curve(all_sources), flam: flam,
                skip_idle: skip_idle, **knobs
              )
            }
          end

          if outputs == :mix
            clip_notes = source.is_a?(Sequence::Clip) && !source.performed? && flams.nil? ? voices.keys.flat_map { |v| gm_notes(v, map) } : nil
            Kit.new(voices, machine: @name, clip_notes: clip_notes, velocity_curve: velocity_curve.nil? && !source.is_a?(Sequence::Kit) ? Drums.velocity_curve(source) : nil)
          else
            GraphNode::Channels.new(voices.values, names: voices.keys).named("#{@name} outputs")
          end
        end
        alias call kit

        # Builds one Drums::Voice for +spec+ played by +source+ (one or an
        # Array of sources; nil if only flams play it), with +flams+ (the
        # flam source or nil) and +chokers+ (sources whose hits choke it).
        def build_voice(spec, source, flams, chokers, accent:, velocity_curve:, flam:, skip_idle: true, **knobs)
          own = knobs.slice(*COMMON_KNOBS)
          k = Drums.knobs(spec.name, spec.defaults, knobs.except(*COMMON_KNOBS))
          accent = own.fetch(:accent, accent)
          velocity_curve = own.fetch(:velocity_curve, velocity_curve)
          flam = own.fetch(:flam, flam)

          notes = []
          triggers = ->(src) {
            (src.is_a?(Array) ? src : [src]).map { |s|
              n = Drums.notes_for(s)
              notes << n if n
              n ? n.trigger : s
            }
          }

          parts = source ? triggers.(source) : []
          if flams
            spacing = MB::Sound::Length.seconds(flam)
            parts += triggers.(flams).map { |t| Repeats.new(t, [[0, FLAM_GRACE], [spacing, 1.0]]) }
          end

          tap = Voice::Tap.new('trigger')
          inputs = [[Drums.mix(parts), tap]]
          trigger = Drums.accented(tap, accent, curve: velocity_curve)

          choke_tap = nil
          unless chokers.empty?
            choke_tap = Voice::Tap.new('choke')
            inputs << [Drums.mix(triggers.(chokers.map { |c| own_notes(c) })), choke_tap]
          end

          hit = Hit.new(trigger, knobs: k, name: spec.name, machine: @name)
          b = spec.block
          graph = b.arity == 0 ? hit.instance_exec(&b) : b.call(hit)
          graph = Drums.mix(graph.flatten) if graph.is_a?(Array)
          unless graph.respond_to?(:sample)
            raise ArgumentError, "The #{spec.name} block returned #{graph.inspect}, not a graph node"
          end
          level = k[:level]
          graph = graph * level unless level.is_a?(Numeric) && level == 1
          graph = graph * ChokeGate.new(tap, choke_tap) if choke_tap
          graph = graph.named("#{@name} #{spec.name}")

          Voice.new(
            graph, name: spec.name, machine: @name, inputs: inputs, notes: notes,
            knobs: k.merge(accent: accent, velocity_curve: velocity_curve), skip_idle: skip_idle
          )
        end

        # The notes that play voice +v+ with +map+ (see #kit).
        def gm_notes(v, map = {})
          map.each { |k, notes| return Array(notes).map { |n| Sequence::Grid.row_value(n) } if voice_name(k) == v }
          @voices.fetch(v).gm
        end

        # Sources by voice name for #kit (see there).
        def voice_sources(source, only:, map:)
          only = only && Array(only).map { |v| key!(v) }

          if source.is_a?(Sequence::Kit)
            groups = Hash.new { |h, k| h[k] = [] }
            source.each do |row, clip|
              key = voice_name(row) || voice_name(clip.events.first&.value)
              raise ArgumentError, "Grid row #{row.inspect} doesn't name a #{@name} voice (voices: #{names.join(', ')})" unless key
              groups[key] << clip if only.nil? || only.include?(key)
            end
            groups.default_proc = nil
            return groups
          end

          gm = names.to_h { |v| [v, @voices[v].gm] }
          map.each { |v, notes| gm[key!(v)] = Array(notes).map { |n| Sequence::Grid.row_value(n) } }
          voices = (only || gm.keys).reject { |v| gm[v].empty? }
          if source.is_a?(Sequence::Clip) && !source.performed?
            values = source.events.map(&:value)
            voices = voices.select { |v| gm.fetch(v).any? { |n| values.include?(n) } }
          end
          stream = MB::Sound::MIDI::Stream.for(source)
          voices.to_h { |v| [v, MB::Sound::Notes.new(stream.keys(*gm.fetch(v)), sustain: false)] }
        end

        def to_s
          "#{@name} (#{names.join(', ')})"
        end

        def inspect
          "#<#{self.class.name} #{to_s}>"
        end

        # +source+ (a grid Kit or Clip) with +shuffle+ (see #kit).
        def self.shuffled(source, shuffle)
          amount = shuffle.is_a?(Integer) ? Rational(24 + 2 * shuffle, 48) : shuffle
          return source if amount == 0.5 || shuffle == 0
          unless shuffle.is_a?(Numeric) && amount > 0 && amount < 1 && (!shuffle.is_a?(Integer) || (0..12).cover?(shuffle))
            raise ArgumentError, "Shuffle is 0..6 (TR-909 steps) or a swing amount between 0 and 1 (got #{shuffle.inspect})"
          end

          case source
          when Sequence::Kit
            Sequence::Kit.new(source.rows.transform_values { |c| c.swing(amount, 16) })
          when Sequence::Clip
            source.swing(amount, 16)
          else
            raise ArgumentError, "Shuffle works on grids and clips (got #{source.class})"
          end
        end

        private

        def key!(name)
          voice_name(name) || raise(ArgumentError, "Unknown #{@name} voice #{name.inspect} (voices: #{names.map(&:inspect).join(', ')})")
        end

        def gm_voice(note)
          @voices.each_value { |s| return s.name if s.gm.include?(note) }
          nil
        end

        def default_gm(name)
          n = Sequence::Grid::GM_DRUMS[name] || Sequence::Grid::ROW_ALIASES[name]
          n ? [n] : []
        end

        # A choke source with its own reader (Notes read their streams
        # themselves).
        def own_notes(s)
          s.is_a?(MB::Sound::Notes) ? MB::Sound::Notes.new(s.stream, sustain: false) : s
        end
      end

      # The block of DrumMethods#kit and Drums.machine (see Machine): defines
      # voices and chokes.
      class Builder
        def initialize(machine)
          @machine = machine
        end

        # Adds the voice +name+ whose block builds its sound from a Hit
        # (`|h| h.body(...) + h.click`; a block without parameters runs on
        # the Hit, so `body(tune) + click`).  Keyword arguments are its
        # knobs with their defaults (read as `h.tune` or `h[:tune]`); +gm:+
        # its General MIDI notes (by default the GM note of its name, if
        # it's one: kick 36, snare 38, closed_hat 42, ...); +as:+ other
        # names for grid rows and knobs.
        #
        # Given a Sample instead of a block, the voice plays it (knobs
        # +tune+ in semitones and +decay+, nil for the sample's own).
        def voice(name, sample = nil, gm: nil, as: [], **defaults, &block)
          if sample
            raise ArgumentError, "Give the #{name} a sample or a block, not both" if block
            s = sample
            defaults = { tune: 0, decay: nil }.merge(defaults)
            block = proc { |h| h.sample(s, tune: h.tune, decay: h.decay) }
          end
          @machine.add_voice(name, defaults, block, gm: gm, aliases: as)
          name.to_sym
        end

        # A choke group: a hit of any voice in +names+ cuts off the others
        # (3 ms ramp).  With +by:+ only those voices' hits cut off +names+:
        # `choke :open_hat, by: :closed_hat`.
        def choke(*names, by: nil)
          @machine.add_choke(names, by: by)
          names
        end

        # Adds TR-909 voices (by name or alias; all of them without names),
        # with their knobs, GM notes, aliases, and the hat choke when both
        # hats are added: `tr909 :kick, :clap`.  Keyword arguments change
        # their knob defaults by voice: `tr909 :kick, kick: { decay: 1.2 }`.
        def tr909(*names, **knobs)
          @machine.add_from(TR909.machine, names, knobs)
        end

        # Adds TR-808 voices (by name or alias; all of them without names)
        # with their knobs, GM notes, and aliases (see Drums::TR808), each
        # with its own metal bank; the open hat is choked by the closed hat
        # when both are added.  `tr808 :cowbell, cowbell: { decay: 0.6 }`.
        def tr808(*names, **knobs)
          @machine.add_from(TR808.machine, names, knobs)
        end

        def to_s
          "kit builder for #{@machine.name}"
        end
        alias inspect to_s
      end

      # A Drums::Machine named +name+ from the block (see Machine).
      def self.machine(name = :kit, &block)
        Machine.new(name, &block)
      end
    end
  end
end
