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
    # Effects add -i/--input FILE, -c/--input-channels N, and --repeat
    # [COUNT]; synths add -i/--input MIDI; songs add -b/--bars N and
    # --bpm BPM.
    #
    # Parameters are declared with defaults (and optional descriptions):
    #
    #     effect_script(delay: 0.25, feedback: [0.5, 'Feedback gain']) { |input, p| ... }
    #
    # Each becomes a --name option (--delay 0.3 or --delay=-0.3; true/false
    # defaults become --name/--no-name switches).  The block's +p+ has a
    # method per parameter (p.delay).
    #
    # After the default, a parameter's Array may also list, in any order:
    # - a description String
    # - a short option like '-w' (not one of the common options above)
    # - a type (Integer, Float, String, Symbol, or a Proc that converts the
    #   String), needed for nil defaults; otherwise the default's type
    # - allowed values: a Range or an Array, checked after conversion
    #
    #     count: [2, 'Repeats per grain', 2.., '-n'],
    #     wave: [:sine, 'LFO waveform', MB::Sound::Oscillator::WAVE_TYPES],
    #     preset: [nil, 'Reverb preset', Symbol],
    class ScriptRunner
      # Audio file extensions recognized in positional arguments.
      AUDIO_EXTENSIONS = /\.(flac|wav|mp3|ogg|mp4|m4a|opus|aiff?)\z/i

      # A declared parameter (see the class comment).
      Param = Struct.new(:name, :default, :description, :short, :type, :allowed)

      # Short options used by every script of a kind, which parameters can't
      # use.
      COMMON_SHORT_OPTIONS = {
        effect: %w[-o -f -g -p -q -h -i -c],
        synth: %w[-o -f -g -p -q -h -i],
        song: %w[-o -f -g -p -q -h -b],
      }.freeze

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

        # Returns a node for parameter +name+ that MIDI CC +number+ controls
        # over +range+, starting at the parameter's value: a MidiDsl CC node
        # when live MIDI is available (JACK is running) and the script isn't
        # writing a file, otherwise a constant.  Both are named after the
        # parameter.
        #
        # Like MIDI::GraphVoice#on_cc, the +range+ multiplies the parameter's
        # value unless +:relative+ is false (then it's an absolute range).
        #
        # Example:
        #     lfo_hz = p.midi_cc(1, :hz, range: 0.0..6.0) # 0 to 6 times --hz
        def midi_cc(number, name, range:, relative: true)
          value = self[name]
          range = (value * range.begin)..(value * range.end) if relative
          node = @midi&.call&.cc(number, range: range, default: value) || value.constant
          node.named(name.to_s)
        end

        # For internal use by ScriptRunner: sets a Proc that returns a
        # MidiDsl, or nil when MIDI isn't available.
        def midi_source=(source)
          @midi = source
        end
      end

      # The kind of script: :effect, :synth, or :song.
      attr_reader :kind

      # Parsed common options (:input, :output, :force, :graphviz, :plot,
      # :quiet, plus :channels for effects and :bars for songs).
      attr_reader :options

      # The parameter values (see Values).
      attr_reader :params

      # Creates a runner for a script of +kind+ with +params+ declared as
      # {name => default} or {name => [default, 'description']}, parsing
      # +argv+ (which is modified) and printing help for +script+.  For
      # effects, +input_channels+ is the default input channel count for
      # files and live input, and +live_channels+ for live input only.
      def initialize(kind, params = {}, argv: ARGV, script: $0, input_channels: nil, live_channels: nil)
        raise ArgumentError, "Unknown script kind #{kind.inspect}" unless [:effect, :synth, :song].include?(kind)

        @kind = kind
        @script = script
        @input_channels = input_channels
        @live_channels = live_channels
        @declared = params.map { |name, spec| declare(name, spec) }
        parse(argv)
      end

      # Runs an effect: builds the graph with the block from the input (a
      # file given as the first audio argument or --input, or live audio
      # with --input-channels channels) and the parameters, then plays or
      # renders it.  A file input rings out: after it ends (and repeats, with
      # --repeat), the effect keeps playing until its output has been quiet
      # for Session::TAIL_QUIET_SECONDS.
      def run_effect(&block)
        path = @options[:input]
        channels = @options[:channels]
        input = if path && @options[:repeat]
                  data = MB::Sound.read(path, channels: channels)
                  ArrayInput.new(data: data, repeat: @options[:repeat]).ringdown
                elsif path
                  MB::Sound.file_input(path, channels: channels).ringdown
                else
                  MB::Sound.input(channels: channels || @live_channels || 2)
                end

        @params.midi_source = method(:midi)
        graph = to_graph(block.call(input, @params))
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
        @params.midi_source = method(:midi)
        graph = to_graph(block.arity == 1 ? block.call(@options[:input]) : block.call(@options[:input], @params))
        announce(graph)
        play_or_render(graph)
      end

      # Runs a song: the block arranges it on the current session (with #bg,
      # #at_bar, etc.), then it plays live until it ends (see
      # PlaybackMethods#wait), or renders +bars+ bars plus the master tail to
      # the output file.  --bars N plays or renders N bars plus the tail
      # (without --bars, live songs play until they end, and renders stop
      # after +bars+ or when the song ends).  --graphviz draws the graph as
      # it is at the start (players started later by #at_bar are missing).
      def run_song(bars: nil, &block)
        print_params
        open_song_graphviz(&block) if @options[:graphviz]

        if @options[:output]
          seconds = MB::Sound.render(@options[:output], bars: @options[:bars] || bars, tail: true, overwrite: overwrite) { arrange_song(&block) }
          puts "Rendered #{seconds.round(1)} seconds to #{@options[:output]}"
        else
          arrange_song(&block)
          stop_after_bars(@options[:bars]) if @options[:bars]
          live
        end
      end

      private

      # Arranges a song with +block+ on the current session, at the --bpm
      # tempo if given.
      def arrange_song(&block)
        MB::Sound.transport.override_bpm(@options[:bpm]) if @options[:bpm]
        block.call(@params)
      end

      # Returns the MidiDsl for live MIDI control (see Values#midi_cc), or
      # nil when writing a file or when MIDI isn't available.  Tries once.
      def midi
        return @midi if defined?(@midi)

        @midi = nil
        return if @options[:output]

        @midi = MB::Sound.midi
        puts "\e[1mMIDI control enabled\e[0m" unless @options[:quiet]
        @midi
      rescue => e
        puts "\e[38;5;243mMIDI control disabled (#{e.message})\e[0m" unless @options[:quiet]
        @midi = nil
      end

      # Stops the song at the end of bar +bars+ on the current session's
      # timeline (like a render with --bars): cancels anything still
      # scheduled and stops every player, letting master effects ring out.
      def stop_after_bars(bars)
        session = Session.current
        session.schedule(bars * session.transport.bar_length, description: "end of --bars #{bars}") do
          MB::Sound.cancel
          MB::Sound.stop(:all, fade: 0)
        end
      end

      # Parses +argv+ into @options and @params.
      def parse(argv)
        @options = { input: nil, output: nil, force: false, graphviz: false, plot: false, quiet: false, channels: @input_channels, repeat: nil }
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
            o.on('-c', '--input-channels N', Integer, 'Input channels (live input, or to up/downmix a file)') { |v| @options[:channels] = v }
            o.on('--repeat [COUNT]', Integer, 'Loop the input file COUNT times (forever without COUNT)') { |v| @options[:repeat] = v || -1 }
          when :synth
            o.on('-i', '--input MIDI', 'A MIDI file, or a MIDI port name (default: live MIDI)') { |v| @options[:input] = v }
          when :song
            o.on('-b', '--bars N', Float, 'Bars to play or render (default: the whole song)') { |v| @options[:bars] = v.rationalize }
            o.on('--bpm BPM', Float, "Starting tempo (the song's tempo changes scale with it)") { |v| @options[:bpm] = v }
          end

          @declared.each do |p|
            names = [p.short].compact
            if p.default == true || p.default == false
              o.on(*names, "--[no-]#{option_name(p)}", help_text(p)) { |v| values[p.name] = v }
            else
              o.on(*names, "--#{option_name(p)} VALUE", help_text(p)) { |v| values[p.name] = convert(p, v) }
            end
          end

          o.on('-h', '--help', 'Show this help') do
            MB::U.print_header_help(@script) if header_comment?
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

      # Creates a Param from a +spec+ given to #initialize.
      def declare(name, spec)
        default, *extras = spec.is_a?(Array) ? spec : [spec]
        param = Param.new(name.to_sym, default)

        extras.each do |e|
          case e
          when /\A-[A-Za-z]\z/ then param.short = e
          when String then param.description = e
          when Class, Proc then param.type = e
          when Range, Array then param.allowed = e
          else raise ArgumentError, "Unknown #{e.inspect} in the declaration of parameter #{name}"
          end
        end

        if param.short && COMMON_SHORT_OPTIONS[@kind].include?(param.short)
          raise ArgumentError, "Parameter #{name} can't use #{param.short}, a common option for #{@kind} scripts"
        end

        param
      end

      # Returns +result+ from a script block as a graph node or bundle: an
      # Array of nodes (one per channel) becomes a GraphNode::Channels.
      def to_graph(result)
        result.is_a?(Array) ? GraphNode::Channels.new(result) : result
      end

      # True if the script file starts with a header comment for --help
      # (a comment line right after the #! line).
      def header_comment?
        File.exist?(@script.to_s) && File.foreach(@script.to_s).first(2)[1].to_s.start_with?('#')
      end

      # The --option name of a parameter (underscores become dashes).
      def option_name(param)
        param.name.to_s.tr('_', '-')
      end

      # The option help for +param+: its description, allowed values, and
      # default.
      def help_text(param)
        allowed = "(#{allowed_text(param)})" if param.allowed
        default = "(default #{param.default.inspect})" unless param.default.nil?
        [param.description, allowed, default].compact.join(' ')
      end

      # Describes +param+'s allowed values.
      def allowed_text(param)
        param.allowed.is_a?(Range) ? "in #{param.allowed}" : "one of #{param.allowed.join(', ')}"
      end

      # Converts a command-line String to +param+'s type (or its default's
      # type), raising UsageError for invalid or disallowed values.
      def convert(param, str)
        value = case param.type || param.default
                when Proc then param.type.call(str)
                when Integer then str.include?('.') ? Float(str) : Integer(str)
                when Float, Rational then Float(str)
                when Symbol then str.to_sym
                else
                  if param.type == Integer then Integer(str)
                  elsif param.type == Float then Float(str)
                  elsif param.type == Symbol then str.to_sym
                  else str
                  end
                end

        if param.allowed && !(param.allowed.is_a?(Range) ? param.allowed.cover?(value) : param.allowed.include?(value))
          raise UsageError.new("--#{option_name(param)} must be #{allowed_text(param)} (got #{str})", @parser.to_s)
        end

        value
      rescue ArgumentError, TypeError => e
        raise if e.is_a?(UsageError)
        raise UsageError.new("Invalid value for --#{option_name(param)}: #{str.inspect} (#{e.message})", @parser.to_s)
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
        Session.with_context(session: session) { arrange_song(&block) }
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
