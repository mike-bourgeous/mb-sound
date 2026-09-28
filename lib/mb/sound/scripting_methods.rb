require_relative 'script_runner'

module MB
  module Sound
    # Helpers for standalone scripts in bin/: effects, synths, songs, and
    # general scripts.  Each parses the common options and declared
    # parameters (see ScriptRunner); effects, synths, and songs then play
    # through the background Session or render to a file.  Run any script
    # with --help to see its options.
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
      # stereo effect; -c/--input-channels overrides it); files are up- or
      # down-mixed to it.  +live_channels+ sets only the live input's
      # default channel count (2 if neither is given), so files keep their
      # channels.
      def effect_script(input_channels: nil, live_channels: nil, **params, &block)
        raise ArgumentError, 'Pass a block that turns the input into a graph' unless block
        runner(:effect, params, input_channels: input_channels, live_channels: live_channels).run_effect(&block)
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
        runner(:synth, params).run_synth(&block)
      end

      # Runs a song script: the block arranges the song on the current
      # session (#bg, #at_bar, #master, ...) with the declared parameters.
      # It plays live until it has ended (including master effects tails),
      # or with an audio file argument (or --output) renders +bars+ bars
      # (or --bars; nil until everything ends) plus the tail.
      #
      # Example:
      #     MB::Sound.song_script(bars: 8) { |p| my_song }
      def song_script(bars: nil, **params, &block)
        raise ArgumentError, 'Pass a block that arranges the song' unless block
        runner(:song, params).run_song(bars: bars, &block)
      end

      # Returns true if +file+ (pass __FILE__) is the script being run, rather
      # than loaded by another script or bin/sound.rb.  Unlike
      # `$0 == __FILE__`, it matches however the path was written (e.g. when
      # the test coverage helper requires the script by its full path).
      #
      # Example:
      #     song_script(bars: 8) { my_song } if main_script?(__FILE__)
      def main_script?(file)
        File.expand_path($0) == File.expand_path(file)
      end

      # Runs a general script (a utility, plot, file processor, benchmark,
      # etc.): parses -h/--help and the declared parameters (see
      # ScriptRunner), then calls the block with the positional arguments (an
      # Array of Strings) and the parameters.  +args+ is the number of
      # positional arguments allowed (an Integer or Range; nil for any), and
      # a different count prints the option help.
      #
      # Example:
      #     MB::Sound.script(args: 1.., channels: [nil, Integer, 'Channels to read']) { |files, p|
      #       files.each { |f| puts MB::Sound.read(f, channels: p.channels).map(&:length).inspect }
      #     }
      def script(args: nil, **params, &block)
        raise ArgumentError, 'Pass a block that runs the script' unless block
        runner(:script, params, args: args).run_script(&block)
      end

      private

      # Creates a ScriptRunner for the script calling a *_script method,
      # printing the error and option help and exiting for invalid
      # arguments.
      def runner(kind, params, **options)
        script = caller_locations(2, 1)[0]&.absolute_path || $0
        MB::U.sigquit_backtrace # Ctrl-\ prints every thread's backtrace
        ScriptRunner.new(kind, params, script: script, **options)
      rescue ScriptRunner::UsageError => e
        $stderr.puts "#{File.basename(script.to_s)}: #{e.message}\n\n"
        $stderr.puts e.help
        exit 1
      end
    end
  end
end
