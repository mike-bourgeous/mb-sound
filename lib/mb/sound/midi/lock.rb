module MB
  module Sound
    module MIDI
      # Scale and chord mapping for keyboards (midi-consol-2; ux-r4 items 8
      # and 10): pure note maps (a played key number and a timeline
      # position in, the note to sound out, or nil for silence) shared by
      # the stream transforms (Stream#degrees, Stream#snap(:chord),
      # Stream#lock), the Session's input lock (`lock :play`), and the
      # virtual keyboard's scale lock, so a computer key and an external
      # keyboard's key give the same note.
      #
      # Every map reads its scale (or chord) at the position, so it can
      # follow the session key (`key :d, :dorian`) or a param (a knob's
      # #choose, a clip of chords).  Note-offs follow their note-ons in the
      # transforms, so a held note keeps its mapping when the scale changes
      # under it.
      module Lock
        # Semitone offsets of the white keys in an octave.
        WHITE = [0, 2, 4, 5, 7, 9, 11].freeze

        # The black keys in the order :fit adds them to the white keys for
        # scales of 8 to 12 notes (pitch order, filling the biggest gaps of
        # a white-key octave first is no better for playing: C#, D#, F#, G#,
        # A#).
        BLACK = [1, 3, 6, 8, 10].freeze

        # Layouts of Degrees (see there).
        LAYOUTS = [:flow, :fit].freeze

        # What black keys play in Degrees (see there).
        BLACKS = [:passing, :silent, :lower].freeze

        # How Degrees and Chord give notes between semitones (cents
        # scales): :mark (the default, maintainer 2026-10-18: the nearest
        # whole note with a pitch mark for the rest: MIDI bytes as a bend
        # before the note-on; samplers and `v.hz.transpose(v.pitch_mark)`
        # play it) or :note (a fractional note number: internal synths play
        # it exactly through `v.hz`, but it has no MIDI 1.0 bytes).
        MICRO = [:note, :mark].freeze

        # Graph nodes (knobs, LFOs) read by params in +x+ (a Style or a Map)
        # (see Transform#param_nodes).
        def self.param_nodes(x)
          x.instance_variables.flat_map { |iv|
            v = x.instance_variable_get(iv)
            case v
            when Param::Base then v.nodes
            when Map, Style then param_nodes(v)
            when Hash then v.values.flat_map { |y| y.is_a?(Param::Base) ? y.nodes : y.is_a?(Map) || y.is_a?(Style) ? param_nodes(y) : [] }
            else []
            end
          }
        end

        # The key nearest middle C that plays a scale's root in Degrees: the
        # root's pitch class in C4's octave (pitch classes up to F#) or the
        # octave below (G up), so roots stay within half an octave of the
        # keys.
        def self.anchored(scale)
          rc = scale.root_class
          root = 60 + (rc > 6 ? rc - 12 : rc)
          scale.root == root ? scale : scale.with_root(root)
        end

        # The Scale +x+ gives at timeline position +pos+: nil follows the
        # session key (the transport's key map), a Symbol is a mode on the
        # session key's root, a Scale or MusicalKey is itself, and a param
        # (MIDI::Param: a knob's #choose, a clip of scale names) is read at
        # +pos+ and resolved the same way.
        def self.scale_at(x, pos, transport:, stream: nil)
          x = x.value_at(pos, transport: transport, stream: stream) if x.is_a?(Param::Base)
          case x
          when Scale then x
          when MusicalKey then x.scale(pos, transport: transport)
          when nil then key_at(transport, pos).scale(pos, transport: transport)
          when Symbol, String then key_at(transport, pos).with_mode(x).scale
          when Array then Scale[x, key_at(transport, pos).root]
          else raise ArgumentError, "A lock's scale is a Scale, a mode name, nil (the session key), or a param giving one (got #{x.inspect})"
          end
        end

        # The session key at +pos+ on +transport+ (C major without one).
        def self.key_at(transport, pos)
          transport ? transport.key_at(pos || transport.position) : MusicalKey.default
        end

        # +x+ checked as a scale argument (raising early for bad names).
        def self.check_scale(x)
          case x
          when nil, Scale, MusicalKey then x
          when Symbol, String then MusicalKey.check_mode(x)
          when Array then Scale[x] && x
          else
            raise ArgumentError, "A lock's scale is a Scale, a mode name, or nil (the session key); got #{x.inspect}" unless Param.param?(x)
            Param.wrap(x, 'The scale')
          end
        end

        # Common behavior: #map gives the note for a played key (see
        # Lock), #event maps a note-on Event (nil to silence it).
        class Map
          attr_reader :micro

          def initialize(micro: :mark)
            raise ArgumentError, "micro: must be #{MICRO.map(&:inspect).join(' or ')} (got #{micro.inspect})" unless MICRO.include?(micro)
            @micro = micro
          end

          # The note-on +e+ mapped at timeline position +pos+, or nil.
          def event(e, pos, transport:, stream: nil)
            return e unless e.note.is_a?(Numeric)
            n = map(e.note, pos, transport: transport, stream: stream)
            return nil if n.nil?
            Lock.with_note(e, n, @micro)
          end

          # Keyword options that differ from the defaults (for #to_s and the
          # styles' printing).
          def options
            {}
          end
        end

        # +e+ moved to note +n+ (a whole note as is; a fraction as the
        # nearest whole note with a pitch mark for the rest, or a fractional
        # note with +micro: :note+).
        def self.with_note(e, n, micro)
          n = Transform::Transpose.whole(n)
          return e.with_note(n) if n.is_a?(Integer) || micro == :note
          whole = n.round
          Event.note_on(whole, e.velocity, channel: e.channel, time: e.time, legato: e.legato, pitch: (e.pitch || 0) + (n - whole).to_f, flam: e.flam, length_hint: e.length_hint)
        end

        # Scale degrees on the keys (Stream#degrees): white keys walk the
        # scale, so no white key plays a wrong note.
        # - layout :flow: each white key is the next degree, counting from
        #   the root on middle C (see Lock.anchored), so 5- and 6-note scales
        #   drift up an octave every few keyboard octaves (good for mashing
        #   and exotic scales; 7-note scales line up with the octaves).
        # - layout :fit: each keyboard octave is one octave of the scale,
        #   with the root on every C: up to 7 notes spread over the white
        #   keys (with repeats for fewer), 8 to 12 notes take the white keys
        #   and then black keys in pitch order (BLACK).
        # Black keys (and :fit's unused ones), +black+:
        # - :passing: the pitch strictly between the scale notes of the white
        #   keys on either side (a gap of 2: the middle; 3 or more: just
        #   below the upper note, the blue-note feel); half-step neighbours
        #   have none (silent); cents scales get the midpoint.
        # - :silent: nothing.
        # - :lower: the scale note of the white key below.
        class Degrees < Map
          attr_reader :scale, :layout, :black

          def initialize(given = nil, scale: given, layout: :flow, black: :passing, micro: :mark)
            super(micro: micro)
            raise ArgumentError, "layout: must be #{LAYOUTS.map(&:inspect).join(' or ')} (got #{layout.inspect})" unless LAYOUTS.include?(layout)
            raise ArgumentError, "black: must be #{BLACKS.map(&:inspect).join(', ')} (got #{black.inspect})" unless BLACKS.include?(black)
            @scale = Lock.check_scale(scale)
            @layout = layout
            @black = black
          end

          def map(note, pos, transport:, stream: nil)
            sc = Lock.anchored(Lock.scale_at(@scale, pos, transport: transport, stream: stream))
            n = note.round
            octave, within = (n - 60).divmod(12)
            @layout == :flow ? flow(sc, octave, within) : fit(sc, octave, within)
          end

          def options
            { layout: (@layout unless @layout == :flow), black: (@black unless @black == :passing), micro: (@micro unless @micro == :mark) }.compact
          end

          def to_s
            parts = [(@scale.nil? ? nil : Param.label(@scale.is_a?(Symbol) ? @scale.inspect : @scale))] + options.map { |k, v| "#{k}: #{v.inspect}" }
            "degrees(#{parts.compact.join(', ')})"
          end

          private

          def flow(sc, octave, within)
            if (w = WHITE.index(within))
              return sc.note(octave * 7 + w)
            end
            w = WHITE.rindex { |x| x < within }
            between(sc, octave * 7 + w, octave * 7 + w + 1)
          end

          def fit(sc, octave, within)
            size = sc.size
            if size <= 7
              if (w = WHITE.index(within))
                return sc.note(octave * size + w * size / 7)
              end
              w = WHITE.rindex { |x| x < within }
              return between(sc, octave * size + w * size / 7, octave * size + (w + 1) * size / 7)
            end

            keys = (WHITE + BLACK.take(size - 7)).sort
            if (i = keys.index(within))
              return sc.note(octave * size + i)
            end
            i = keys.rindex { |x| x < within }
            between(sc, octave * size + i, octave * size + i + 1)
          end

          # The black-key note between degrees +lo+ and +hi+ (see the class
          # comment).
          def between(sc, lo, hi)
            case @black
            when :silent then nil
            when :lower then sc.note(lo)
            else
              a = sc.note(lo)
              b = sc.note(hi)
              gap = b - a
              return nil if gap <= 1
              return (a + b) / 2r if gap != gap.round # (cents scales)
              gap == 2 ? a + 1 : b - 1
            end
          end
        end

        # Every key to the nearest scale note, keeping the keyboard layout
        # (Stream#snap with no scale or a mode; `lock :along`): ties go
        # down, octaves stay where they are.
        class ScaleSnap < Map
          attr_reader :scale, :direction

          def initialize(given = nil, scale: given, direction: :nearest, micro: :mark)
            super(micro: micro)
            raise ArgumentError, "direction: must be :nearest, :down, or :up (got #{direction.inspect})" unless [:nearest, :down, :up].include?(direction)
            @scale = Lock.check_scale(scale)
            @direction = direction
          end

          def map(note, pos, transport:, stream: nil)
            Lock.scale_at(@scale, pos, transport: transport, stream: stream).snap(note, @direction)
          end

          def options
            { direction: (@direction unless @direction == :nearest), micro: (@micro unless @micro == :mark) }.compact
          end

          def to_s
            parts = [(@scale.nil? ? nil : Param.label(@scale.is_a?(Symbol) ? @scale.inspect : @scale))] + options.map { |k, v| "#{k}: #{v.inspect}" }
            "snap(#{parts.compact.join(', ')})"
          end
        end

        # Every key to the nearest tone of the current chord (Stream#snap
        # with :chord; `lock :chord`), the chord from +from+ at each note's
        # position:
        # - a Clip (chords as notes sounding together; looping clips follow
        #   the timeline), a Generative::Chord (`chord(:min7, root: :d)`),
        #   an Array of chord degrees counted from 1 like ghost_chords
        #   (`[1, 4, 5, 1]`, one per +per+, a bar by default, in the session
        #   key's scale), or a param giving any of these (a knob's #choose);
        # - nil: the session key's tonic triad.
        # +extend+: false (only the chord's own tones, in any octave),
        # :above (the chord's tones within its voiced range; above its top
        # note, thirds stacked from the session scale: 7, 9, 11, 13 (from
        # the chord's quality when its root isn't in the scale)), true
        # (those extensions in every octave).  +avoid+ (true) leaves out
        # avoid notes among the extensions (natural 11 over a major third,
        # b9 over a minor third).  +bass+ :root_fifth: keys below the
        # chord's lowest note play its root or fifth.
        class Chord < Map
          # Extensions above a chord's root when its root isn't in the scale
          # (semitones: 7th, 9th, 11th, 13th).
          QUALITY_EXTENSIONS = { major: [11, 14, 17, 21], minor: [10, 14, 17, 21], other: [10, 14, 17, 21] }.freeze

          # Extend modes (see the class comment).
          EXTENDS = [false, :above, true].freeze

          attr_reader :from, :extend, :avoid, :bass, :per

          def initialize(from: nil, extend: false, avoid: true, bass: nil, per: nil, scale: nil, micro: :mark)
            super(micro: micro)
            raise ArgumentError, "extend: must be false, :above, or true (got #{extend.inspect})" unless EXTENDS.include?(extend)
            raise ArgumentError, "bass: must be nil or :root_fifth (got #{bass.inspect})" unless bass.nil? || bass == :root_fifth
            @from = from.is_a?(Array) || from.nil? || from.is_a?(Sequence::Clip) || from.is_a?(Generative::Chord) ? from : Param.wrap(from, 'The chords')
            @extend = extend
            @avoid = !!avoid
            @bass = bass
            @per = per && Sequence::Duration.whole_notes(per)
            @scale = Lock.check_scale(scale)
          end

          def map(note, pos, transport:, stream: nil)
            voiced = chord_at(pos, transport, stream)
            return note if voiced.empty?

            sc = Lock.scale_at(@scale, pos, transport: transport, stream: stream)
            low = voiced.min
            high = voiced.max
            pcs = voiced.map { |n| n.round % 12 }.uniq
            root = low.round % 12
            ext = @extend ? extensions(root, pcs, sc) : []
            fifth = [root, (root + 7) % 12]

            ok = ->(k) {
              pc = k % 12
              if @bass && k < low then fifth.include?(pc)
              elsif @extend == :above then k <= high ? pcs.include?(pc) : (pcs.include?(pc) || ext.include?(pc))
              elsif @extend then pcs.include?(pc) || ext.include?(pc)
              else pcs.include?(pc)
              end
            }
            n = note.round
            (0..12).each do |d|
              return n - d if ok.(n - d)
              return n + d if d > 0 && ok.(n + d)
            end
            note
          end

          def options
            { from: @from, extend: (@extend unless @extend == false), avoid: (@avoid unless @avoid), bass: @bass, per: @per && Sequence::Duration.new(@per), micro: (@micro unless @micro == :mark) }.compact
          end

          def to_s
            "snap(:chord#{options.map { |k, v| ", #{k}: #{v.is_a?(Symbol) ? v.inspect : Param.label(v)}" }.join})"
          end

          # The chord's voiced notes at +pos+ (an Array of note numbers).
          def chord_at(pos, transport, stream)
            Chord.voiced(@from, pos, transport: transport, stream: stream, per: @per, scale: @scale)
          end

          # Voiced chord notes of +from+ at +pos+ (see the class comment).
          def self.voiced(from, pos, transport:, stream: nil, per: nil, scale: nil)
            from = Param.value_at(from, pos, transport: transport, stream: stream) if from.is_a?(Param::Base)
            case from
            when nil
              sc = Lock.anchored(Lock.scale_at(scale, pos, transport: transport))
              sc.chord(0)
            when Sequence::Clip then clip_chord(from, pos)
            when Generative::Chord then from.notes.map { |n| n.respond_to?(:number) ? n.number : n }
            when Array
              return [] if from.empty?
              # Notes (C4, 60, ...) are one chord; small Integers (1..14)
              # are chord degrees, one per +per+
              return from.map { |n| n.respond_to?(:number) ? n.number : n } unless from.all? { |x| x.is_a?(Integer) && x.between?(1, 14) }

              span = per || (transport ? transport.bar_length(pos) : 1r)
              index = transport && per.nil? ? transport.bar_at(pos).floor - 1 : (pos / span).floor
              degree = from[index % from.length]
              sc = Lock.anchored(Lock.scale_at(scale, pos, transport: transport))
              sc.chord(degree - 1)
            when Integer then [from]
            else raise ArgumentError, "Chords come from a clip, chord(...), degrees like [1, 4, 5], or a param giving one (got #{from.inspect})"
            end
          end

          # The notes of +clip+ sounding at clip position +pos+ (or, between
          # chords, the last chord that started).
          def self.clip_chord(clip, pos)
            pos = pos.to_r
            phase = clip.looping? ? pos % clip.length : pos
            cycle = clip.looping? ? (pos / clip.length).floor : 0
            events = clip.looping? ? clip.events_for(cycle) : clip.events
            on = events.select { |e| e.start <= phase && phase < e.start + e.length }
            if on.empty?
              last = events.select { |e| e.start <= phase }.map(&:start).max
              on = last ? events.select { |e| e.start == last } : []
            end
            on.map(&:value).filter_map { |v| v.respond_to?(:number) && !v.is_a?(Numeric) ? v.number : (v.is_a?(Numeric) ? v : nil) }
          end

          private

          # Extension pitch classes above +root+ (see the class comment).
          def extensions(root, pcs, sc)
            third = pcs.include?((root + 4) % 12) ? :major : pcs.include?((root + 3) % 12) ? :minor : :other
            r = root + 60
            list = if sc.include?(r)
                     d = sc.degree(r)[0]
                     [6, 8, 10, 12].map { |k| sc.note(d + k).round % 12 }
                   else
                     QUALITY_EXTENSIONS[third].map { |s| (root + s) % 12 }
                   end
            if @avoid
              list -= [(root + 5) % 12] if third == :major
              list -= [(root + 1) % 12] if third == :minor
            end
            list - pcs
          end
        end

        # A lock applied to events as they arrive, outside a stream (the
        # Session's input lock, `lock :play`; see Session::MidiInput): maps
        # each note-on at its timeline position through +style+ and sends
        # its note-off (and poly pressure) to the note it became, so held
        # notes keep their pitch when the style, key, or chord changes.
        # Controllers feed the style's cc params.
        class Live
          attr_reader :style

          def initialize(style)
            @style = style
            @held = {} # [channel, played note] => Array of sounding notes (nil: silent), oldest first
            @reading = Param::Reading.new
          end

          # Changes the style; held notes keep their mapping.
          def style=(style)
            @style = style
          end

          # The events +e+ becomes at timeline position +pos+ (an Array).
          def process(e, pos, transport:)
            case e.type
            when :note_on
              out = e.note.is_a?(Numeric) ? @style.event(e, pos, transport: transport, stream: @reading) : e
              (@held[[e.channel, e.note]] ||= []) << out&.note
              out ? [out] : []
            when :note_off
              list = @held[[e.channel, e.note]]
              return [e] if list.nil? # (a note pressed before the lock)
              n = list.shift
              @held.delete([e.channel, e.note]) if list.empty?
              n.nil? ? [] : [n == e.note ? e : Event.note_off(n.round, e.velocity, channel: e.channel, time: e.time)]
            when :poly_pressure
              n = @held[[e.channel, e.note]]&.last
              n.nil? ? [] : [n == e.note ? e : e.with_note(n.round)]
            else
              @reading.observe(e) if e.type == :cc
              [e]
            end
          end

          # True while notes it mapped are held.
          def holding?
            !@held.empty?
          end
        end

        # A lock style (`lock :play`): one verb for the scale and chord maps,
        # by intent (ux-r4 item 10), with keyword overrides:
        # - :mash - degrees, layout :flow, black keys silent: mash any keys,
        #   every note is in the scale.
        # - :play - degrees, layout :fit (the root on every C), black keys
        #   passing notes: play it like a keyboard in the key.
        # - :along - every key to the nearest scale note, keeping the layout.
        # - :chord - every key to the current chord's tones, extend :above.
        # - :off - keys as played.
        # The scale is the session key unless +scale:+ gives one (or a
        # param: `lock :play, scale: knob(:mode).choose(:dorian, :lydian)`).
        class Style
          # The styles: [map class, default options].
          STYLES = {
            mash: [Degrees, { layout: :flow, black: :silent }],
            play: [Degrees, { layout: :fit, black: :passing }],
            along: [ScaleSnap, {}],
            chord: [Chord, { extend: :above }],
            off: [nil, {}],
          }.freeze

          attr_reader :name, :overrides, :map

          def initialize(name = :play, **overrides)
            if Param.param?(name)
              # A style that moves (a knob's #choose): each style it gives
              # is built once and read at each note's position
              @name = Param.wrap(name, 'The lock style')
              @overrides = overrides.freeze
              @map = nil
              @styles = {}
              freeze
              return
            end
            @styles = nil
            name = name.to_sym if name.is_a?(String)
            unless STYLES.key?(name)
              hint = DidYouMean::SpellChecker.new(dictionary: STYLES.keys.map(&:to_s)).correct(name.to_s).first
              raise ArgumentError, "Unknown lock style #{name.inspect}#{hint ? " (did you mean :#{hint}?)" : ''}; styles: #{STYLES.keys.map(&:inspect).join(', ')}"
            end
            @name = name
            @overrides = overrides.freeze
            klass, defaults = STYLES[name]
            @map = klass && klass.new(**defaults.merge(overrides))
            freeze
          end

          def off?
            @styles.nil? && @map.nil?
          end

          # True for a style read from a param (see #initialize).
          def moving?
            !@styles.nil?
          end

          # The fixed Style in effect at +pos+ (itself unless moving).
          def at(pos, transport:, stream: nil)
            return self unless @styles
            v = @name.value_at(pos, transport: transport, stream: stream)
            v = v.to_sym if v.is_a?(String)
            @styles[v] ||= Style.new(v, **@overrides)
          end

          # The note for played key +note+ at +pos+ (nil: silent).
          def map_note(note, pos, transport:, stream: nil)
            return at(pos, transport: transport, stream: stream).map_note(note, pos, transport: transport, stream: stream) if @styles
            @map ? @map.map(note, pos, transport: transport, stream: stream) : note
          end

          # The note-on +e+ mapped at +pos+ (nil: silent).
          def event(e, pos, transport:, stream: nil)
            return at(pos, transport: transport, stream: stream).event(e, pos, transport: transport, stream: stream) if @styles
            @map ? @map.event(e, pos, transport: transport, stream: stream) : e
          end

          # The style as Ruby: the short preset when not overridden
          # (`lock(:play)`), else with its overrides.
          def to_s
            parts = [@name.is_a?(Symbol) ? @name.inspect : Param.label(@name)] + @overrides.map { |k, v| "#{k}: #{v.is_a?(Symbol) ? v.inspect : Param.label(v)}" }
            "lock(#{parts.join(', ')})"
          end

          def inspect
            "#<Lock #{self}>"
          end

          # A Style from +x+: a Style, a style name, or a param giving one
          # (a knob's #choose).
          def self.[](x, **overrides)
            x.is_a?(Style) && overrides.empty? ? x : new(x, **overrides)
          end
        end
      end
    end
  end
end
