require 'cmath'
require 'numo/narray'

require_relative 'sound/version'

module MB
  # Convenience functions for making quick work of sound.
  #
  # Top-level namespace for the mb-sound library.
  module Sound
    class FileExistsError < IOError; end

    # Reads an entire sound file into an array of Numo::NArrays, one per
    # channel.  Always resamples to 48kHz.
    #
    # See MB::Sound::FFMPEGInput for more flexible sound input.
    def self.read(filename, max_frames: nil)
      input = MB::Sound::FFMPEGInput.new(filename, resample: 48000)
      input.read(max_frames || input.frames)
    ensure
      input&.close
    end

    # Writes an Array of Numo::NArrays into the given sound file.  If the sound
    # file already exists and +:overwrite+ is false, an error will be raised.
    #
    # See MB::Sound::FFMPEGOutput for more flexible sound output.
    def self.write(filename, data, rate:, overwrite: false)
      if !overwrite && File.exist?(filename)
        raise FileExistsError, "#{filename.inspect} already exists"
      end

      output = MB::Sound::FFMPEGOutput.new(filename, rate: rate, channels: data.length)
      output.write(data)
    ensure
      output&.close
    end

    # Plays a sound file if a String is given, a generated tone if a Tone is
    # given, or an audio buffer if an audio buffer is given.  If an audio
    # buffer or tone is given, the sample rate should be specified (defaults to
    # 48k).  The sample rate is ignored for an audio filename.
    def self.play(file_tone_data, rate: 48000, gain: 1.0)
      puts "\e[36mPlaying\e[0m #{MB::Sound::U.highlight(file_tone_data)}"

      # TODO: Allow plotting while playing
      case file_tone_data
      when String
        return play_file(file_tone_data, gain: gain)

      when Array
        data = file_tone_data
        channels = data.length < 2 ? 2 : data.length
        data = data * 2 if data.length < 2
        output = MB::Sound.output(rate: rate, channels: channels)
        output.write(data)

      when Tone
        output = MB::Sound.output(rate: rate)
        file_tone_data.write(output)

      else
        raise "Unsupported type #{file_tone_data.class.name} for playback"
      end
    ensure
      output&.close
    end

    # Plays the given filename using the default audio output returned by
    # MB::Sound.output.  The +:channels+ parameter may be used to force mono
    # playback (mono sound is converted to stereo by default), or to ask ffmpeg
    # to upmix or downmix audio to a different number of channels.
    def self.play_file(filename, channels: nil, gain: 1.0)
      input = MB::Sound::FFMPEGInput.new(filename, channels: channels)
      output = MB::Sound.output(channels: channels || (input.channels < 2 ? 2 : input.channels))

      # TODO: Move the loop to a processing helper method when those are added
      loop do
        data = input.read(1000)
        break if data.nil? || data.empty? || data[0].empty?

        data.map { |d|
          d.inplace * gain
        }

        # Ensure the output is at least stereo (Pulseaudio plays nothing for
        # mono output on my system)
        data = data * 2 if data.length == 1 && channels.nil?

        output.write(data)
      end

    ensure
      input&.close
      output&.close
    end

    # Tries to auto-detect an input device for recording sound.  Returns a
    # sound input stream with a :read method.
    #
    # For input types that support naming a specific device, the INPUT_DEVICE
    # environment variable, the DEVICE environment variable, or the +:device+
    # parameter may be used to override the default.  Environment variables
    # take precedence.
    #
    # See FFMPEGInput and AlsaInput for more flexible recording.
    def self.input(rate: 48000, channels: 2, device: nil, buffer_size: nil)
      case RUBY_PLATFORM
      when /linux/
        if device
          MB::Sound::AlsaInput.new(device: device, rate: rate, channels: channels, buffer_size: buffer_size)
        elsif `pgrep pulseaudio`.strip.length > 0
          MB::Sound::AlsaInput.new(device: 'pulse', rate: rate, channels: channels, buffer_size: buffer_size)
        else
          MB::Sound::AlsaInput.new(device: 'default', rate: rate, channels: channels, buffer_size: buffer_size)
        end

      else
        raise NotImplementedError, 'TODO: support other platforms'
      end
    end

    # Tries to auto-detect an output device for playing sound.  Returns a sound
    # output stream with a :write method.
    #
    # For output types that support naming a specific device, the OUTPUT_DEVICE
    # environment variable, the DEVICE environment variable or +:device+
    # parameter may be used to override the default.  Environment variables
    # take precedence.
    #
    # See FFMPEGOutput and AlsaOutput for more flexible playback.
    def self.output(rate: 48000, channels: 2, device: nil, buffer_size: nil)
      case RUBY_PLATFORM
      when /linux/
        if device
          MB::Sound::AlsaOutput.new(device: device, rate: rate, channels: channels, buffer_size: buffer_size)
        elsif `pgrep pulseaudio`.strip.length > 0
          MB::Sound::AlsaOutput.new(device: 'pulse', rate: rate, channels: channels, buffer_size: buffer_size)
        else
          MB::Sound::AlsaOutput.new(device: 'default', rate: rate, channels: channels, buffer_size: buffer_size)
        end

      else
        raise NotImplementedError, 'TODO: support other platforms'
      end
    end

    # Endlessly streams audio in non-overlapping +:block_size+ chunks from
    # MB::Sound.input to MB::Sound.output.
    #
    # If a block is given, the audio read will be yielded to the block as an
    # Array of Numo::NArrays.
    #
    # Press Ctrl-C to interrupt, or call break in the block.
    def self.loopback(rate: 48000, channels: 2, block_size: 512)
      inp = input(rate: rate, channels: channels, buffer_size: block_size)
      outp = output(rate: rate, channels: channels, buffer_size: block_size)
      loop do
        data = inp.read(block_size)
        data = yield data if block_given?
        outp.write(data)
      end
    ensure
      inp&.close
      outp&.close
    end

    # Plots a subset of the given audio file, test tone, or data, starting at
    # +offset+, and plotting the following +samples+ samples.  If +all+ is true
    # then the entirety of the file, tone, or data will be plotted.
    def self.plot(file_tone_data, samples: 960, offset: 0, all: false)
      STDOUT.write("\e[H\e[2J") if all == true

      if all == true || all == false
        header = "\e[36mPlotting #{MB::Sound::U.highlight(file_tone_data)}\e[0m"
        header_lines = header.lines.count
        puts header
      elsif all.is_a?(Numeric)
        header_lines = all
      end

      # TODO: Allow plotting audio input in realtime
      case file_tone_data
      when Array || Numo::NArray
        data = file_tone_data
        if data.is_a?(Array) && !data[0].is_a?(Numo::NArray)
          data = [data]
        end

      when String
        # TODO: Read speaker names
        data = read(file_tone_data, max_frames: all ? nil : samples + offset)

      when Tone
        data = [file_tone_data.generate(all ? nil : samples + offset)]

      else
        raise "Cannot plot type #{file_tone_data.class.name}"
      end

      @p ||= MB::Sound::Plot.terminal(height_fraction: 0.8)

      if all == true
        t = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        until offset >= data[0].length
          STDOUT.write("\e[#{header_lines}H\e[36mPress Ctrl-C to stop  \e[1;35m#{offset} / #{data[0].length}\e[0m\e[K\n")
          @p.yrange(data.map(&:min).min, data.map(&:max).max) unless all.nil?
          plot(data, samples: samples, offset: offset, all: nil)

          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          elapsed = [now - t, 0.1].min
          t = now

          offset += elapsed * 48000

          STDOUT.flush
          sleep 0.02
        end
      else
        data = data.map { |c| c[offset...([offset + samples, c.length].min)] || [] }

        @p.yrange(data.map(&:min).min, data.map(&:max).max) unless all.nil?
        @lines = @p.plot(data.map.with_index { |c, idx| [idx.to_s, c] }.to_h, print: false)
        puts @lines
      end

      nil
    ensure
      puts "\e[#{@p.height + (header_lines || 2) + 2}H" if all == true
    end
  end
end

require_relative 'sound/u'
require_relative 'sound/m'
require_relative 'sound/io_input'
require_relative 'sound/io_output'
require_relative 'sound/ffmpeg_input'
require_relative 'sound/ffmpeg_output'
require_relative 'sound/alsa_input'
require_relative 'sound/alsa_output'
require_relative 'sound/oscillator'
require_relative 'sound/tone'
require_relative 'sound/plot'
