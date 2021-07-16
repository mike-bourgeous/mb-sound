require 'forwardable'

module MB
  module Sound
    module MIDI
      # An oscillator, filter, and amplifier section, forming one polyphonic
      # voice of a synthesizer.
      class Voice
        extend Forwardable

        DEFAULT_ENVELOPE = {
          attack_time: 0.1,
          decay_time: 0.3,
          sustain_level: 0.5,
          release_time: 0.3,
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
        def initialize(wave_type: nil, filter_type: :lowpass, rate: 48000)
          @filter_intensity = 2.0
          @cutoff = 1000.0
          @quality = 1.5
          @gain = 1.0
          @rate = rate.to_f
          @value = 0.0

          @oscillator = MB::Sound::A4.at(1).at_rate(48000).ramp.oscillator
          @oscillator.wave_type = wave_type if wave_type

          self.filter_type = filter_type

          @filter_envelope = MB::Sound::ADSREnvelope.new(**DEFAULT_ENVELOPE, rate: @rate)
          @amp_envelope = MB::Sound::ADSREnvelope.new(**DEFAULT_ENVELOPE, rate: @rate)

          @cutoff_filter = 60.hz.at_rate(rate).lowpass1p
          @quality_filter = 60.hz.at_rate(rate).lowpass1p

          # TODO: pitch filter for portamento
        end

        # Changes the filter type.  This can be a Symbol that refers to a
        # filter-generating shortcut on MB::Sound::Tone, or an actual Filter
        # object that responds to :process, :reset, :quality=, and
        # :center_frequency=.
        def filter_type=(filter_type)
          if filter_type.respond_to?(:process)
            filter = filter_type
          else
            filter = @cutoff.hz.at_rate(@rate).send(filter_type, quality: @quality)
          end

          raise "Filter #{filter.class} should respond to #process" unless filter.respond_to?(:process)
          raise "Filter #{filter.class} should respond to #reset" unless filter.respond_to?(:reset)
          raise "Filter #{filter.class} should respond to #quality=" unless filter.respond_to?(:quality=)
          raise "Filter #{filter.class} should respond to #center_frequency=" unless filter.respond_to?(:center_frequency=)

          @filter = filter
          @filter.reset(@value)
        end

        # Restarts the amplitude and filter envelopes, and sets the oscillator's
        # pitch to the given note number.
        def trigger(note, velocity)
          @oscillator.reset
          @oscillator.number = note
          @filter_envelope.trigger(velocity / 127.0) # TODO: filter key track (raise filter freq with key freq)
          @amp_envelope.trigger(MB::M.scale(velocity, 0..127, -20..-6).db)
        end

        # Starts the release phase of the filter and amplitude envelopes.
        def release(note, velocity)
          @filter_envelope.release
          @amp_envelope.release
        end

        # Returns +count+ samples of the filtered, amplified oscillator.
        def sample(count)
          buf = @oscillator.sample(count) # TODO: per-sample pitch filtering
          buf.inplace.map { |v|
            @filter.center_frequency = @cutoff_filter.process([@cutoff])[0] * (@filter_intensity ** @filter_envelope.sample)
            @filter.quality = @quality_filter.process([@quality])[0]
            @filter.process([v])[0] * @amp_envelope.sample
          }
          @value = buf[-1]
          buf.not_inplace!
        end
      end
    end
  end
end
