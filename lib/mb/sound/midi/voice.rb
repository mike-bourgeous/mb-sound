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

        def_delegators :@oscillator, :frequency, :frequency=, :random_advance, :random_advance=
        def_delegators :amp_envelope, :active?

        attr_reader :filter_envelope, :amp_envelope, :pitch_filter, :oscillator

        # The filter's base cutoff frequency.  The envelope multiplies this
        # frequency by a value from 1 to #filter_intensity.
        attr_accessor :cutoff

        # The filter's resonance (0.5 to 10 is a good range).
        attr_accessor :quality

        # The output gain (default is 1.0).
        attr_accessor :gain

        # The peak multiple of filter frequency.
        attr_accessor :filter_intensity


        # Initializes a synthesizer voice with the given +:wave_type+ (defaulting
        # to sawtooth/ramp wave) and +:filter_type+ (a shortcut on
        # MB::Sound::Tone, defaulting to :lowpass).
        def initialize(wave_type: nil, filter_type: :lowpass, amp_envelope: {}, filter_envelope: {}, rate: 48000)
          @filter_intensity = 15.0
          @cutoff = 200.0
          @quality = 4.0
          @gain = 1.0
          @rate = rate.to_f
          @value = 0.0

          @oscillator = MB::Sound::A4.at(1).at_rate(48000).ramp.oscillator
          @oscillator.wave_type = wave_type if wave_type

          self.filter_type = filter_type

          @filter_envelope = MB::Sound::ADSREnvelope.new(**DEFAULT_FILTER_ENVELOPE.merge(filter_envelope), rate: @rate)
          @amp_envelope = MB::Sound::ADSREnvelope.new(**DEFAULT_AMP_ENVELOPE.merge(amp_envelope), rate: @rate)

          # TODO: pitch filter for portamento
          # TODO: get these to run fast enough
          #@cutoff_filter = 60.hz.at_rate(rate).lowpass1p
          #@quality_filter = 60.hz.at_rate(rate).lowpass1p
        end

        # Changes the filter type.  This must be a Symbol that refers to a
        # filter-generating shortcut on MB::Sound::Tone.
        def filter_type=(filter_type)
          filter = @cutoff.hz.at_rate(@rate).send(filter_type, quality: @quality)
          filter2 = @cutoff.hz.at_rate(@rate).send(filter_type, quality: @quality)

          raise "Filter #{filter.class} should respond to #dynamic_process" unless filter.respond_to?(:dynamic_process)
          raise "Filter #{filter.class} should respond to #reset" unless filter.respond_to?(:reset)
          raise "Filter #{filter.class} should respond to #quality=" unless filter.respond_to?(:quality=)
          raise "Filter #{filter.class} should respond to #center_frequency=" unless filter.respond_to?(:center_frequency=)

          @filter = filter
          @filter.reset(@value)
          @filter2 = filter2
          @filter2.reset(@value)
        end

        # Restarts the amplitude and filter envelopes, and sets the oscillator's
        # pitch to the given note number.
        def trigger(note, velocity)
          @oscillator.reset
          @oscillator.number = note
          @filter_envelope.trigger(velocity / 256.0 + 0.5)
          @amp_envelope.trigger(MB::M.scale(velocity, 0..127, -20..-6).db)
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
          centers.inplace.clip(20, 18000)
          qualities = Numo::SFloat.zeros(count).fill(@quality).clip(0.25, 10)
          @filter.dynamic_process(re.inplace, centers, qualities)
          @filter2.dynamic_process(im.inplace, centers, qualities)

          @value = buf[-1]
          re + im * 1i
        end
      end
    end
  end
end
