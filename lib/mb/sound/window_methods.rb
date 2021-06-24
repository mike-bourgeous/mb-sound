module MB
  module Sound
    # Methods for processing sound in overlapping or non-overlapping chunks
    # (called "windows"), whether in the time domain or frequency domain.
    # MB::Sound extends itself with this module.
    #
    # These methods represent an evolution of techniques over time, starting
    # with #process and #process_split, and reaching the #analyze_time_window
    # and #synthesize_time_window and related methods.  See the commit history.
    #
    # Recommended methods: #analyze_time_window, #synthesize_time_window, #process_window
    #
    # TODO: Document these better in the context of the MB::Sound CLI.
    module WindowMethods
      # Non-overlapping processing of an entire file in a single FFT.  Passes
      # an array of Numo::DComplex DFTs of each channel to the +block+,
      # configured for in-place processing, then writes the inverse DFT of
      # whatever is returned by the block to out_filename.  Thus the block may
      # either modify the arrays in place and return them, or create new arrays
      # of the same or different sizes.
      #
      # The yielded DFT arrays will contain only positive frequencies.
      #
      # Input files are always resampled to 48kHz, and output values are
      # normalized to a maximum of 1.0.
      #
      # Examples (MB::Sound may be omitted when running in bin/sound.rb):
      #
      #     # Simple amplifier
      #     MB::Sound.process('sounds/synth0.flac', '/tmp/louder.flac') do |dfts|
      #       dfts.map do |c|
      #         c * 2 # in-place processing, but must return the dfts
      #       end
      #     end
      #     play '/tmp/louder.flac'
      #
      #     # Reverse an audio file (the slow way)
      #     MB::Sound.process('sounds/synth0.flac', '/tmp/reverse.flac') do |dfts|
      #       dfts.map(&:conj)
      #     end
      #     play '/tmp/reverse.flac'
      #
      #     # Scramble an audio file's frequencies
      #     # This tends to blur the sound of an audio file across the entire file.
      #     MB::Sound.process('sounds/synth0.flac', '/tmp/scramble.flac') do |dfts|
      #       dfts.map { |c|
      #         # This is obviously suboptimal (in-place shuffling would be faster)
      #         # Creation and concatenation of Ruby Array is faster than for Numo::NArray
      #         Sound.array_to_narray(c.split(c.size / 100).map { |s| s.to_a.shuffle! }.reduce(&:concat))
      #       }
      #     end
      #     play '/tmp/scramble.flac'
      #
      #     # Gradually roll off higher frequencies
      #     # Just a subtle treble reduction:
      #     MB::Sound.process('sounds/synth0.flac', '/tmp/dark.flac') do |dfts|
      #       scale = Numo::SFloat.linspace(1, 0, dfts.first.size)
      #       dfts.map { |c| c * scale }
      #     end
      #     play '/tmp/dark.flac'
      #
      #     # Or a more notable rolloff:
      #     MB::Sound.process('sounds/synth0.flac', '/tmp/darker.flac') do |dfts|
      #       scale = Numo::SFloat.logspace(0, -5, dfts.first.size)
      #       dfts.map { |c| c * scale }
      #     end
      #     play '/tmp/darker.flac'
      def process(in_filename, out_filename, &block)
        raise 'No block given' unless block_given?

        channels = read(in_filename)
        frames = channels.first.size

        dfts = channels.map { |c| real_fft(c).inplace! }
        modified = yield dfts
        results = modified.map { |c| real_ifft(c, odd_length: frames.odd?) }

        normalize_max(results)

        write(out_filename, results)
      end

      # Non-overlapping processing of an entire file in multiple DFTs.  Splits
      # the sound into chunks of +split_size+ frames with no overlap, then
      # sequentially yields the DFTs of each chunk to the block.  The final
      # chunk is padded with zeros.
      #
      # Input files are always resampled to 48kHz.
      def process_split(in_filename, out_filename, split_size, &block)
        raise 'No block given' unless block_given?

        channels = read(in_filename)
        frames = channels.first.size

        splits = (split_size...frames).step(split_size).to_a
        channels.map! { |c|
          c.split(splits).map { |s| MB::M.zpad(s, split_size) }
        }

        results = []
        for idx in 0...channels.first.size
          dfts = channels.map { |c| real_fft(c[idx]) }
          modified = yield dfts
          results << modified.map { |c| real_ifft(c, odd_length: c.size.odd?) }
        end

        puts "Processed #{results.size} chunks of size #{split_size}"

        results = results.transpose.map { |c| array_to_narray(c.map(&:to_a).reduce(&:concat))[0...frames] }

        normalize_max(results)

        write(out_filename, results)
      end

      # Processes a sound file in chunks of length +split_size+, with a cross-faded
      # overlap of +overlap_size+.
      #
      # Input files are always resampled to 48kHz.
      def process_overlap(in_filename, out_filename, split_size, overlap_size, &block)
        raise 'No block given' unless block_given?
        raise 'Overlap size must be less than split size' unless overlap_size < split_size

        channels = read(in_filename)
        frames = channels.first.size

        hop_size = split_size - overlap_size
        fade_in = linear_fade(0, 1, overlap_size)
        fade_out = 1 - fade_in

        count = 0
        outputs = nil
        for offset in (0...frames).step(hop_size)
          STDOUT.write("\r\e[K#{(offset * 100 / frames)}%")
          STDOUT.flush

          count += 1
          slice = channels.map { |c| MB::M.zpad(c[offset...[offset + split_size, c.size].min], split_size) }
          dfts = slice.map { |c| real_fft(c) }
          modified = yield dfts
          outputs ||= modified.size.times.map { Numo::SFloat.zeros(frames + split_size) }
          raise "Channel count changed from #{outputs.size} to #{modified.size}" if modified.size != outputs.size

          outputs.each_with_index do |out, idx|
            c = real_ifft(modified[idx], odd_length: split_size.odd?).inplace!
            out_span = out[offset...(offset + split_size)].inplace!

            if offset > 0
              out_span[0...overlap_size].inplace! * fade_out
              c[0...overlap_size].inplace! * fade_in
            end

            for i in 0...out_span.size
              out_span[i] += c[i]
            end
          end
        end

        puts "\rProcessed #{count} chunks of size #{split_size} with overlap #{overlap_size}"

        outputs = outputs.map { |c| c[0...frames] }

        normalize_max(outputs)

        write(out_filename, outputs)
      end

      # Processes audio using overlapping cross-fades, from an +input_stream+ that
      # can return a requested number of frames (specifically +hop_size+) as an
      # array of Numo::SFloat arrays.  Writes audio to +output_stream+ as an array
      # of Numo::SFloat.
      #
      # Calls the block with an array of NArrays with +split_size+ samples each,
      # incrementing by +hop_size+ each frame.
      #
      # The +input_stream+ should provide a read method that takes a number of
      # frames as its parameter and returns an array of Numo::SFloat arrays.
      #
      # The +output_stream+ should provide a write method that takes an array of
      # Numo::SFloat arrays.
      #
      # The +block+ should return the same number of channels as expected by the
      # +output_stream+.
      def process_time_stream(input_stream, output_stream, split_size, hop_size, &block)
        overlap_size = split_size - hop_size

        in_bufs = input_stream.channels.times.map { Numo::SFloat.zeros(split_size) }
        out_bufs = output_stream.channels.times.map { Numo::SFloat.zeros(split_size) }
        output = []

        if overlap_size > 1
          fade_in = MB::M.opad(linear_fade(0, 1, overlap_size), split_size)
          fade_out = 1 - fade_in
        end

        loop do
          input = input_stream.read(hop_size)
          break if input.first.length == 0 # FIXME: drain the buffer
          input = input.map { |c| MB::M.zpad(c, hop_size) }

          in_bufs.each_with_index do |c, idx|
            if hop_size < split_size
              c[0..(overlap_size - 1)] = c[hop_size..-1]
            end
            c[overlap_size..-1] = input[idx]
          end

          if block_given?
            result = yield in_bufs
          else
            result = in_bufs
          end

          raise "Processing block returned #{result.size} channels instead of #{output_stream.channels}" unless result.size == output_stream.channels

          out_bufs.each_with_index do |c, idx|
            if hop_size < split_size
              # Fade out old
              c.inplace!
              c * fade_out
              c.not_inplace!

              # Fade in new
              result[idx].inplace!
              result[idx] * fade_in
              result[idx].not_inplace!

              # Add (whole buffer)
              c[0..-1] = c[0..-1] + result[idx]

              # Extract first hop
              output[idx] = c[0..(hop_size - 1)].clone

              # Shift buffer
              c[0..(overlap_size - 1)] = c[hop_size..-1]
              c[overlap_size..-1] = 0
            else
              output[idx] = result[idx]
            end
          end

          wrote = output_stream.write(output)
          break if wrote != output.first.size
        end
      end

      # Like #process_time_stream(), but passes DFT data to the block.
      #
      # Uses a +split_size+ length FFT, with +hop_size+ hops.  This imposes a
      # latency of +split_size+.
      def process_stream(input_stream, output_stream, split_size, hop_size, &block)
        process_time_stream(input_stream, output_stream, split_size, hop_size) do |in_bufs|
          dfts = in_bufs.map { |c| real_fft(c) }
          if block_given?
            modified = yield dfts # TODO define a standard parameter system with time domain, frequency domain, stream info, etc.
          else
            modified = in_bufs
          end

          modified.map { |c| real_ifft(c, odd_length: split_size.odd?) }
        end
      end

      # Analyzes audio from the given array of +input_streams+ with the given
      # +window+ function.  Continues providing zeros for each input stream until
      # all input streams have ended.
      #
      # The block, if given, is called with the window-multiplied time domain data
      # of each overlapping window of each input stream, with one  per
      # stream.  For example, five two-channel input streams will result in a
      # five-element array of two-element arrays being passed to the block.  That
      # is, an array (for inputs) of arrays (for channels) of NArrays (for
      # samples).
      def analyze_multi_time_window(input_streams, window, &block)
        readers = input_streams.map { |i| Sound::WindowReader.new(i, window) }
        zero = Numo::SFloat.zeros(window.length)

        loop do
          audio = readers.map { |r| r.read }
          break if audio.all?(&:nil?)

          audio = audio.each_with_index.map { |s, idx|
            s || ([zero] * input_streams[idx].channels)
          }

          yield audio
        end
      end

      # Analyzes audio from the given +input_stream+ with the given +window+
      # function.  Pads the window and input data to +pad_factor+ times the
      # original window length.  Reads in hop-sized chunks as specified by the
      # window.
      #
      # The block, if given, is called with the window-multiplied time domain data
      # of each overlapping window.
      #
      # Returns an array with everything that was returned by the block.  If a
      # block was not given, returns an array containing the array of DFTs for each
      # frame.
      def analyze_time_window(input_stream, window, pad_factor: 1, &block)
        # Uh-oh, this is starting to look like Java
        input_reader = Sound::WindowReader.new(input_stream, window, pad_factor: pad_factor)

        results = []

        loop do
          input = input_reader.read
          break if input.nil?

          if block_given?
            results << yield(input)
          else
            results << input
          end
        end

        results
      end

      # Adds overlapping chunks of audio data from the given block, applying the
      # given window (if it provides a post-processing window).  The block should
      # yield an array of NArrays with audio samples, one NArray for each channel.
      # The number of samples in each NArray must equal the window size multiplied
      # by the pad factor.
      #
      # Continues running until the block breaks the loop or an error is thrown.
      def synthesize_time_window(output_stream, window, pad_factor: 1, &block)
        window_writer = Sound::WindowWriter.new(output_stream, window, pad_factor: pad_factor)

        loop do
          window_writer.write(yield)
        end

      ensure
        # Drain the window overlap buffer to the output stream unless there was an error
        window_writer&.drain unless $!
      end

      # Like #analyze_time_window, but yields positive DFT frequencies instead of
      # time domain audio.
      def analyze_window(input_stream, window, pad_factor: 1, &block)
        analyze_time_window(input_stream, window, pad_factor: pad_factor) do |in_bufs|
          dfts = in_bufs.map { |c| real_fft(c) }
          if block_given?
            yield(dfts)
          else
            dfts
          end
        end
      end

      # Adds overlapping windows of data from the given block, using the given
      # +window+ function, and writes them to the +output_stream+.  The block
      # should yield an array of DFTs to write in overlapping windowed chunks to
      # the output stream.  The +window+ should include a post-processing window
      # (no window function will be applied otherwise).
      #
      # Continues running until the block breaks the loop or an error is thrown.
      def synthesize_window(output_stream, window, &block)
        fft_writer = Sound::FFTWriter.new(output_stream, window)

        loop do
          fft_writer.write(yield)
        end

      ensure
        # Drain the window overlap buffer to the output stream unless there was an error
        fft_writer&.drain unless $!
      end

      # Processes time domain audio in overlapping windows from the +input_stream+
      # to an +output_stream+ through a block, if given.  If a block is not given,
      # the audio is passed unaltered (apart from overlapping) from input to
      # output.
      #
      # See the .process_window function.
      def process_time_window(input_stream, output_stream, window, skip_overlap: false, pad_factor: 1, &block)
        window_writer = Sound::WindowWriter.new(output_stream, window, skip_overlap: skip_overlap, pad_factor: pad_factor)
        analyze_time_window(input_stream, window, pad_factor: 1) do |audio|
          result = block_given? ? yield(audio) : audio
          window_writer.write(result)
        end
        window_writer.drain
      end

      # Processes audio using the given +window+ function from an +input_stream+
      # that can return a requested number of frames (determined by the +window+'s
      # hop size) as an array of Numo::SFloat arrays.  Writes audio to
      # +output_stream+ as an array of Numo::SFloat.
      #
      # The hop and window size are determined by the window given.
      #
      # The +input_stream+ should provide a read method that takes a number of
      # frames as its parameter and returns an array of Numo::SFloat arrays.
      #
      # The +output_stream+ should provide a write method that takes an array of
      # Numo::SFloat arrays.
      #
      # The +block+ should return the same number of channels as expected by the
      # +output_stream+.
      #
      # If skip_overlap is true, then each hop's full window length will be
      # written to the file for analysis (this will not sound good).  If
      # skip_overlap is a positive integer, than that many samples of 0 will be
      # written between hops to make the edges clearer.
      #
      # FIXME: Getting clicks on window boundaries due to edges not going to zero.
      # Maybe need to zero pad save extra, or make position algorithms generate
      # minimum-phase filters, or apply a post-IFFT window.
      #
      # TODO: Take advantage of the fact that FFTs are circular to avoid having
      # to copy the remnant buffer data around, and just rotate the window
      # function (and read/write offsets) instead like a circular buffer.
      def process_window(input_stream, output_stream, window, skip_overlap = false, pad_factor: 1, &block)
        fft_writer = Sound::FFTWriter.new(output_stream, window, skip_overlap: skip_overlap, pad_factor: pad_factor)

        analyze_window(input_stream, window, pad_factor: pad_factor) do |dfts|
          if block_given?
            result = yield dfts # TODO define a standard parameter system with time domain, frequency domain, stream info, etc.
          else
            result = dfts
          end

          raise "Processing block returned #{result.size} channels instead of #{output_stream.channels}" unless result.size == output_stream.channels

          fft_writer.write(result)

          nil
        end

        fft_writer.drain
      end
    end
  end
end
