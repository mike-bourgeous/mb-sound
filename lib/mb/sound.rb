require 'cmath'
require 'numo/narray'

begin
  require 'mb-sound-jackffi'
rescue LoadError
  # JackFFI is unavailable
end

require_relative 'sound/version'
require_relative 'sound/io_methods'
require_relative 'sound/plot_methods'
require_relative 'sound/playback_methods'
require_relative 'sound/fft_methods'

module MB
  # Convenience functions for making quick work of sound.
  #
  # Top-level namespace for the mb-sound library.
  module Sound
    class FileExistsError < IOError; end

    # Most of the methods available in the CLI are defined in these separate
    # modules and incorporated here by extension.
    extend IOMethods
    extend PlotMethods
    extend PlaybackMethods
    extend FFTMethods

    # Returns the current time from the system's monotonically increasing
    # clock.  A shorthand for Process.clock_gettime(Process::CLOCK_MONOTONIC).
    def self.clock_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Filters a sound with the given filter parameters (see
    # MB::Sound::Filter::Cookbook).
    #
    # +:frequency+ - The center or cutoff frequency of the filter.
    # +:filter_type+ - One of the filter types from MB::Sound::Filter::Cookbook::FILTER_TYPES.
    # +:rate+ - The sample rate to use for the filter (defaults to sound.rate if sound responds to :rate, or 48000).
    # +:quality+ - The "quality factor" of the filter.  Higher values are more
    #              resonant.  Must specify one of quality, slope, or bandwidth.
    # +:slope+ - The slope for a shelf filter.  Specify one of quality, slope, or bandwidth.
    # +:bandwidth+ - The bandwidth of a peaking filter.
    # +:gain+ - The gain of a shelf or peaking filter.
    def self.filter(sound, frequency:, filter_type: :lowpass, rate: nil, quality: nil, slope: nil, bandwidth: nil, gain: nil)
      # TODO: Further develop filters and sound sources into a sound
      # source/sink graph, where a complete graph can be built up with a DSL,
      # and actual generation only occurs on demand?
      sound = any_sound_to_array(sound)
      rate ||= sound.respond_to?(:rate) ? sound.rate : 48000
      frequency = frequency.frequency if frequency.respond_to?(:frequency) # get 343 from 343.hz
      filter = MB::Sound::Filter::Cookbook.new(
        filter_type,
        rate,
        frequency,
        db_gain: gain&.to_db,
        quality: quality,
        bandwidth_oct: bandwidth,
        shelf_slope: slope,
      )
      sound.map { |c|
        filter.reset(c[0])
        filter.process(c)
      }
    end

    # Silly experiment for retrieving notes by name as ruby constants.
    def self.const_missing(name)
      MB::Sound::Note.new(name)
    rescue ArgumentError
      super(name)
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
require_relative 'sound/jack_input'
require_relative 'sound/jack_output'
require_relative 'sound/oscillator'
require_relative 'sound/tone'
require_relative 'sound/note'
require_relative 'sound/plot'
require_relative 'sound/plot_output'
require_relative 'sound/filter'
