require 'cmath'
require 'numo/narray'

require_relative 'sound/version'

module MB
  # Convenience functions for making quick work of sound.
  #
  # Top-level namespace for the mb-sound library.
  module Sound
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
