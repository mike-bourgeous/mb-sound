module MB
  module Sound
    class Notes
      # A Tone made from a Notes pitch (Notes#hz): its phase resets at each
      # note-on of the Notes instance (key sync, Tone#reset(v.key_trigger))
      # by default, except re-strikes that add energy to a sounding voice
      # (envelopes with +retrigger: :add+; see Notes#key_trigger), so a
      # ringing note struck again keeps its phase instead of clicking.  Calling #free, #lfo, #sync, or #softsync
      # drops the key sync quietly, since those mean the tone isn't reset by
      # notes; #reset replaces it; #rnd keeps it (a random phase at each
      # note).
      class KeyedTone < MB::Sound::Tone
        # Turns key sync on with +trigger+ (a Notes#key_trigger).  Returns
        # self.
        #
        # Sets the reset input directly instead of through Tone#reset (which
        # KeyedTone overrides to drop key sync, and which warns about
        # conflicting calls).  The frequency of a vibrato pitch may already
        # depend on the same trigger (its LFO resets at note-ons); the cycle
        # check accepts that second path.
        def key_sync(trigger)
          raise ArgumentError, 'Key sync must be set before sync or other resets' if @sync_source || @reset

          configure do
            @reset = fixup_source(trigger)
            @reset_to = nil
            @key_sync = @reset
          end
        end

        # True if the tone still resets at each note (see the class
        # description).
        def key_sync?
          !@key_sync.nil? && @reset.equal?(@key_sync)
        end

        def reset(trigger, to: nil)
          drop_key_sync
          super
        end

        def free(free = true)
          drop_key_sync if free
          super
        end

        def lfo
          drop_key_sync
          super
        end

        def sync(master = nil, ratio: nil)
          drop_key_sync
          super
        end

        def softsync(master = nil, ratio: nil)
          drop_key_sync
          super
        end

        private

        # Removes the key sync reset input, if it's still there, without the
        # warnings Tone gives for conflicting calls, and destroys its Tee
        # branch.
        def drop_key_sync
          return unless @key_sync

          if @reset.equal?(@key_sync)
            configure do
              @reset = nil
              @reset_to = nil
            end
          end
          @key_sync.destroy if @key_sync.respond_to?(:destroy)
          @key_sync = nil
        end
      end

      # A Pitch whose frequency follows a Notes instance (Notes#hz, alias
      # #tone and #pitch): the held note number plus pitch bend through the
      # session Tuning.  Oscillators made from it (#tone, #saw, #square, ...)
      # are KeyedTones that reset their phase at every note-on (except :add
      # re-strikes of a sounding voice; see Notes#key_trigger), unless they
      # are #free or #lfo.
      #
      # Settings return a new NotePitch (pitches are values):
      # - #bend_range(12.st): the bend range of this pitch (the stream's by
      #   default; see MIDI::Stream#bend_range).
      # - #transpose(7.st): an offset (or a graph node of semitones).
      #
      # Inside a unison block (Pitch#unison), the settings may be per-copy
      # values: a Range (random per copy), `spread(a..b)` (even by copy),
      # or `channels(...)` (see Unison::Copy).
      #
      # Examples:
      #     play v.hz.saw * v.amp_env
      #     play (v.hz.saw + v.hz.transpose(-1.oct).square.free) * v.amp_env
      class NotePitch < MB::Sound::Pitch
        # The Notes instance this pitch follows.
        attr_reader :notes

        # The settings (see the class description) as a Hash.
        attr_reader :settings

        DEFAULTS = { bend_range: nil, transpose: 0.0 }.freeze

        def initialize(notes, sample_rate: notes.sample_rate, **settings)
          @notes = notes
          extra = settings.keys - self.class::SETTINGS
          raise ArgumentError, "Unknown pitch settings #{extra.inspect}" unless extra.empty?
          @settings = DEFAULTS.merge(settings).freeze
          super(nil, sample_rate: sample_rate)
        end

        # Setting names accepted by #initialize.
        SETTINGS = [:bend_range, :transpose, :glide, :vibrato, :shift].freeze

        # The node producing this pitch's frequency in Hz (a
        # Notes::Frequency, made on first use).
        def freq
          @freq ||= @notes.frequency_for(@settings, @sample_rate) { build_freq }
        end

        # The current frequency in Hz.
        def frequency
          freq.value
        end

        def constant?
          false
        end

        def oscillator_frequency
          freq
        end

        # A KeyedTone at this pitch (see the class description).
        def tone(wave_type = :sine)
          setup_tone(new_tone(freq, wave_type))
        end
        alias hz tone

        # Returns a NotePitch with a bend range of +range+ (an Interval or
        # semitones, e.g. `12.st`), or the stream's with nil.
        def bend_range(range)
          range = per_copy(range)
          with(bend_range: range.nil? ? nil : Interval.semitones(range).to_f)
        end

        # Returns a NotePitch with vibrato (see Notes#vibrato for the
        # arguments).  With no arguments, the GM controllers set it: depth =
        # mod wheel × 50 cents (× CC 77), rate = CC 76 (5.5 Hz at 64), and a
        # fade-in after each note-on of CC 78 (none at 64).  Explicit
        # +rate+ (Hz) and +depth:+ (an Interval or semitones, e.g.
        # `30.cents`) may be numbers or nodes; missing ones come from the
        # controllers, and +delay:+ (seconds) is 0 unless given or all are
        # left to the controllers.
        #
        #     play v.hz.vibrato.saw * v.amp_env
        #     play v.hz.vibrato(6, depth: 20.cents).saw * v.amp_env
        def vibrato(rate = nil, depth: nil, delay: nil)
          with(vibrato: [per_copy(rate), per_copy(depth), per_copy(delay)].freeze)
        end

        # Returns a NotePitch that glides between notes (portamento) over
        # +time+ (seconds or a length, e.g. `50.ms`; a node of seconds; or
        # :gm for CC 5 time with CC 65 on/off and CC 84), in the pitch
        # domain.  With +legato: true+ only legato notes glide; otherwise
        # every note after the first does.  +from:+ (a Pitch or note number)
        # is where the pitch starts, so the first note glides from it too.
        # An Interval +from:+ is relative to the first note (e.g. `-1.oct`).
        # +overshoot:+ passes the target by that fraction of the glide's
        # distance before settling (0..1, default 0).  See Notes::Glide.
        #
        # Pitches with the same glide settings on one Notes instance share
        # one Glide node (e.g. every copy of a unison with
        # `p.glide(50.ms)`).
        #
        #     play v.hz.glide(80.ms).saw * v.amp_env
        #     play v.hz.glide(:gm, legato: true).saw * v.amp_env.legato
        #     play v.hz.glide(100.ms, from: 440.hz).saw * v.amp_env
        #     play v.hz.glide(300.ms, overshoot: 0.1).saw * v.amp_env
        def glide(time, legato: false, from: nil, overshoot: 0)
          time = per_copy(time)
          # Per-copy starts of Intervals stay relative (see Unison::Copy)
          relative = Unison::Copy.per_copy?(from) && Unison::Copy.values_of(from).all?(Interval)
          from = per_copy(from)
          from = from.semitones if relative && from.is_a?(Numeric)
          overshoot = per_copy(overshoot)
          settings = [time, !!legato]
          settings << from unless from.nil? && overshoot == 0
          settings << overshoot.to_f unless overshoot == 0
          with(glide: settings.freeze)
        end

        # Returns a NotePitch +semitones+ higher (an Interval or semitones),
        # or following a graph node of semitones (e.g. an LFO for a slow
        # wander).
        def transpose(semitones)
          semitones = per_copy(semitones)
          return with(shift: [*@settings[:shift], semitones.get_sampler].freeze) if semitones.respond_to?(:sample)

          with(transpose: @settings[:transpose] + Interval.semitones(semitones).to_f)
        end

        def to_s
          "Notes pitch #{MB::M.sigfigs(frequency, 6)} Hz"
        end

        def inspect
          "#<#{self.class.name} #{@settings.reject { |k, v| DEFAULTS[k] == v }}>"
        end

        protected

        # A KeyedTone at +frequency+, key synced to the notes (see Pitch#new_tone).
        def new_tone(frequency, wave_type)
          KeyedTone.new(frequency: frequency, wave_type: wave_type, sample_rate: @sample_rate).key_sync(@notes.key_trigger)
        end

        private

        # A copy with changed settings.
        def with(**changes)
          derived(NotePitch.new(@notes, sample_rate: @sample_rate, **@settings, **changes))
        end

        # The note number node (see #build_freq): Notes#number, or a
        # Notes::Glide.
        def number_node
          return @notes.number unless @settings[:glide]

          time, legato, from, overshoot = @settings[:glide]
          @notes.send(:memo, [:glide, @settings[:glide], @sample_rate]) {
            Glide.new(@notes.note_stream, time: time, legato: legato, from: from, overshoot: overshoot || 0, notes: @notes, sample_rate: @sample_rate)
          }
        end

        # Semitone offsets for #build_freq.
        def offsets
          o = [@notes.bend_semitones(@settings[:bend_range])]
          o << @settings[:transpose] if @settings[:transpose] != 0
          o << @notes.vibrato(*@settings[:vibrato][0..0], depth: @settings[:vibrato][1], delay: @settings[:vibrato][2]) if @settings[:vibrato]
          o.concat(@settings[:shift]) if @settings[:shift]
          o
        end

        def build_freq
          Frequency.new(number_node, offsets: offsets, sample_rate: @sample_rate)
        end
      end
    end
  end
end
