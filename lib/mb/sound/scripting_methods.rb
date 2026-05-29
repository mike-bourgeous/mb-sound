require 'optionparser'

module MB
  module Sound
    # Helpers for standalone scripts/synths/effects/etc.
    module ScriptingMethods
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
        }

        OptionParser.new { |p|
          # TODO: allow the script to add more options
          p.on('-i', '--input MIDI_FILE_OR_JACK_PORT', String, 'A MIDI file to process, or a Jack port to connect for MIDI events')
          p.on('-o', '--output AUDIO_FILE', String, 'An audio file to write output to (default is soundcard output)')
          p.on('-f', '--force', TrueClass, 'Whether to overwrite an existing output file')
          p.on('--graphviz', TrueClass, 'If true, opens a visualization of the node graph')
        }.parse!(into: options)

        ARGV.each do |a|
          case a
          when /.(flac|wav|mp3|ogg|mp4|m4a|opus)$/i
            options[:output] ||= a

          when /^-/
            puts "Option parser left a flag??? #{a.inspect}" # XXX

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
          MB::Sound.play(graph)
        end
      end
    end
  end
end
