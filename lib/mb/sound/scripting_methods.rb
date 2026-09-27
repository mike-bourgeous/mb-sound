require_relative 'script_runner'

module MB
  module Sound
    # Helpers for standalone scripts in bin/: effects, synths, and songs.
    # Each parses the common options and declared parameters (see
    # ScriptRunner), then plays through the background Session or renders
    # to a file.  Run any script with --help to see its options.
    module ScriptingMethods
      # Runs an effect script: the block gets the input (an audio file given
      # as the first audio argument or --input, rung out after it ends, or
      # live input) and the parameters, and returns the processed graph.
      # Multichannel inputs are bundles, so effects run on every channel.
      # A second audio argument or --output writes a file.
      #
      # Example:
      #     MB::Sound.effect_script(delay: [0.25, 'Delay seconds'], feedback: 0.5) { |input, p|
      #       input.delay(p.delay, feedback: p.feedback, dry: 1)
      #     }
      #
      # +input_channels+ sets the default input channel count (e.g. 2 for a
      # stereo effect; the -c option overrides it); files are up- or
      # down-mixed to it.
      def effect_script(input_channels: nil, **params, &block)
        raise ArgumentError, 'Pass a block that turns the input into a graph' unless block
        ScriptRunner.new(:effect, params, script: script_path, input_channels: input_channels).run_effect(&block)
      end

      # Runs a synthesizer script: the block gets the MIDI input name (a
      # MIDI file or port, or nil for live MIDI; pass it to #synth) and,
      # with two block parameters, the declared parameters, and returns the
      # graph.  An audio file argument or --output writes a file.
      #
      # Example:
      #     MB::Sound.synth_script { |input|
      #       MB::Sound.synth(input) { |midi| midi.hz.tone.ramp.at(1) * midi.env }
      #     }
      def synth_script(**params, &block)
        raise ArgumentError, 'Provide a block to accept a MIDI name and return a node graph' unless block
        ScriptRunner.new(:synth, params, script: script_path).run_synth(&block)
      end

      # Runs a song script: the block arranges the song on the current
      # session (#bg, #at_bar, #master, ...) with the declared parameters.
      # It plays live until it has ended (including master effects tails),
      # or with an audio file argument (or --output) renders +bars+ bars
      # plus the tail.
      #
      # Example:
      #     MB::Sound.song_script(bars: 8) { |p| my_song }
      def song_script(bars:, **params, &block)
        raise ArgumentError, 'Pass a block that arranges the song' unless block
        ScriptRunner.new(:song, params, script: script_path).run_song(bars: bars, &block)
      end

      private

      # The script calling a *_script method, for --help.
      def script_path
        caller_locations(2, 1)[0]&.absolute_path || $0
      end
    end
  end
end
