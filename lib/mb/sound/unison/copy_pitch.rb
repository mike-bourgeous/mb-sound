module MB
  module Sound
    module Unison
      # A unison copy whose detune changes (Pitch#unison with a +detune:+
      # node): a Pitch at one output of a Unison::Detune node, making the
      # same kind of oscillator as the pitch it was made from (so copies of
      # a Notes pitch, `v.hz`, keep their key sync; bend, glide, and vibrato
      # come through the base pitch's frequency).  Pitches derived from a
      # copy (#transpose, Pitch#vibrato) are copies too, following the same
      # detune.  Settings of Notes pitches (glide, bend range, vibrato from
      # the controllers) go on the pitch before #unison.
      class CopyPitch < Pitch
        # The pitch the unison was made from.
        attr_reader :base

        # Creates a copy at +frequency+ (a node of Hz) making +base+'s kind of
        # oscillators.
        def initialize(base, frequency)
          @base = base
          super(frequency, sample_rate: base.sample_rate)
        end

        def to_s
          "Unison copy of #{@base}"
        end

        protected

        def new_tone(frequency, wave_type)
          @base.send(:new_tone, frequency, wave_type)
        end

        private

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
