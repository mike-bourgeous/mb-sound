module MB
  module Sound
    module GraphNode
      # Continuously performs an IFFT on the given +data+ which should be the
      # non-negative coefficients of an FFT in a Numo::NArray.  The period of
      # the generated waveform will be 2 * (data.length - 1).
      class IfftSynth
        include GraphNode
        include SampleRateHelper

        # TODO: figure out how to synthesize at an arbitrary period e.g. by
        # skipping bins and using a larger size.
        def self.sawtooth(period)
          buf = Numo::SComplex.new(period / 2).indgen
          buf[1..-1] = 1i * (-1) ** buf[1..-1] / buf[1..-1]
          self.new(data: buf)
        end

        def initialize(data:, sample_rate: 48000)
          @data = data.dup
          @sample_rate = sample_rate.to_f
        end

        def sample(count)
          @cbuf ||= MB::Sound::CircularBuffer.new(buffer_size: (@data.length + count) * 2, complex: true)

          while @cbuf.length < count
            @cbuf.write(MB::Sound.real_ifft(@data))
          end

          @cbuf.read(count).not_inplace!.real.dup # XXX
        end
      end
    end
  end
end
