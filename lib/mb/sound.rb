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
    # channel.
    #
    # See MB::Sound::FFMPEGInput for more flexible sound input.
    def self.read(filename, max_frames: nil)
      input = MB::Sound::FFMPEGInput.new(filename)
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

    # Converts a Ruby Array of any nesting depth to a Numo::NArray with a
    # matching number of dimensions.  All nested arrays at a particular depth
    # should have the same size (that is, all positions should be filled).
    #
    # Chained subscripts on the Array become comma-separated subscripts on the
    # NArray, so array[1][2] would become narray[1, 2].
    def self.array_to_narray(array)
      return array if array.is_a?(Numo::NArray)
      narray = Numo::NArray[array]
      narray.reshape(*narray.shape[1..-1])
    end
  end
end

require_relative 'sound/io_input'
require_relative 'sound/io_output'
require_relative 'sound/ffmpeg_input'
require_relative 'sound/ffmpeg_output'
require_relative 'sound/alsa_input'
require_relative 'sound/alsa_output'
