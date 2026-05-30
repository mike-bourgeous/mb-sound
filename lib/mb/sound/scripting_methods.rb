require 'optionparser'

module MB
  module Sound
    # Helpers for standalone scripts/synths/effects/etc.
    module ScriptingMethods
      # TODO: for an effect script, we'd want audio input, audio output, and
      # possibly midi input for control, all of which should be selectable
      # between files and realtime i/o.

      # Parses options and arguments from ARGV to set up MIDI input and audio
      # output for a synthesizer script.  Yields input name to the block.  The
      # block should return a node graph.
      def synth_script
        raise 'Provide a block to accept a MIDI name and return a node graph' unless block_given?

        # TODO: support dropping into pry within the playback loop
        MB::U.sigquit_backtrace

        options = {
          input: nil,
          output: nil,
          force: false,
          graphviz: false,
          quiet: false,
        }

        OptionParser.new { |p|
          # TODO: allow the script to add more options
          p.on('-i', '--input MIDI_FILE_OR_JACK_PORT', String, 'A MIDI file to process, or a Jack port to connect for MIDI events')
          p.on('-o', '--output AUDIO_FILE', String, 'An audio file to write output to (default is soundcard output)')
          p.on('-f', '--force', TrueClass, 'Whether to overwrite an existing output file')
          p.on('--graphviz', TrueClass, 'If true, opens a visualization of the node graph')
          p.on('-q', '--quiet', TrueClass, 'Disable waveform plotting')
        }.parse!(into: options)

        ARGV.each do |a|
          case a
          when /.(flac|wav|mp3|ogg|mp4|m4a|opus)$/i
            options[:output] ||= a

          else
            options[:input] ||= a
          end
        end

        graph = yield options[:input]

        if options[:graphviz]
          graph.open_graphviz
        end

        if options[:output]
          MB::Sound.write(options[:output], graph, overwrite: options[:force] || :prompt)
        else
          # FIXME: text console plots constantly scroll
          MB::Sound.play(graph, plot: !options[:quiet])
        end
      end
    end
  end
end
