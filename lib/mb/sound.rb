require 'cmath'
require 'numo/narray'

begin
  require 'mb-sound-jackffi'
rescue LoadError
  # JackFFI is unavailable
end

require 'mb-math'
require 'mb-util'

require_relative 'sound/version'
require_relative 'sound/io_methods'
require_relative 'sound/plot_methods'
require_relative 'sound/playback_methods'
require_relative 'sound/fft_methods'
require_relative 'sound/gain_methods'
require_relative 'sound/window_methods'

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
    extend GainMethods
    extend WindowMethods

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
      rate ||= sound.respond_to?(:rate) ? sound.rate : 48000
      sound = any_sound_to_array(sound)
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

    # Allows retrieving a Note by name using e.g. MB::Sound::A4 (or just A4 in
    # the interactive CLI).  A new Note object is created each time to allow
    # for modifications to old Notes and changes in global tuning.
    def self.const_missing(name)
      MB::Sound::Note.new(name)
    rescue ArgumentError
      super(name)
    end
  end
end

require_relative 'sound/io_base'
require_relative 'sound/io_input'
require_relative 'sound/io_output'
require_relative 'sound/ffmpeg_input'
require_relative 'sound/ffmpeg_output'
require_relative 'sound/alsa_input'
require_relative 'sound/alsa_output'
require_relative 'sound/jack_input'
require_relative 'sound/jack_output'
require_relative 'sound/null_input'
require_relative 'sound/null_output'

require_relative 'sound/oscillator'
require_relative 'sound/tone'
require_relative 'sound/note'
require_relative 'sound/plot_output'
require_relative 'sound/filter'
require_relative 'sound/noise'
require_relative 'sound/processing_matrix'
require_relative 'sound/softest_clip'
require_relative 'sound/complex_pan'
require_relative 'sound/haas_pan'
require_relative 'sound/meter'

require_relative 'sound/window'
require_relative 'sound/window_reader'
require_relative 'sound/window_writer'
require_relative 'sound/fft_writer'
require_relative 'sound/multi_writer'

require_relative 'sound/midi'
require_relative 'sound/adsr_envelope'
require_relative 'sound/timeline_interpolator'
