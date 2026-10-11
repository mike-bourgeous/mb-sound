require 'cmath'
require 'numo/narray'

require 'mb-math'
require 'mb-util'

# RANDOM_SEED makes random sounds repeatable (e.g. for bin/null_test.rb):
# Kernel#rand here, and the root seed (RandomMethods), which Tone#rnd,
# Tone#noise, and spectral Noise draw from.
srand(Integer(ENV['RANDOM_SEED'])) if ENV['RANDOM_SEED']

require_relative 'sound/length'
require_relative 'sound/interval'
require_relative 'sound/phase'
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
require_relative 'sound/fast_resonator'
require_relative 'sound/fast_reverb'
require_relative 'sound/fast_unison'
require_relative 'sound/fast_control'
require_relative 'sound/fast_loudness'
require_relative 'sound/fast_dynamics'
require_relative 'sound/fast_lofi'
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
require_relative 'sound/arrangement_methods'
require_relative 'sound/form_methods'
require_relative 'sound/knob_methods'
require_relative 'sound/record_methods'
require_relative 'sound/multichannel_methods'
require_relative 'sound/warm_up_methods'
require_relative 'sound/envelope_methods'
require_relative 'sound/mod_methods'
require_relative 'sound/random_methods'
require_relative 'sound/live_methods'
require_relative 'sound/drum_methods'

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
    extend ArrangementMethods
    extend FormMethods
    extend KnobMethods
    extend RecordMethods
    extend MultichannelMethods
    extend TuningMethods
    extend WarmUpMethods
    extend EnvelopeMethods
    extend ModMethods
    extend RandomMethods
    extend LiveMethods
    extend DrumMethods

    # Speed of sound for wavelength calculations, in meters per second.
    SPEED_OF_SOUND = 343.0

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
require_relative 'sound/plan'
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
require_relative 'sound/scale'
require_relative 'sound/sequence'
require_relative 'sound/midi/streams'
require_relative 'sound/notes'
require_relative 'sound/synth'
require_relative 'sound/drums'
require_relative 'sound/session'
require_relative 'sound/take'
require_relative 'sound/arrangement/recording'
require_relative 'sound/arrangement'
require_relative 'sound/form'

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

# Records the DSL calls that build graphs (GraphNode#to_ruby); loads last so
# every DSL method exists
require_relative 'sound/graph_node/recipe'
MB::Sound::GraphNode::Recipe.install!
require_relative 'sound/graph_io'
