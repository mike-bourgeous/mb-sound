require 'cmath'
require 'numo/narray'

require 'mb-math'
require 'mb-util'

# RANDOM_SEED makes random sounds repeatable (e.g. for bin/null_test.rb):
# Kernel#rand here, Noise::RAND below, and the root seed (RandomMethods),
# which Tone#rnd and Tone#noise draw their seeds from.
srand(Integer(ENV['RANDOM_SEED'])) if ENV['RANDOM_SEED']

require_relative 'sound/length'
require_relative 'sound/interval'
require_relative 'sound/curve'
require_relative 'sound/numeric_sound_mixins'

# Load C extensions
require_relative 'fast_sound'
require_relative 'sound/fast_resample'
require_relative 'sound/fast_wavetable'
require_relative 'sound/fast_delay'
require_relative 'sound/fast_synth'
require_relative 'sound/fast_clip'
require_relative 'sound/fast_arithmetic'
require_relative 'sound/fast_envelope'
require_relative 'sound/fast_filter'
require_relative 'sound/fast_unison'
require_relative 'sound/fast_loudness'
require_relative 'sound/fast_audio'
require_relative 'sound/fast_midi'

require_relative 'sound/version'
require_relative 'sound/tuning'
require_relative 'sound/io_methods'
require_relative 'sound/plot_methods'
require_relative 'sound/playback_methods'
require_relative 'sound/fft_methods'
require_relative 'sound/gain_methods'
require_relative 'sound/window_methods'
require_relative 'sound/analysis_methods'
require_relative 'sound/generation_methods'
require_relative 'sound/midi_methods'
require_relative 'sound/scripting_methods'
require_relative 'sound/sequence_methods'
require_relative 'sound/schedule_methods'
require_relative 'sound/multichannel_methods'
require_relative 'sound/warm_up_methods'
require_relative 'sound/envelope_methods'
require_relative 'sound/mod_methods'
require_relative 'sound/random_methods'
require_relative 'sound/live_methods'

module MB
  # Convenience functions for making quick work of sound.
  #
  # Top-level namespace for the mb-sound library.
  module Sound
    # Most of the methods available in the CLI are defined in these separate
    # modules and incorporated here by extension.
    extend IOMethods
    extend PlotMethods
    extend PlaybackMethods
    extend FFTMethods
    extend GainMethods
    extend WindowMethods
    extend AnalysisMethods
    extend GenerationMethods
    extend MidiMethods
    extend ScriptingMethods
    extend SequenceMethods
    extend ScheduleMethods
    extend MultichannelMethods
    extend TuningMethods
    extend WarmUpMethods
    extend EnvelopeMethods
    extend ModMethods
    extend RandomMethods
    extend LiveMethods

    # Speed of sound for wavelength calculations, in meters per second.
    SPEED_OF_SOUND = 343.0

    # Filters a sound with the given filter parameters (see
    # MB::Sound::Filter::Cookbook).
    #
    # TODO: Maybe remove this, as it is superseded by the GraphNode DSL.
    #
    # +:frequency+ - The center or cutoff frequency of the filter.
    # +:filter_type+ - One of the filter types from MB::Sound::Filter::Cookbook::FILTER_TYPES.
    # +:sample_rate+ - The sample rate to use for the filter (defaults to
    #                  sound.sample_rate if sound responds to :sample_rate, or 48000).
    # +:quality+ - The "quality factor" of the filter.  Higher values are more
    #              resonant.  Must specify one of quality, slope, or bandwidth.
    # +:slope+ - The slope for a shelf filter.  Specify one of quality, slope, or bandwidth.
    # +:bandwidth+ - The bandwidth of a peaking filter.
    # +:gain+ - The gain of a shelf or peaking filter.
    def self.apply_filter(sound, frequency:, filter_type: :lowpass, sample_rate: nil, quality: nil, slope: nil, bandwidth: nil, gain: nil)
      # TODO: Further develop filters and sound sources into a sound
      # source/sink graph, where a complete graph can be built up with a DSL,
      # and actual generation only occurs on demand?
      sample_rate ||= sound.respond_to?(:sample_rate) ? sound.sample_rate : 48000
      sound = any_sound_to_array(sound)
      frequency = frequency.frequency if frequency.respond_to?(:frequency) # get 343 from 343.hz
      filter = MB::Sound::Filter::Cookbook.new(
        filter_type,
        sample_rate,
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
      super if !defined?(MB::Sound::Note) || name.to_s == 'Note'
      MB::Sound::Note.new(name)
    rescue ArgumentError
      super
    end
  end

  # S is a shortcut for Sound
  S = Sound
end

require_relative 'sound/buffer_helper'
require_relative 'sound/circular_buffer'
require_relative 'sound/delay_line'
require_relative 'sound/wavetable'
require_relative 'sound/graph_node'
require_relative 'sound/envelope'
require_relative 'sound/sq80'
require_relative 'sound/graph_node_input'

require_relative 'sound/midi'
require_relative 'sound/timeline_interpolator'

require_relative 'sound/io_base'
require_relative 'sound/io_input'
require_relative 'sound/io_output'
require_relative 'sound/ffmpeg_input'
require_relative 'sound/ffmpeg_output'
require_relative 'sound/null_input'
require_relative 'sound/null_output'
require_relative 'sound/device_output'
require_relative 'sound/jack'
require_relative 'sound/device_input'
require_relative 'sound/loopback'
require_relative 'sound/array_input'
require_relative 'sound/input_buffer_wrapper'
require_relative 'sound/output_buffer_wrapper'
require_relative 'sound/background_output'

require_relative 'sound/band_limit'
require_relative 'sound/tone/state'
require_relative 'sound/tone'
require_relative 'sound/pitch'
require_relative 'sound/note'
require_relative 'sound/sequence'
require_relative 'sound/midi/streams'
require_relative 'sound/notes'
require_relative 'sound/synth'
require_relative 'sound/session'

require_relative 'sound/plot_output'
require_relative 'sound/filter'
require_relative 'sound/loudness'
require_relative 'sound/noise'
require_relative 'sound/processing_matrix'
require_relative 'sound/softest_clip'
require_relative 'sound/shaper'
require_relative 'sound/haas_pan'
require_relative 'sound/meter'

require_relative 'sound/window'
require_relative 'sound/window_reader'
require_relative 'sound/window_writer'
require_relative 'sound/fft_writer'
require_relative 'sound/multi_writer'
require_relative 'sound/process_reader'

require_relative 'sound/io_logger'
