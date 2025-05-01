require 'forwardable'

module MB
  module Sound
    module MIDI
      # An oscillator, filter, and amplifier section, forming one polyphonic
      # voice of a synthesizer.
      class Voice
        extend Forwardable

        DEFAULT_AMP_ENVELOPE = {
          attack_time: 0.005,
          decay_time: 0.05,
          sustain_level: 0.5,
          release_time: 0.6,
        }

        DEFAULT_FILTER_ENVELOPE = {
          attack_time: 0.05,
          decay_time: 1.5,
          sustain_level: 0.3,
          release_time: 0.4,
        }

        def_delegators :@oscillator, :frequency, :frequency=, :random_advance, :random_advance=, :number, :wave_type, :wave_type=
        def_delegators :amp_envelope, :active?, :on?

        attr_reader :filter_envelope, :amp_envelope, :oscillator, :sample_rate, :re_filter, :im_filter

        # The filter's base cutoff frequency.  The envelope multiplies this
        # frequency by a value from 1 to #filter_intensity.
        attr_accessor :cutoff

        # The filter's resonance (0.5 to 10 is a good range).
        attr_reader :quality

        # The output gain (default is 1.0).
        attr_accessor :gain

        # The peak multiple of filter frequency.
        attr_accessor :filter_intensity

        # Blends between filtered (1.0) and unfiltered (0.0) audio.
        attr_accessor :filter_blend


        # Initializes a synthesizer voice with the given +:wave_type+ (defaulting
        # to sawtooth/ramp wave) and +:filter_type+ (a shortcut on
        # MB::Sound::Tone, defaulting to :lowpass).
        def initialize(wave_type: nil, filter_type: :lowpass, amp_envelope: {}, filter_envelope: {}, sample_rate: 48000)
          @filter_intensity = 15.0
          @cutoff = 200.0
          @quality = 4.0
          @last_quality = 4.0
          @gain = 1.0
          @sample_rate = sample_rate.to_f
          @value = 0.0
          @filter_blend = 1.0

          @oscillator = MB::Sound::A4.at(1).at_rate(48000).ramp.oscillator
          @oscillator.wave_type = wave_type if wave_type

          self.filter_type = filter_type

          @filter_envelope = MB::Sound::ADSREnvelope.new(**DEFAULT_FILTER_ENVELOPE.merge(filter_envelope), sample_rate: @sample_rate)
          @amp_envelope = MB::Sound::ADSREnvelope.new(**DEFAULT_AMP_ENVELOPE.merge(amp_envelope), sample_rate: @sample_rate)

          # TODO: pitch filter for portamento
          # TODO: get these to run fast enough
          #@cutoff_filter = 60.hz.at_rate(rate).lowpass1p
          #@quality_filter = 60.hz.at_rate(rate).lowpass1p
        end

        # Changes the filter type.  This must be a Symbol that refers to a
        # filter-generating shortcut on MB::Sound::Tone.
        def filter_type=(filter_type)
          re_filter = @cutoff.hz.at_rate(@sample_rate).send(filter_type, quality: @quality)
          im_filter = @cutoff.hz.at_rate(@sample_rate).send(filter_type, quality: @quality)

          raise "Filter #{re_filter.class} should respond to #dynamic_process" unless re_filter.respond_to?(:dynamic_process)
          raise "Filter #{re_filter.class} should respond to #reset" unless re_filter.respond_to?(:reset)
          raise "Filter #{re_filter.class} should respond to #quality=" unless re_filter.respond_to?(:quality=)
          raise "Filter #{re_filter.class} should respond to #center_frequency=" unless re_filter.respond_to?(:center_frequency=)

          @re_filter = re_filter
          @re_filter.reset(@value)
          @im_filter = im_filter
          @im_filter.reset(@value)
        end

        # Restarts the amplitude and filter envelopes, and sets the oscillator's
        # pitch to the given note number.
        def trigger(note, velocity)
          # TODO: maybe don't reset oscillators, or randomize phase, so phase
          # is more interesting, but that would make consistent plotting more
          # challenging
          @oscillator.reset unless @oscillator.no_trigger
          @oscillator.number = note
          @filter_envelope.trigger(velocity / 256.0 + 0.5)
          @amp_envelope.trigger(MB::M.scale(velocity, 0..127, -20..-6).db)
        end

        # Sets the oscillator's pitch to the given note number without
        # resetting any envelopes.
        def number=(note)
          @oscillator.number = note
        end

        # Same as #number=, but with an ignored keyword argument for VoicePool
        # compatibility.  TODO: implement portamento?
        def set_note(note, reset_portamento: :ignored)
          self.number = note
        end

        # Sets the filter quality, clamping to 0.5..10.0.
        def quality=(q)
          @quality = MB::M.clamp(q.to_f, 0.5, 10.0)
        end

        # Starts the release phase of the filter and amplitude envelopes.
        def release(note, velocity)
          @filter_envelope.release
          @amp_envelope.release
        end

        # Returns +count+ samples of the filtered, amplified oscillator.
        def sample(count)
          buf = @oscillator.sample(count) * @amp_envelope.sample(count) # TODO: per-sample pitch filtering (probably way too slow)
          re = buf.real
          im = buf.imag

          # TODO: Reduce max quality for higher cutoff and/or oscillator frequencies?
          centers = @cutoff * MB::M.scale(@oscillator.number, 0..127, 0.9..2.0) * @filter_intensity ** @filter_envelope.sample(count)
          centers.inplace.clip(20, [@cutoff, 18000].max)

          if @last_quality != @quality
            @qualities = Numo::SFloat.linspace(@last_quality, @quality, count)
            @last_quality = @quality
          else
            @qualities ||= Numo::SFloat.zeros(count).fill(@quality)
          end

          # Filtering real and imaginary separately is faster than processing
          # complex values.
          case @filter_blend
          when 1.0
            @re_filter.dynamic_process(re.inplace, centers, @qualities)
            @im_filter.dynamic_process(im.inplace, centers, @qualities)

          when 0.0
            # Do nothing

          else
            re2 = @re_filter.dynamic_process(re, centers, @qualities)
            im2 = @im_filter.dynamic_process(im, centers, @qualities)

            re = MB::M.interp(re, re2, @filter_blend)
            im = MB::M.interp(im, im2, @filter_blend)
          end

          @value = buf[-1]
          re + im * 1i
        end
      end
    end
  end
end
