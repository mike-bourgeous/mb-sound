require 'optparse'

module MB
  module Sound
    # Runs standalone scripts in bin/ (effects, synths, and songs; see
    # ScriptingMethods): parses command-line options and declared parameters,
    # chooses file or live input and output, and plays everything through a
    # Session, so every script gets master effects, tail handling, and
    # multichannel graphs.
    #
    # Common options for every script:
    #     -h, --help               the script's header comment plus the options
    #     -o, --output FILE        write to an audio file instead of playing
    #     -f, --force              overwrite the output file (alias --overwrite)
    #     -g, --graphviz           open a visualization of the node graph
    #     -p, --plot               plot the output while playing live
    #     -q, --quiet              don't print the parameters
    #
    # Parameters are declared with defaults (and optional descriptions):
    #
    #     effect_script(delay: 0.25, feedback: [0.5, 'Feedback gain']) { |input, p| ... }
    #
    # Each becomes a --name option (--delay 0.3 or --delay=-0.3; true/false
    # defaults become --name/--no-name switches).  The block's +p+ has a
    # method per parameter (p.delay).
    class ScriptRunner
      # Audio file extensions recognized in positional arguments.
      AUDIO_EXTENSIONS = /\.(flac|wav|mp3|ogg|mp4|m4a|opus|aiff?)\z/i

      # A declared parameter.
      Param = Struct.new(:name, :default, :description)

      # Raised for invalid command-line arguments.  #help has the option
      # list, which ScriptingMethods prints before exiting.
      class UsageError < ArgumentError
        # The option help text.
        attr_reader :help

        def initialize(message, help)
          super(message)
          @help = help
        end
      end

      # Parameter values given to script blocks, with a method per parameter.
      class Values
        def initialize(values)
          @values = values
          values.each_key do |k|
            define_singleton_method(k) { @values[k] }
          end
        end

        # Returns the value of parameter +name+.
        def [](name)
          @values.fetch(name.to_sym)
        end

        # The parameter values as a Hash.
        def to_h
          @values.dup
        end
      end

      # The kind of script: :effect, :synth, or :song.
      attr_reader :kind

      # Parsed common options (:input, :output, :force, :graphviz, :plot,
      # :quiet, plus :channels for effects).
      attr_reader :options

      # The parameter values (see Values).
      attr_reader :params

      # Creates a runner for a script of +kind+ with +params+ declared as
      # {name => default} or {name => [default, 'description']}, parsing
      # +argv+ (which is modified) and printing help for +script+.
      def initialize(kind, params = {}, argv: ARGV, script: $0, input_channels: nil)
        raise ArgumentError, "Unknown script kind #{kind.inspect}" unless [:effect, :synth, :song].include?(kind)

        @kind = kind
        @script = script
        @input_channels = input_channels
        @declared = params.map { |name, spec|
          default, description = spec.is_a?(Array) ? spec : [spec, nil]
          Param.new(name.to_sym, default, description)
        }
        parse(argv)
      end

      # Runs an effect: builds the graph with the block from the input (a
      # file given as the first audio argument or --input, or live audio
      # with --channels channels) and the parameters, then plays or renders
      # it.  A file input rings out: after it ends, the effect keeps playing
      # until its output has been quiet for Session::TAIL_QUIET_SECONDS.
      def run_effect(&block)
        path = @options[:input]
        input = if path
                  MB::Sound.file_input(path, channels: @options[:channels]).ringdown
                else
                  MB::Sound.input(channels: @options[:channels] || 2)
                end

        graph = block.call(input, @params)
        announce(graph)

        ringdowns = graph_nodes(graph).grep(GraphNode::Ringdown)
        play_or_render(graph) do |session|
          stop_after_ringdown(session, ringdowns) unless ringdowns.empty?
        end
      end

      # Runs a synth: builds the graph with the block from the MIDI input
      # name (a MIDI file or port given as a non-audio argument or --input;
      # nil for the default live input) and the parameters, then plays or
      # renders it.
      def run_synth(&block)
        graph = block.arity == 1 ? block.call(@options[:input]) : block.call(@options[:input], @params)
        announce(graph)
        play_or_render(graph)
      end

      # Runs a song: the block arranges it on the current session (with #bg,
      # #at_bar, etc.), then it plays live until it ends (see
      # PlaybackMethods#wait), or renders +bars+ bars plus the master tail to
      # the output file.  --graphviz draws the graph as it is at the start
      # (players started later by #at_bar are missing).
      def run_song(bars:, &block)
        print_params
        open_song_graphviz(&block) if @options[:graphviz]

        if @options[:output]
          seconds = MB::Sound.render(@options[:output], bars: bars, tail: true, overwrite: overwrite) { block.call(@params) }
          puts "Rendered #{seconds.round(1)} seconds to #{@options[:output]}"
        else
          block.call(@params)
          live
        end
      end

      private

      # Parses +argv+ into @options and @params.
      def parse(argv)
        @options = { input: nil, output: nil, force: false, graphviz: false, plot: false, quiet: false, channels: @input_channels }
        values = @declared.to_h { |p| [p.name, p.default] }

        @parser = parser = OptionParser.new { |o|
          o.banner = "Options for #{File.basename(@script)}:"
          o.on('-o', '--output FILE', 'Write to an audio file instead of playing') { |v| @options[:output] = v }
          o.on('-f', '--force', '--overwrite', 'Overwrite the output file') { @options[:force] = true }
          o.on('-g', '--graphviz', 'Open a visualization of the node graph') { @options[:graphviz] = true }
          o.on('-p', '--plot', 'Plot the output while playing live') { @options[:plot] = true }
          o.on('-q', '--quiet', "Don't print the parameters") { @options[:quiet] = true }

          case @kind
          when :effect
            o.on('-i', '--input FILE', 'An audio file to process (default: live input)') { |v| @options[:input] = v }
            o.on('-c', '--channels N', Integer, 'Input channels (live input, or to up/downmix a file)') { |v| @options[:channels] = v }
          when :synth
            o.on('-i', '--input MIDI', 'A MIDI file, or a MIDI port name (default: live MIDI)') { |v| @options[:input] = v }
          end

          @declared.each do |p|
            desc = [p.description, "(default #{p.default.inspect})"].compact.join(' ')
            if p.default == true || p.default == false
              o.on("--[no-]#{option_name(p)}", desc) { |v| values[p.name] = v }
            else
              o.on("--#{option_name(p)} VALUE", desc) { |v| values[p.name] = convert(p, v) }
            end
          end

          o.on('-h', '--help', 'Show this help') do
            MB::U.print_header_help(@script) if File.exist?(@script.to_s)
            puts o
            exit 0
          end
        }

        begin
          rest = parser.parse(argv)
        rescue OptionParser::ParseError => e
          raise UsageError.new(e.message, parser.to_s)
        end
        positional(rest)
        @params = Values.new(values)
      end

      # Assigns positional filenames to input and output by script kind.
      def positional(args)
        args.each do |a|
          if @kind == :effect && a.match?(AUDIO_EXTENSIONS)
            @options[:input] ? (@options[:output] ||= a) : (@options[:input] = a)
          elsif a.match?(AUDIO_EXTENSIONS)
            @options[:output] ||= a
          elsif @kind == :synth
            @options[:input] ||= a
          else
            hint = @declared.empty? ? '' : "; parameters are options, e.g. --#{option_name(@declared.first)} #{a}"
            raise UsageError.new("Unexpected argument #{a.inspect}#{hint}", @parser.to_s)
          end
        end
      end

      # The --option name of a parameter (underscores become dashes).
      def option_name(param)
        param.name.to_s.tr('_', '-')
      end

      # Converts a command-line String to the type of +param+'s default.
      def convert(param, str)
        case param.default
        when Integer then str.include?('.') ? Float(str) : Integer(str)
        when Float, Rational then Float(str)
        when Symbol then str.to_sym
        else str
        end
      end

      # The overwrite setting for output files.
      def overwrite
        @options[:force] ? true : :prompt
      end

      # Prints the parameters (unless --quiet) and opens the graph
      # visualization (with --graphviz).
      def announce(graph)
        print_params
        if @options[:graphviz]
          png = graph.open_graphviz
          puts "Wrote GraphViz image to #{png}"
        end
      end

      # Arranges the song with +block+ on a silent session that never plays,
      # and opens a drawing of the graph as it is at the start (see
      # Session#graph_view).
      def open_song_graphviz(&block)
        output = NullOutput.new(channels: 2, sleep: false)
        transport = Sequence::Transport.new(bpm: Sequence.transport.bpm, bar_length: Sequence.transport.bar_length)
        session = Session.new(output: output, transport: transport, realtime: false)
        Session.with_context(session: session) { block.call(@params) }
        png = session.graph_view.open_graphviz
        puts "Wrote GraphViz image to #{png}"
      ensure
        session&.close
      end

      def print_params
        return if @options[:quiet]
        shown = @params.to_h
        shown[:input] = @options[:input] || 'live' unless @kind == :song
        shown[:output] = @options[:output] || 'sound card'
        puts MB::U.highlight(shown)
      end

      # Every node in +graph+ (a node or bundle).
      def graph_nodes(graph)
        [graph, *graph.outputs, *graph.graph]
      end

      # Plays +graph+ live, or renders it to the output file (with as many
      # channels as the graph), calling the block with the session after the
      # graph is added.
      def play_or_render(graph)
        if @options[:output]
          seconds = MB::Sound.render(@options[:output], channels: graph.channel_count, overwrite: overwrite) do
            MB::Sound.bg(:script, graph, fade: 0)
            yield Session.current if block_given?
          end
          puts "Rendered #{seconds.round(1)} seconds to #{@options[:output]}"
        else
          MB::Sound.bg(:script, graph, fade: 0)
          yield Session.current if block_given?
          live
        end
      end

      # Waits for live playback to end (or Ctrl-C), plotting with --plot.
      def live
        puts 'Playing (Ctrl-C to stop)' unless @options[:quiet]
        MB::Sound.visualize if @options[:plot]
        MB::Sound.wait
      rescue Interrupt
        puts
      end

      # Stops the script's player once every Ringdown in the graph has ended
      # and the mix has been quiet for Session::TAIL_QUIET_SECONDS, or fades
      # it out over Session::TAIL_FADE_SECONDS after Session::MAX_TAIL_SECONDS
      # of tail.
      def stop_after_ringdown(session, ringdowns)
        rate = session.output.sample_rate
        quiet = 0
        tail = 0
        tap = nil
        tap = session.add_tap { |mix|
          next unless ringdowns.all?(&:ended?)
          tail += mix[0].length
          quiet = session.quiet?(mix) ? quiet + mix[0].length : 0
          if quiet >= Session::TAIL_QUIET_SECONDS * rate
            session.remove(:script, fade: 0)
            session.remove_tap(tap)
          elsif tail >= Session::MAX_TAIL_SECONDS * rate
            t = session.transport
            session.remove(:script, fade: Session::TAIL_FADE_SECONDS / t.seconds(t.bar_length))
            session.remove_tap(tap)
          end
        }
      end
    end
  end
end
