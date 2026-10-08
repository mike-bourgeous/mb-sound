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
    #     -P, --plot               plot the output while playing live
    #     -q, --quiet              don't print the parameters (or MIDI controls)
    #
    # General scripts (kind :script; utilities, plots, file processors) have
    # only -h/--help: their positional arguments go to the block.
    #
    # Effects add -i/--input FILE, -c/--input-channels N, --repeat [COUNT],
    # and -m/--midi SOURCE (MIDI controls for Values#midi_cc from a port or a
    # MIDI file); synths add -i/--input MIDI (a file or port, whose MIDI the
    # block gets as a MB::Sound::Notes); songs add -b/--bars N and --bpm BPM.
    # Live MIDI switches the sound card to the :low latency profile unless
    # one was chosen (see PlaybackMethods#live_midi_latency).
    #
    # Effects and synths list the MIDI controllers they respond to (a
    # MIDI::ControlMap of their Values#midi_cc parameters, the controllers
    # in use on their MIDI, and every controller node and Synth in the
    # graph) when MIDI is in use, unless --quiet, and take --acid-xml FILE
    # to write the map as a controller map for the ACID DAW ('-' prints it,
    # highlighted on a terminal).
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
    # - :required for a parameter that must be given (with a nil default)
    #
    #     count: [2, 'Repeats per grain', 2.., '-n'],
    #     wave: [:sine, 'LFO waveform', MB::Sound::Tone::WAVE_TYPES],
    #     preset: [nil, 'Reverb preset', Symbol],
    class ScriptRunner
      # Audio file extensions recognized in positional arguments.
      AUDIO_EXTENSIONS = /\.(flac|wav|mp3|ogg|mp4|m4a|opus|aiff?)\z/i

      # A declared parameter (see the class comment).
      Param = Struct.new(:name, :default, :description, :short, :type, :allowed, :required)

      # Short options used by every script of a kind, which parameters can't
      # use.
      COMMON_SHORT_OPTIONS = {
        effect: %w[-o -f -g -P -q -h -i -c],
        script: %w[-h],
        synth: %w[-o -f -g -P -q -h -i],
        song: %w[-o -f -g -P -q -h -b],
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
        # over +range+, starting at the parameter's value: a Notes controller
        # node (MB::Sound::Notes#control) when MIDI is available (live MIDI
        # unless the script is writing a file, or a -m/--midi MIDI file),
        # otherwise a constant.  Both are named after the parameter.  The
        # controller's MIDI::ControlSpec (see .cc_spec) carries the
        # parameter's name and description, so `p.midi.controls` lists it.
        #
        # The +range+ multiplies the parameter's value unless +:relative+ is
        # false (then it's an absolute range).
        # When the value is inside the range, the controller's middle (64)
        # gives exactly the value, with each half of the knob mapped
        # linearly to its side (like the GM2 sound controllers), so the knob
        # starts in the middle at the value given on the command line.
        #
        # The controller glides over +:smooth+ (default
        # Notes.control_smoothing; a time, or false for exact steps; see
        # Notes#cc).
        #
        # Example:
        #     lfo_hz = p.midi_cc(1, :hz, range: 0.0..6.0) # 0 to 6 times --hz
        #     mix = p.midi_cc(7, :mix, range: 0.0..1.0, smooth: 50.ms)
        def midi_cc(number, name, range:, relative: true, smooth: nil)
          value = self[name]
          range = (value * range.begin)..(value * range.end) if relative
          spec = Values.cc_spec(number, name, value, range, @descriptions&.[](name.to_sym))
          (@control_specs ||= []) << spec unless @control_specs&.include?(spec)
          notes = midi
          node = notes ? notes.control(spec, smooth: smooth) : value.constant
          node.named(name.to_s)
        end

        # The MIDI::ControlSpecs of every #midi_cc call so far, also those
        # that gave constants because MIDI wasn't available (for the
        # script's MIDI::ControlMap; see ScriptRunner#controls).
        def control_specs
          @control_specs || []
        end

        # The MIDI::ControlSpec for #midi_cc: controller +number+ named after
        # parameter +name+, mapped linearly over +range+ (a Range of
        # numbers, either direction) and starting at +value+: centered on it
        # (raw 64 = +value+) when it is strictly inside the range, else at the
        # range's end nearest to it.
        def self.cc_spec(number, name, value, range, description = nil)
          lo = range.begin.to_f
          hi = range.end.to_f
          inside = value > [lo, hi].min && value < [lo, hi].max
          default = if inside
                      64
                    elsif hi == lo
                      0
                    else
                      ((value - lo) / (hi - lo) * 127).round.clamp(0, 127)
                    end

          MIDI::ControlSpec.new(
            number: number, name: name.to_s, range: lo..hi, default: default,
            center: inside ? value : nil, description: description
          )
        end

        # The script's MIDI as a MB::Sound::Notes (live input, a MIDI file
        # given with -m/--midi for effects or as a synth's input), or nil when
        # MIDI isn't available (e.g. an effect writing a file without
        # -m/--midi).  Effects open it when first needed.
        def midi
          @midi&.call
        end

        # For internal use by ScriptRunner: sets a Proc that returns the
        # script's Notes (see #midi), or nil when MIDI isn't available, and
        # the parameter descriptions for controller specs.
        def midi_source=(source)
          @midi = source
        end

        # For internal use by ScriptRunner (see #midi_cc).
        def descriptions=(descriptions)
          @descriptions = descriptions
        end
      end

      # The kind of script: :effect, :synth, :song, or :script.
      attr_reader :kind

      # Positional arguments for a general script (kind :script).
      attr_reader :args

      # Parsed common options (:input, :output, :force, :graphviz, :plot,
      # :quiet, plus :channels for effects and :bars for songs).
      attr_reader :options

      # The parameter values (see Values).
      attr_reader :params

      # Creates a runner for a script of +kind+ with +params+ declared as
      # {name => default} or {name => [default, 'description']}, parsing
      # +argv+ (which is modified) and printing help for +script+.  For
      # effects, +input_channels+ is the default input channel count for
      # files and live input, and +live_channels+ for live input only.  For
      # general scripts, +args+ is the number of positional arguments
      # allowed (an Integer or Range; nil for any number).
      def initialize(kind, params = {}, argv: ARGV, script: $0, input_channels: nil, live_channels: nil, args: nil, profile: nil)
        raise ArgumentError, "Unknown script kind #{kind.inspect}" unless [:effect, :synth, :song, :script].include?(kind)

        @kind = kind
        @script = script
        @input_channels = input_channels
        @live_channels = live_channels
        @arg_count = args
        @profile = profile
        @declared = params.map { |name, spec| declare(name, spec) }
        parse(argv)
        apply_latency_profile
      end

      # Runs a general script: calls the block with the positional arguments
      # (an Array of Strings) and the parameters.  Returns the block's
      # result.
      def run_script(&block)
        block.call(@args, @params)
      end

      # Runs an effect: builds the graph with the block from the input (a
      # file given as the first audio argument or --input, or live audio
      # with --input-channels channels) and the parameters, then plays or
      # renders it at unity master gain (0 dB, not the -10 dB session
      # default).  File inputs ring out, so after the file ends (and
      # repeats, with --repeat), the effect keeps playing until its output
      # has been quiet for Session::TAIL_QUIET_SECONDS.
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

        # Effects process recordings that already have their own levels, so
        # they skip the master bus headroom that mixes of full-scale
        # oscillators need
        MB::Sound.master_gain(1)

        # Only the input's ring-out ends an effect (not MIDI file controls)
        play_or_render(graph) do |session|
          stop_after_ringdown(session, ending_nodes(graph).grep(GraphNode::Ringdown))
        end
      end

      # Runs a synth: builds the graph with the block from the script's MIDI
      # (a MB::Sound::Notes; see below) and the parameters, then plays or
      # renders it.  MIDI files ring out, so after the last event, the synth
      # keeps playing until its output has been quiet for
      # Session::TAIL_QUIET_SECONDS (see Synth#ended? and Notes#ended?).
      #
      # The MIDI comes from a MIDI file (a non-audio argument or --input), or
      # from live input (a port given the same way, connected by part of its
      # name, or by default a port named after the script).  Live input
      # switches the sound card to the :low latency profile unless one was
      # chosen (see PlaybackMethods#live_midi_latency).  The block gets it as
      # a Notes, which is a mono voice and a source for polyphonic synths:
      #
      #     synth_script { |midi| midi.synth(voices: 6) { |v| v.hz.saw * v.amp_env } }
      #     synth_script { |midi| midi.hz.saw * midi.amp_env }   # mono
      #
      # MB::Sound.synth(midi) { |v| ... } is the same as midi.synth.
      def run_synth(&block)
        notes = @synth_notes = synth_midi
        @params.midi_source = -> { notes }
        graph = to_graph(block.arity == 1 ? block.call(notes) : block.call(notes, @params))
        announce(graph)
        play_or_render(graph) do |session|
          stop_after_ringdown(session, ending_nodes(graph))
        end
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
          MB::Sound.warm_up # before the first write to the output (see WarmUpMethods)
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

      # Returns the effect's MIDI as a Notes (see Values#midi and #midi_cc),
      # or nil when MIDI isn't available.  Tries once.  An effect's --midi
      # SOURCE is a .mid/.midi file (played along with the graph, also when
      # writing a file) or part of a port's name to connect to; otherwise live
      # MIDI comes from a port to connect to, and none is used when writing a
      # file.
      def midi
        return @midi if defined?(@midi)

        @midi = nil
        source = @options[:midi]
        if source && File.file?(source)
          @midi = file_notes(source)
          puts "\e[1mMIDI control from #{source}\e[0m" unless @options[:quiet]
          return @midi
        end

        return if @options[:output]

        @midi = live_notes(source)
        puts "\e[1mMIDI control enabled\e[0m (#{@midi.stream.source.input.connections.join(', ')})" unless @options[:quiet]
        @midi
      rescue => e
        puts "\e[38;5;243mMIDI control disabled (#{e.message})\e[0m" unless @options[:quiet]
        @midi = nil
      end

      # A synth's MIDI as a Notes: its input file, or live input (see
      # #run_synth).  Rendering from live input reads it without changing
      # the sound card's profile.
      def synth_midi
        input = @options[:input]
        return file_notes(input) if input && File.file?(input)
        return Notes.new(MIDI::Stream.live(connect: input)) if @options[:output]

        live_notes(input)
      end

      # A Notes playing the MIDI file +path+ (raises unless it is .mid or
      # .midi).
      def file_notes(path)
        raise ArgumentError, "#{path} is not a MIDI file (expected .mid or .midi)" unless path.downcase.end_with?('.mid', '.midi')
        Notes.new(path)
      end

      # A Notes on live MIDI from MB::Sound.midi (shared with the console's
      # #midi; switches to the :low latency profile unless one was chosen).
      def live_notes(connect)
        MB::Sound.midi(connect, quiet: @options[:quiet])
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

      # Sets AUDIO_PROFILE for sound card outputs opened later (see
      # MB::Sound::DeviceOutput::PROFILES): -L/--latency-profile wins, then
      # an AUDIO_PROFILE already set, then the script's own +:profile+.
      def apply_latency_profile
        if @options[:profile]
          ENV['AUDIO_PROFILE'] = @options[:profile].to_s
        elsif @profile && !ENV['AUDIO_PROFILE']
          ENV['AUDIO_PROFILE'] = @profile.to_s
        end
      end

      # Parses +argv+ into @options and @params.
      def parse(argv)
        @options = { input: nil, output: nil, force: false, graphviz: false, plot: false, quiet: false, channels: @input_channels, repeat: nil }
        values = @declared.to_h { |p| [p.name, p.default] }

        @parser = parser = OptionParser.new { |o|
          o.banner = "Options for #{File.basename(@script)}:"
          unless @kind == :script
            o.on('-o', '--output FILE', 'Write to an audio file instead of playing') { |v| @options[:output] = v }
            o.on('-f', '--force', '--overwrite', 'Overwrite the output file') { @options[:force] = true }
            o.on('-g', '--graphviz', 'Open a visualization of the node graph') { @options[:graphviz] = true }
            o.on('-P', '--plot', 'Plot the output while playing live') { @options[:plot] = true }
            o.on('-q', '--quiet', "Don't print the parameters or MIDI controls") { @options[:quiet] = true }
            profiles = MB::Sound::DeviceOutput::PROFILES.keys
            o.on(
              '-L', '--latency-profile PROFILE', profiles.map(&:to_s),
              "Sound card latency profile: #{profiles.join(', ')} (default: #{@profile || 'AUDIO_PROFILE or default'})"
            ) { |v| @options[:profile] = v.to_sym }
          end

          case @kind
          when :effect
            o.on('-i', '--input FILE', 'An audio file to process (default: live input)') { |v| @options[:input] = v }
            o.on('-c', '--input-channels N', Integer, 'Input channels (live input, or to up/downmix a file)') { |v| @options[:channels] = v }
            o.on('--repeat [COUNT]', Integer, 'Loop the input file COUNT times (forever without COUNT)') { |v| @options[:repeat] = v || -1 }
            o.on(
              '-m', '--midi SOURCE',
              'MIDI controls from a port (part of its name) or a .mid file (default: a port to connect to)'
            ) { |v| @options[:midi] = v }
          when :synth
            o.on('-i', '--input MIDI', 'A MIDI file, or a MIDI port name (default: live MIDI)') { |v| @options[:input] = v }
          when :song
            o.on('-b', '--bars N', Float, 'Bars to play or render (default: the whole song)') { |v| @options[:bars] = v.rationalize }
            o.on('--bpm BPM', Float, "Starting tempo (the song's tempo changes scale with it)") { |v| @options[:bpm] = v }
          end

          if @kind == :effect || @kind == :synth
            o.on('--acid-xml FILE', "Write the MIDI controls as an ACID controller map ('-' prints it)") { |v| @options[:acid_xml] = v }
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
          rest = parser.parse(@kind == :script ? protect_negative_numbers(argv) : argv)
        rescue OptionParser::ParseError => e
          raise UsageError.new(e.message, parser.to_s)
        end
        rest = rest.map { |a| a.delete_prefix(NEGATIVE_MARK) }
        argv.replace(rest) # leave only positional arguments (e.g. for Kernel#gets)
        positional(rest)

        missing = @declared.select { |p| p.required && values[p.name].nil? }
        unless missing.empty?
          raise UsageError.new("Missing #{missing.map { |p| "--#{option_name(p)}" }.join(', ')}", parser.to_s)
        end

        @params = Values.new(values)
        @params.descriptions = @declared.to_h { |p| [p.name, p.description] }
      end

      # Assigns positional filenames to input and output by script kind.
      def positional(args)
        if @kind == :script
          @args = args
          check_arg_count
          return
        end

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
          when :required then param.required = true
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

      # Marks negative numbers given as positional arguments to general scripts
      # (e.g. timestamp/delay pairs like `1 -100`) so OptionParser doesn't
      # read them as short options.
      NEGATIVE_MARK = "\0"

      # Returns +argv+ with negative numbers marked (see NEGATIVE_MARK),
      # except those following an option that takes a value (e.g.
      # `--gain -12`), which OptionParser reads correctly.
      def protect_negative_numbers(argv)
        takes_value = @declared.reject { |p| p.default == true || p.default == false }
          .flat_map { |p| ["--#{option_name(p)}", p.short].compact }

        argv.each_with_index.map { |a, idx|
          if a.match?(/\A-\d/) && !(idx > 0 && takes_value.include?(argv[idx - 1]))
            NEGATIVE_MARK + a
          else
            a
          end
        }
      end

      # Raises UsageError unless a general script got the allowed number of
      # positional arguments.
      def check_arg_count
        return if @arg_count.nil?

        allowed = @arg_count.is_a?(Range) ? @arg_count : (@arg_count..@arg_count)
        return if allowed.cover?(@args.length)

        expected = case
                   when allowed.end.nil? then "at least #{allowed.begin}"
                   when allowed.begin == allowed.end then allowed.begin.to_s
                   else "#{allowed.begin} to #{allowed.end}"
                   end
        raise UsageError.new("Expected #{expected} argument#{expected == '1' ? '' : 's'} (got #{@args.length})", @parser.to_s)
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
        default = '(required)' if param.required
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
        show_controls(graph)
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

      # The script's MIDI controls as a MIDI::ControlMap: its
      # Values#midi_cc parameters, the controllers in use on its MIDI (a
      # synth's Notes, or an effect's when opened), and every controller
      # node and Synth in +graph+.
      def controls(graph)
        notes = @kind == :synth ? @synth_notes : (@midi if defined?(@midi))
        MIDI::ControlMap.new(@params, notes, graph)
      end

      # Writes or prints the ACID controller map (--acid-xml), and lists the
      # MIDI controls unless --quiet, if MIDI is in use (a synth, or an
      # effect with MIDI open) and there are any (see #controls).
      def show_controls(graph)
        map = controls(graph)
        name = File.basename(@script)

        case @options[:acid_xml]
        when nil
        when '-'
          xml = map.to_acid_xml(name: name)
          puts $stdout.tty? ? MB::U.syntax(xml, :xml) : xml
        else
          map.write_acid_xml(@options[:acid_xml], name: name)
          n = map.numbers.length
          puts "Wrote an ACID controller map (#{n} MIDI control#{'s' unless n == 1}) to #{@options[:acid_xml]}" unless @options[:quiet]
        end

        midi_in_use = @kind == :synth || (defined?(@midi) && @midi)
        puts map if midi_in_use && !map.empty? && !@options[:quiet]
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
          MB::Sound.warm_up(midi: @kind == :synth) # before the first write to the output (see WarmUpMethods)
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

      # Returns the nodes in +graph+ whose sources can end while the graph
      # keeps sounding (they respond to #ended?): GraphNode::Ringdown for
      # file inputs, and Synths and Notes nodes for MIDI files.
      #
      # A Synth stands for everything inside it (its #ended? waits for the
      # source and for every voice lane to go idle), and Envelopes with a
      # gate or trigger are skipped, since they never end by themselves.
      def ending_nodes(graph)
        nodes = graph_nodes(graph).select { |n| n.respond_to?(:ended?) }
        inside = nodes.grep(Synth).flat_map(&:graph).reject { |n| n.is_a?(Synth) }.map(&:__id__).to_set
        nodes.reject { |n|
          inside.include?(n.__id__) || (n.is_a?(Envelope) && !n.one_shot?)
        }.uniq(&:__id__)
      end

      # Stops the script's player once every node in +ringdowns+ has ended
      # (see #ending_nodes) and the mix has been quiet for
      # Session::TAIL_QUIET_SECONDS, or fades it out over
      # Session::TAIL_FADE_SECONDS after Session::MAX_TAIL_SECONDS of tail.
      # Does nothing if +ringdowns+ is empty (e.g. live input).
      def stop_after_ringdown(session, ringdowns)
        return if ringdowns.empty?

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
