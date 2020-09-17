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
    def self.read(filename)
      input = MB::Sound::FFMPEGInput.new(filename)
      input.read(input.frames)
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
