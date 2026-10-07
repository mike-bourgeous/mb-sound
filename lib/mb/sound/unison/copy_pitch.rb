module MB
  module Sound
    module Unison
      # The copies of a unison with a changing detune (Pitch#unison with a
      # +detune:+ node), made on first use: the Unison::Detune node giving
      # every copy's frequency (#frequency), and each copy's detune offset
      # in semitones (#offset), for copies of Notes pitches that take their
      # own Notes settings (see CopyPitch).  Nothing is built for copies
      # that never make an oscillator, so no graph branch goes unread.
      class CopySet
        # The pitch the unison was made from.
        attr_reader :base

        # The detune node (semitones) as given.
        attr_reader :detune

        # The copies' layout positions (-1..1).
        attr_reader :fractions

        def initialize(base, detune, fractions:, mode:)
          @base = base
          @detune = detune
          @fractions = fractions
          @mode = mode
          @node = nil
          @offsets = {}
        end

        # The Unison::Detune node (made on first use).
        def node
          @node ||= Detune.new(@base.oscillator_frequency, @detune, fractions: @fractions, mode: @mode, sample_rate: @base.sample_rate)
        end

        # The frequency output (Hz) of copy +index+.
        def frequency(index)
          node.outputs[index]
        end

        # A node of copy +index+'s offset in semitones (its fraction times
        # the detune; made once per copy), or nil for a copy at fraction 0.
        def offset(index)
          f = @fractions[index]
          return nil if f == 0

          @offsets[index] ||= (@detune * f).named("unison offset #{index + 1}")
        end
      end

      # A unison copy whose detune changes (Pitch#unison with a +detune:+
      # node): a Pitch at one output of a Unison::Detune node, making the
      # same kind of oscillator as the pitch it was made from (so copies of
      # a Notes pitch, `v.hz`, keep their key sync; bend, glide, and vibrato
      # set before #unison come through the base pitch's frequency).
      # Pitches derived from a copy (#transpose, Pitch#vibrato) are copies
      # too, following the same detune.
      #
      # Copies of a Notes pitch (Notes::NotePitch) also take the Notes pitch
      # settings in the unison block (#glide, #bend_range, #vibrato, and
      # #transpose by a node), per copy: they return a NotePitch with the
      # copy's settings and its detune offset (CopySet#offset) as a
      # transpose node, so its frequency follows the detune exactly (like
      # Detune's :exact mode) through Notes::Frequency.  Copies with the
      # same glide settings share one Notes::Glide.
      #
      #     v.hz.unison(5, detune: v.mod * 0.3) { |p| p.glide(50.ms).saw }
      #     v.hz.unison(5, detune: v.mod * 0.3) { |p, i| p.glide((i + 1) * 40.ms).vibrato(5 + i * 0.3, depth: 15.cents).saw }
      class CopyPitch < Pitch
        # The pitch the unison was made from.
        attr_reader :base

        # The copy's index, or nil for a pitch derived through a frequency
        # node (e.g. Pitch#vibrato).
        attr_reader :index

        # The copy's fixed transpose in semitones (see #transpose).
        attr_reader :shift

        # Creates a copy at +frequency+ (a node of Hz) making +base+'s kind of
        # oscillators, or copy +index+ of +set+ (a CopySet; frequency from
        # its Detune node on first use) transposed by +shift+ semitones.
        def initialize(base, frequency = nil, set: nil, index: nil, shift: 0.0)
          @base = base
          @set = set
          @index = index
          @shift = shift.to_f
          raise ArgumentError, 'A unison copy needs a frequency or a copy set and index' if frequency.nil? && (set.nil? || index.nil?)

          super(frequency, sample_rate: base.sample_rate)
        end

        def freq
          return super unless @set

          @freq ||= @shift == 0 ? @set.frequency(@index) : @set.frequency(@index) * 2 ** (@shift / 12.0)
        end

        def frequency
          return super unless @set

          @set.frequency(@index).value * 2 ** (@shift / 12.0)
        end

        def constant?
          @set ? false : super
        end

        def oscillator_frequency
          @set ? freq : super
        end

        # Returns a copy +semitones+ higher (see Pitch#transpose); a node of
        # semitones on a copy of a Notes pitch gives a NotePitch (see the
        # class description).
        def transpose(semitones)
          semitones = per_copy(semitones)
          return notes_pitch.transpose(semitones) if notes? && semitones.respond_to?(:sample)
          return super unless @set && !semitones.respond_to?(:sample)

          derived(CopyPitch.new(@base, set: @set, index: @index, shift: @shift + Interval.semitones(semitones).to_f))
        end

        # On a copy of a Notes pitch, Notes::NotePitch#glide for this copy.
        def glide(time, legato: false, from: nil, overshoot: 0)
          notes_pitch!(:glide).glide(time, legato: legato, from: from, overshoot: overshoot)
        end

        # On a copy of a Notes pitch, Notes::NotePitch#bend_range for this
        # copy.
        def bend_range(range)
          notes_pitch!(:bend_range).bend_range(range)
        end

        # On a copy of a Notes pitch, Notes::NotePitch#vibrato for this copy
        # (MIDI defaults for missing arguments); otherwise Pitch#vibrato.
        def vibrato(rate = nil, depth: nil, delay: nil)
          return notes_pitch.vibrato(rate, depth: depth, delay: delay) if notes?
          raise ArgumentError, 'Vibrato delay needs a Notes pitch (e.g. v.hz)' unless delay.nil?

          super(rate, depth: depth)
        end

        # True if this copy can become a Notes::NotePitch with its own
        # settings (a copy of a Notes pitch; see the class description).
        def notes?
          !@set.nil? && @base.is_a?(Notes::NotePitch)
        end

        # This copy as a Notes::NotePitch: the base pitch transposed by
        # #shift and by the copy's detune offset node.
        def notes_pitch
          raise ArgumentError, "#{self} isn't a copy of a Notes pitch" unless notes?

          p = @base
          p = p.transpose(@shift) if @shift != 0
          offset = @set.offset(@index)
          p = p.transpose(offset) if offset
          p.unison_phase = @unison_phase
          p.unison_copy = @unison_copy
          p
        end

        def to_s
          "Unison copy#{" #{@index + 1}" if @index} of #{@base}"
        end

        protected

        def new_tone(frequency, wave_type)
          @base.send(:new_tone, frequency, wave_type)
        end

        private

        # #notes_pitch, or an error naming +method+ for copies of other
        # pitches.
        def notes_pitch!(method)
          return notes_pitch if notes?

          raise ArgumentError, "#{method} needs a unison of a Notes pitch (e.g. v.hz or clip.tone; this is #{self})"
        end

        def rebased(frequency)
          derived(CopyPitch.new(@base, frequency))
        end

        # Tempo-synced base pitches lock their copies to the timeline too.
        def follow(tone)
          @base.send(:follow, tone)
        end
      end
    end
  end
end
