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
          buf = Numo::SComplex.new(period / 2 + 1).indgen
          buf[1..-1] = 1i * (-1) ** buf[1..-1] / buf[1..-1]
          buf.inplace * (1.69492 / Math::PI) # empirical scaling factor to avoid clipping
          self.new(data: buf)
        end

        # https://en.wikipedia.org/wiki/Square_wave_(waveform)
        def self.square(period)
          buf = Numo::SComplex.zeros(period / 2 + 1)
          bview = buf[(1..-1).step(2)]
          bview.indgen.inplace + 1
          1.0 / (bview.inplace * 2 - 1)
          bview[] = bview
          buf.inplace * (3.38983i / Math::PI) # empirical scaling
          self.new(data: buf)
        end

        attr_reader :data

        def initialize(data:, sample_rate: 48000)
          @data = data.dup
          @time_data = MB::Sound.real_ifft(@data)
          @sample_rate = sample_rate.to_f
        end

        def sample(count)
          growbuf(count)

          while @cbuf.length < count
            @cbuf.write(@time_data)
          end

          @cbuf.read(count)
        end

        private

        def growbuf(count)
          size = (@data.length + count) * 2

          @cbuf ||= MB::Sound::CircularBuffer.new(buffer_size: size, complex: true)

          if @cbuf.buffer_size < size
            @cbuf = @cbuf.dup(size)
          end
        end
      end
    end
  end
end
