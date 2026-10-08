module MB
  module Sound
    # A pitch: a frequency source that can become oscillators.  The source is
    # a constant in Hz (`440.hz`, also a wavelength like `2.meters.hz`), or a
    # node producing Hz: a Note's follows the session Tuning (see Note), and
    # a Sequence::Duration's follows the tempo (`1.beat.hz`, see
    # Sequence::TempoNode).
    #
    # Pitches are light values, so they can be passed around and stored
    # (e.g. in sequences) without creating oscillators.  Oscillator methods
    # make a new Tone at this pitch each time they're called: #tone (alias
    # #hz) for a sine, #sine/#triangle/#ramp/... for other waves, and #at,
    # #with_phase, #fm, #log_fm, #pm, #lfo, #noise as shortcuts on that tone;
    # #phasor makes a phasor (Tone#phasor).  Filter helpers (#lowpass, #highpass, ...) use
    # the current frequency.
    #
    # A Pitch used directly as a signal (`play 440.hz`, `440.hz * env`) is a
    # full-scale sine (#signal).  Arithmetic works on that signal, so
    # `440.hz * 2` doubles the amplitude; use #transpose or `(f * 2).hz` for
    # frequency changes.
    #
    # Examples (bin/sound.rb):
    #     play 440.hz                       # a sine at 440 Hz
    #     play 220.hz.ramp.at(0.5)          # a sawtooth
    #     play C4.triangle.at(-6.db)        # a note in the session tuning
    #     filter(noise, 1000.hz.lowpass)    # a filter at the pitch's frequency
    class Pitch
      include GraphNode

      # Creates a Pitch from a frequency in Hz, a wavelength (e.g.
      # `2.meters`), or a node producing Hz.
      def self.[](frequency)
        new(frequency)
      end

      # The sample rate for oscillators made from this pitch.
      attr_reader :sample_rate

      # Creates a pitch at +frequency+ (see the class description).
      # Subclasses like Note pass nil and override #frequency and #freq.
      def initialize(frequency = nil, sample_rate: 48000)
        frequency = SPEED_OF_SOUND / frequency.meters if frequency.is_a?(NumericSoundMixins::Distance)

        unless frequency.nil? || frequency.is_a?(Numeric) || frequency.respond_to?(:sample)
          raise ArgumentError, "A Pitch needs a frequency in Hz or a node (got #{frequency.inspect})"
        end

        @source = frequency.is_a?(Numeric) ? frequency.to_f : frequency
        @sample_rate = sample_rate.to_f
        @signal = nil
      end

      # The current frequency in Hz.
      def frequency
        case
        when @source.is_a?(Numeric) then @source
        when @source.respond_to?(:value) then @source.value
        when @source.respond_to?(:constant) then @source.constant
        else raise ArgumentError, "Can't find the current frequency of #{@source}"
        end
      end

      # True if the frequency never changes (a constant in Hz).
      def constant?
        @source.is_a?(Numeric)
      end

      # A node producing the frequency in Hz.
      def freq
        constant? ? @source.constant(sample_rate: @sample_rate) : @source
      end

      # The frequency to give an oscillator: the constant itself (the fast
      # path) or #freq.
      def oscillator_frequency
        constant? ? @source : freq
      end

      # Returns a new full-scale Tone (sine unless +wave_type+ is given) at
      # this pitch.
      def tone(wave_type = :sine)
        setup_tone(new_tone(oscillator_frequency, wave_type))
      end
      alias hz tone

      # Returns +count+ copies of an oscillator at this pitch, detuned
      # around it and mixed: a unison or "supersaw" sound.  The block is
      # called once per copy with a detuned Pitch (and the copy's index) and
      # returns that copy's oscillator, so any shape or modulation works;
      # without a block the copies are saws.  Works on any Pitch: `220.hz`,
      # Notes like `A3`, and Notes pitches in synth voices (`v.hz`, which
      # keep their key sync, bend, glide, and vibrato).
      #
      # +count+ - The number of copies (default Unison::DEFAULT_COUNT = 3,
      #           or the length of a +detune:+ Array).
      # +detune:+ - How far the outermost copies are from the pitch, either
      #             side: an Interval (default `12.cents`), or semitones.  An
      #             Array gives each copy's offset instead (fixed values
      #             only).  A graph node of semitones (e.g. `v.mod * 0.3`,
      #             or `0.2.hz.lfo.at(5..30) / 100` for 5 to 30 cents)
      #             changes it while playing: each copy keeps its layout
      #             position, a fixed fraction from -1 to 1 of the detune,
      #             and the copies are Unison::CopyPitches (copies of a
      #             Notes pitch take glide, bend range, and vibrato in the
      #             block too, per copy).
      # +detune_mode:+ - How copies follow a +detune:+ node (see
      #                  Unison::Detune): :exact (default) computes every
      #                  copy at f × 2 ** (fraction × detune / 12) every
      #                  sample; :interp computes the outermost ratio
      #                  r = 2 ** (detune / 12) exactly every 16 samples,
      #                  ramps it linearly in between, and spaces the copies
      #                  linearly in Hz from f / r to f × r, so inner copies
      #                  are slightly sharp (the middle one by 0.18 cents at
      #                  25 cents of detune, 0.72 at 50, 2.9 at 100) for
      #                  slightly less CPU (~0.15% of realtime for 7 copies).
      #                  Fixed detunes are always exact.
      # +layout:+ - :random (default) for uneven spacing within the detune,
      #             so the beats between copies don't form a regular pattern
      #             (less flanging; see Unison.offsets), or :even.  The random
      #             layout comes from +seed:+ (an Integer), or by default a
      #             sub-seed of the root generator (MB::Sound.seed), so it
      #             repeats from render to render; in a Synth each voice gets
      #             its own (like slightly different analog voices) unless
      #             +seed:+ is given.
      # +phase:+ - The copies' phases: :random (default) gives every
      #            oscillator made in the block a random phase (Tone#rnd),
      #            which in synth voices means new random phases at every
      #            note-on (key sync with random targets), so notes start
      #            without the zipping, flanging attack of copies starting
      #            together; radians (e.g. 0) start (and key sync) every copy
      #            at that phase, for a hard, repeatable attack; :reset leaves
      #            the block's oscillators as they are.  Call #free in the
      #            block for free-running copies that never reset (random
      #            start, like the JP-8000's supersaw).
      # +spread:+ - Stereo spread from 0 (default: a mono node) to 1 (the
      #             outermost copies hard left and right), or a graph node of
      #             0..1; any spread above 0 returns a stereo Channels bundle.
      #             The sides alternate so each gets copies above and below
      #             the pitch (Unison.pan_slots).
      # +mix:+ - The level of the side copies, 0..2 (a number or a graph
      #          node, clamped), like a supersaw's mix knob on a perceptual
      #          curve: the center copies (the one nearest the pitch for an
      #          odd count, the two nearest for an even count;
      #          Unison.center_copies) stay at level 1 and the others play at
      #          mix²: 0.5 is -12 dB, about 0.7 is -6 dB, 1 (default) every
      #          copy equal (exactly the output without a mix), 1.4 about
      #          +6 dB, 2 +12 dB (sides above the center, a hollow, wide
      #          sound).  The normalization follows the levels (:power keeps
      #          the total power, so loudness stays about the same while the
      #          mix moves; mix 0 with an odd count is the center copy alone
      #          at full level).
      # +normalize:+ - :power (default) scales the sum by 1/sqrt(count), so
      #                the loudness stays about the same for any count (peaks
      #                may pass full scale when copies line up); :peak by
      #                1/count (never louder than one copy, quieter as count
      #                grows); a number scales the plain sum.  With a spread
      #                each channel has the mono mix's power (see
      #                GraphNode::ChannelMixer::Unison).
      #
      # Examples (bin/sound.rb):
      #     play 110.hz.unison(7, detune: 25.cents)                              # a supersaw
      #     play A2.unison(3, detune: 8.cents) { |p| p.square.pwm(0.3) }.at(-6.db)
      #     play 220.hz.unison(7, detune: 20.cents, spread: 0.8).filter(:lowpass, cutoff: 2000)
      #     play 110.hz.unison(5, layout: :even, phase: 0)                      # flanging, hard attack
      #     midi.synth(voices: 4) { |v| v.hz.unison(5, detune: 15.cents, spread: 1) * v.amp_env }
      #     midi.synth(voices: 4) { |v| v.hz.unison(7, detune: v.mod * 0.5) * v.amp_env }  # mod wheel: 0-50 cents
      #     play 110.hz.unison(7, detune: 0.2.hz.lfo.at(0..50) / 100, detune_mode: :interp)  # a bit cheaper
      #     play 110.hz.unison(7, detune: 25.cents, mix: 0.5)                   # sides 12 dB down
      #     play 110.hz.unison(7, detune: 25.cents, mix: 1.5, spread: 1)        # sides 7 dB up: hollow and wide
      #     midi.synth(voices: 4) { |v| v.hz.unison(7, detune: 25.cents, mix: v.mod * 2) * v.amp_env }  # mod wheel: center only to +12 dB sides
      #     midi.synth(voices: 4) { |v| v.hz.unison(5, detune: v.mod * 0.3) { |p| p.glide(50.ms).saw } * v.amp_env }
      #     midi.synth(voices: 4) { |v| v.hz.unison(7) { |p| p.glide(spread(30.ms..300.ms)).saw } * v.amp_env }
      #
      # Per-copy settings: the block gets each copy's index, and pitch
      # methods on a copy (#transpose, #vibrato, and the Notes pitch
      # methods glide, bend_range, vibrato) take per-copy values: a Range
      # (random per copy from the unison's seed), `spread(a..b)` (even by
      # copy, lowest copy first), or `channels(a, b, ...)` (one per copy);
      # see Unison::Copy.  Copies with the same Notes settings share their
      # nodes (one Glide for `p.glide(50.ms)` on every copy).  See #swarm
      # for a ready-made swarm of gliding copies.
      #
      #     play 110.hz.unison(5, detune: 10.cents) { |p| p.vibrato(4.0..6.5, depth: 8.cents).saw }.at(-12.db)   # Range: random rate per copy
      #     play 110.hz.unison(7, spread: 1) { |p| p.vibrato(spread(3..7), depth: 10.cents).saw }.at(-12.db)     # spread: 3 Hz low copy to 7 Hz high
      #     play 110.hz.unison(4, detune: 6.cents) { |p| p.transpose(channels(0, 12, 0, 19)).saw }.at(-12.db)    # channels: octave and 12th stack
      #     play 220.hz.unison(5) { |p| p.transpose(-0.1..0.1).square }.at(-12.db)                             # extra random detune per copy
      #     midi.synth(voices: 4) { |v| v.hz.unison(6) { |p| p.glide(channels(20.ms, 80.ms, 250.ms)).saw } * v.amp_env }  # cycled list
      def unison(count = nil, detune: 12.cents, layout: :random, phase: :random, spread: 0, mix: 1, normalize: :power, seed: nil, detune_mode: :exact, &block)
        Unison.build(self, count, detune: detune, layout: layout, phase: phase, spread: spread, mix: mix, normalize: normalize, seed: seed, detune_mode: detune_mode, &block)
      end

      # Returns a swarm: a unison (see #unison) whose copies glide between
      # notes each in their own time, so the cloud smears and re-forms at
      # every note, optionally spread over the tones of a +chord+, starting
      # scattered (+scatter:+) and converging, and drifting slowly
      # (+drift:+).  Glides need a Notes pitch (`v.hz` in a synth voice,
      # `clip.tone`, `midi.hz`); on other pitches give `glide: nil`.  The
      # block (default `p.saw`) gets each copy's pitch with the glide and
      # drift already applied, and its index.
      #
      # Per-copy arguments (+glide:+, +overshoot:+, +drift_rate:+, and
      # +scatter:+ as a Range) take a Range (random per copy, repeatable
      # from +seed:+), `spread(a..b)` (from the lowest copy to the highest),
      # `channels(...)`, or one value for every copy (see Unison::Copy).
      #
      # +count+ - The number of copies (default 12).
      # +chord:+ - Intervals or semitones above the pitch for the copies to
      #            settle on (copy k takes tone k % length; see
      #            Unison.chord_offsets); nil (default) for a unison.
      # +detune:+ - The detune of the copies on each tone (default
      #             `15.cents`; see #unison).
      # +glide:+ - Each copy's glide time between notes (seconds or
      #            Lengths; default Unison::SWARM_GLIDE, random from 80 ms to
      #            0.9 s), or nil for no glide.
      # +legato:+ - Only legato notes glide (see Notes::NotePitch#glide).
      # +overshoot:+ - How far glides pass their target, as a fraction of
      #                the glide (default none; e.g. 0..0.15; see Notes::Glide;
      #                with a +shape:+, that curve's size).
      # +shape:+ - The glide curve (default nil: smoothstep; a name such as
      #            :squiggle, :elastic, :back, :bounce, or :steps, or a
      #            Curve; see Notes::NotePitch#glide and MB::Sound::Curve),
      #            per copy with `channels(:squiggle, :bounce)`.
      # +cycles:+ - Wiggles, swings, bounces, or steps of a named +shape+
      #             (the curve's default when nil; per-copy values work).
      # +scatter:+ - Where copies start before the first note glides them
      #              in: an Interval (e.g. `1.oct`, either side of the first
      #              note, random per copy) or a Range of Intervals; nil
      #              (default) starts them on the note.
      # +from:+ - Where copies start instead, as an absolute band: a Range
      #           of Pitches, Notes, or note numbers (e.g. `G3..G4`, like
      #           the THX Deep Note's 200-400 Hz cloud), random per copy.
      # +drift:+ - A slow wander of each copy by up to this Interval (e.g.
      #            `20.cents`), a sine LFO at a random phase; nil (default)
      #            for none.
      # +drift_rate:+ - The drift LFOs' rates in Hz (default
      #                 Unison::SWARM_DRIFT_RATE, 0.05 to 0.35 Hz per copy).
      # Other options (+layout:+, +phase:+, +spread:+ (default 1 here),
      # +mix:+, +normalize:+, +seed:+, +detune_mode:+) go to #unison.
      #
      # Examples (bin/sound.rb; more in bin/songs/swarm_song.rb):
      #     midi.synth(voices: 1) { |v| v.hz.swarm(12) * v.amp_env }                       # copies arrive one by one
      #     midi.synth(voices: 2) { |v| v.hz.swarm(16, glide: spread(50.ms..1.5.seconds), overshoot: 0..0.1) * v.amp_env }
      #     midi.synth(voices: 1) { |v| v.hz.swarm(24, chord: [-12, 0, 7, 12, 16, 19], scatter: 2.oct, glide: 2..6) * v.amp_env(2, 0, 1, 3) }
      #     play 110.hz.swarm(9, glide: nil, drift: 15.cents)                                  # a drifting cloud on a fixed pitch
      #     midi.synth(voices: 1) { |v| v.hz.swarm(10, glide: spread(40.ms..600.ms), shape: :squiggle, cycles: 3..6) * v.amp_env }
      def swarm(count = 12, chord: nil, detune: 15.cents, glide: :auto, legato: false, overshoot: nil, shape: nil, cycles: nil, scatter: nil, from: nil, drift: nil,
                drift_rate: Unison::SWARM_DRIFT_RATE, spread: 1, **unison, &block)
        Unison.swarm(
          self, count, chord: chord, detune: detune, glide: glide, overshoot: overshoot, shape: shape, cycles: cycles, scatter: scatter, from: from, legato: legato,
          drift: drift, drift_rate: drift_rate, spread: spread, **unison, &block
        )
      end

      # The phase setting for oscillators made from a unison copy (see
      # #unison and Unison.apply_phase; nil normally).  Pitches derived from
      # a copy (#transpose, #vibrato, ...) keep it, so e.g. an FM modulator
      # at `p.transpose(12)` in a unison block gets it too.
      attr_accessor :unison_phase

      # The Unison::Copy this pitch belongs to inside a unison block (see
      # #unison; nil normally).  Pitches derived from a copy keep it, and
      # methods taking per-copy settings (ranges, `spread(a..b)`; see
      # Unison::Copy) resolve them through it.
      attr_accessor :unison_copy

      # Wave shapes: each returns a new Tone at this pitch.
      [
        :sine, :sin, :triangle, :square, :ramp, :saw, :sawtooth, :drumramp, :envramp, :gauss, :parabola,
        :atriangle, :asquare, :aramp, :asaw, :asawtooth,
        :complex_sine, :complex_square, :complex_triangle, :complex_ramp,
        :acomplex_square, :acomplex_triangle, :acomplex_ramp,
      ].each do |wave|
        define_method(wave) { tone.public_send(wave) }
      end

      # Shortcuts for a sine Tone at this pitch (see Tone#at, #with_phase,
      # #fm, #log_fm, #pm, #feedback/#fb, #lfo, #pwm/#skew, #noise), and a
      # pulse (Tone#pulse, #apulse).
      def at(amplitude) = tone.at(amplitude)
      def gain(gain) = tone.gain(gain)
      def amp(gain) = tone.gain(gain)
      def with_phase(phase) = tone.with_phase(phase)
      def fm(tone_or_node, index = nil) = tone.fm(tone_or_node, index)
      def log_fm(tone_or_node, index = nil) = tone.log_fm(tone_or_node, index)
      def pm(tone_or_node, index = nil) = tone.pm(tone_or_node, index)
      def fm_feedback(amount, gain: nil, dc: false) = tone.fm_feedback(amount, gain: gain, dc: dc)
      def fm_fb(amount, gain: nil, dc: false) = tone.fm_feedback(amount, gain: gain, dc: dc)
      def fm_feedback_cycles(cycles, gain: nil, dc: false) = tone.fm_feedback_cycles(cycles, gain: gain, dc: dc)
      def fm_fb_cycles(cycles, gain: nil, dc: false) = tone.fm_feedback_cycles(cycles, gain: gain, dc: dc)
      def lfo = tone.lfo
      def sync(master = nil, ratio: nil) = tone.sync(master, ratio: ratio)
      def softsync(master = nil, ratio: nil) = tone.softsync(master, ratio: ratio)
      def wraps = signal.wraps
      def increment = signal.increment
      def pwm(width, dc: false) = tone.pwm(width, dc: dc)
      def skew(width, dc: false) = tone.skew(width, dc: dc)
      def pulse(width = 0.5, dc: false) = tone.pulse(width, dc: dc)
      def apulse(width = 0.5, dc: false) = tone.apulse(width, dc: dc)
      def noise(blend = true, seed: nil) = tone.noise(blend, seed: seed)

      # An additive oscillator at this pitch whose harmonic amplitudes
      # (+spectrum+: numbers, graph nodes, or a callable of the time) may
      # change while it plays (see GraphNode::HarmonicTable).  Also called
      # #additive.
      #
      #     play 110.hz.harmonics([1, 0.5, 0.33, 0.25]) * 0.5
      #     play 110.hz.additive([1, 0, 0.33, 0, 0.2]) * 0.5            # odd harmonics: square-ish
      #     play 110.hz.additive([1, 0.2.hz.lfo.at(0..1), 0.5]) * 0.5  # a moving 2nd harmonic
      def harmonics(spectrum, phases: nil, update: GraphNode::HarmonicTable::DEFAULT_UPDATE, interpolation: nil)
        GraphNode::HarmonicTable.new(
          frequency: oscillator_frequency, spectrum: spectrum, phases: phases, update: update,
          interpolation: interpolation, sample_rate: @sample_rate
        )
      end
      alias additive harmonics

      # A wavetable Tone at this pitch (see Tone#wavetable).
      def wavetable(table, scan: nil, interpolation: nil, scan_wrap: false) = tone.wavetable(table, scan: scan, interpolation: interpolation, scan_wrap: scan_wrap)

      # Shortcuts for a sine Tone at this pitch with a reset input
      # (Tone#reset), never reset (Tone#free), or a random phase
      # (Tone#random_phase / #rnd).
      def reset(trigger, to: nil, keep_feedback: nil) = tone.reset(trigger, to: to, keep_feedback: keep_feedback)
      def free(free = true) = tone.free(free)
      def random_phase(seed: nil) = tone.random_phase(seed: seed)
      alias rnd random_phase

      # For a tempo-synced pitch (Sequence::Duration#hz), lets the phases of
      # its oscillators run free of the timeline (see
      # Sequence::TempoNode#freewheel).
      def freewheel(free = true)
        raise ArgumentError, 'Only tempo-synced tones (e.g. 4.bars.lfo) can freewheel' unless @source.respond_to?(:freewheel)

        @source.freewheel(free)
        self
      end

      # Returns a phasor (a Tone that outputs its phase in cycles; see
      # Tone#phasor) at this pitch, starting at +phase+ (cycles).
      def phasor(phase: 0.0)
        tone(:phasor).with_phase_cycles(phase % 1.0)
      end

      # The sine this pitch plays as when used directly as a signal (created
      # on first use).
      def signal
        @signal ||= tone
      end

      def sample(count)
        signal.sample(count)
      end

      def sources
        { signal: signal }
      end

      # Sets the sample rate for oscillators made from now on (and #signal).
      def sample_rate=(sample_rate)
        @sample_rate = sample_rate.to_f
        @signal&.at_rate(@sample_rate)
        self
      end
      alias at_rate sample_rate=

      # Returns a Pitch with vibrato: a sine LFO at +rate+ Hz (a number or
      # node) moving the frequency up and down by +depth+ (an Interval such
      # as `30.cents`, semitones, or a node of semitones).  Notes pitches
      # (Notes#hz) also have MIDI defaults (see Notes::NotePitch#vibrato).
      #
      #     play A4.vibrato(5.5, depth: 30.cents).triangle
      def vibrato(rate = nil, depth: nil)
        raise ArgumentError, 'Pitch#vibrato needs a rate and depth: (MIDI-controlled vibrato comes from Notes#hz)' if rate.nil? || depth.nil?

        rate = per_copy(rate)
        depth = per_copy(depth)

        depth = Interval.semitones(depth).to_f unless depth.respond_to?(:sample)
        lfo = Tone.new(frequency: rate, sample_rate: @sample_rate).lfo
        rebased(GraphNode::SemitoneShift.new(freq, lfo * depth, sample_rate: @sample_rate))
      end

      # Returns a Pitch +semitones+ higher (lower if negative); +semitones+
      # may be an Interval (`7.st`, `1.oct`), or a graph node of semitones
      # (e.g. `0.2.hz.lfo.at(-0.3..0.3)` to wander by 30 cents).  On a
      # unison copy it may also be a per-copy setting (see Unison::Copy).
      #
      # A tempo-synced pitch (`1.beat.hz`) transposed by a fixed interval
      # stays tempo-synced: its oscillators follow a Sequence::TempoNode
      # of the duration divided by the ratio (TempoNode#scaled), so they
      # stay locked to the timeline.
      def transpose(semitones)
        semitones = per_copy(semitones)
        return rebased(GraphNode::SemitoneShift.new(freq, semitones, sample_rate: @sample_rate)) if semitones.respond_to?(:sample)

        semitones = Interval.semitones(semitones)
        ratio = 2 ** (semitones / 12.0)
        return rebased(@source.scaled(ratio)) if @source.is_a?(Sequence::TempoNode) && @source.mode == :hz

        rebased(constant? ? @source * ratio : freq * ratio)
      end

      # The period of one cycle in seconds and in samples.
      def period = 1.0 / frequency
      def period_samples = period * @sample_rate

      # The wavelength of this pitch in air (see SPEED_OF_SOUND).
      def wavelength
        (SPEED_OF_SOUND / frequency).meters
      end

      # Returns the nearest Note (with detuning) in the current tuning.
      def to_note
        Note.new(MB::Sound.tuning.number_of(frequency))
      end

      # Converts to a note-on MB::Sound::MIDI::Event at the nearest note
      # (see Note#to_midi).
      def to_midi(velocity: 64, channel: 0)
        to_note.to_midi(velocity: velocity, channel: channel)
      end

      # A second-order low-pass filter at this frequency.
      #
      # Examples:
      #     1000.hz.lowpass
      #     1000.hz.at_rate(44100).lowpass
      def lowpass(quality: 1)
        MB::Sound::Filter::Cookbook.new(:lowpass, @sample_rate, frequency, quality: quality)
      end

      # A first-order low-pass filter at this frequency.
      #
      # Examples:
      #     50.hz.lowpass1p
      #     10.hz.at_rate(60).lowpass1p
      def lowpass1p
        MB::Sound::Filter::FirstOrder.new(:lowpass1p, @sample_rate, frequency)
      end

      # A second-order high-pass filter at this frequency.
      def highpass(quality: 1)
        MB::Sound::Filter::Cookbook.new(:highpass, @sample_rate, frequency, quality: quality)
      end

      # A peaking filter at this frequency with +gain+ (linear, default 1)
      # and a bandwidth of +octaves+.  `500.hz.at(3.db).peak` uses the
      # amplitude as the gain (see Tone#peak).
      def peak(octaves: 0.5, gain: 1.0)
        MB::Sound::Filter::Cookbook.new(:peak, @sample_rate, frequency, bandwidth_oct: octaves, db_gain: gain.to_db)
      end

      # A LinearFollower that follows full-scale changes no faster than this
      # frequency (see Tone#follower).
      def follower
        tone.follower
      end

      # Compares pitches by frequency (e.g. for Ranges of Notes).  Not
      # Comparable: == stays identity, since pitches are graph nodes too.
      def <=>(other)
        case other
        when Numeric then frequency <=> other
        when Pitch, Tone then frequency <=> other.frequency
        end
      end

      def to_s
        "#{MB::M.sigfigs(frequency, 6)} Hz" rescue "#{self.class.name} (variable)"
      end

      def inspect
        "#<#{self.class.name} #{self}>"
      end

      protected

      # Returns a new Tone (before #setup_tone) at +frequency+ (Hz or a node
      # of Hz) for #tone.  Subclasses that make other oscillators (e.g.
      # Notes::NotePitch's key-synced tones) override it, and unison copies
      # with a changing detune (Unison::CopyPitch) use it to make their
      # base pitch's kind of oscillator at their own frequency.
      def new_tone(frequency, wave_type)
        Tone.new(frequency: frequency, wave_type: wave_type, sample_rate: @sample_rate)
      end

      private

      # Returns a Pitch at +frequency+ (Hz or a node of Hz) derived from
      # this one (for #transpose and #vibrato; see #derived).
      def rebased(frequency)
        derived(Pitch.new(frequency, sample_rate: @sample_rate))
      end

      # Gives +pitch+, derived from this one, this pitch's #unison_phase.
      # Returns +pitch+.
      def derived(pitch)
        pitch.unison_phase = @unison_phase
        pitch.unison_copy = @unison_copy
        pitch
      end

      # Resolves a per-copy +value+ (a Range, `spread(a..b)`, or
      # `channels(...)`; see Unison::Copy) for this unison copy, or returns
      # +value+ unchanged.
      def per_copy(value)
        return value unless Unison::Copy.per_copy?(value)
        raise ArgumentError, "Per-copy values (#{value}) work only on unison copies, inside a Pitch#unison block" if @unison_copy.nil?

        @unison_copy.pick(value)
      end

      # Applies this pitch's settings to a +tone+ made from it (#follow, and
      # the #unison_phase).  Returns the tone.
      def setup_tone(tone)
        follow(tone)
        @unison_phase ? Unison.apply_phase(tone, @unison_phase) : tone
      end

      # Locks the phase of a tone made from this pitch to the timeline if
      # the frequency comes from a tempo source (Sequence::TempoNode; see
      # Tone#follow_timeline).
      def follow(tone)
        tone.follow_timeline(@source) if @source.is_a?(Sequence::TempoNode)
        tone
      end
    end
  end
end

require_relative 'unison'
