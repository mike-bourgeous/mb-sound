require 'optparse'

require_relative 'script_runner/live_keys'
require_relative 'script_runner/scrub'

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
    #     --ui [LAYOUT]            play live in a terminal screen (see #live_ui)
    #
    # General scripts (kind :script; utilities, plots, file processors) have
    # only -h/--help: their positional arguments go to the block.
    #
    # Effects add -i/--input FILE, -c/--input-channels N, --repeat [COUNT],
    # and -m/--midi SOURCE (MIDI controls for Values#midi_cc from a port or a
    # MIDI file); synths add -i/--input MIDI (a file or port, whose MIDI the
    # block gets as a MB::Sound::Notes); songs add -b/--bars N, --bpm BPM,
    # --from/--to/--seek (render windows), and --take [FILE] (the run
    # recorded as a take; see #run_song).
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
      @songs = {}

      class << self
        # Remembers a song script's parameter declarations and block (see
        # ScriptingMethods#song_script), so a take replay can run the song
        # again (see .replay_song).
        def register_song(file, params, block)
          @songs[File.expand_path(file)] = [params, block].freeze
        end

        # The script file being loaded for a take replay (see
        # .replay_song), or nil: ScriptingMethods#main_script? is true for
        # it, and its song_script only registers its block.
        def song_replay_file
          Thread.current[:mb_sound_song_replay]
        end

        # Runs the song of script +path+ (relative to mb-sound's root, or
        # absolute) on the current session with parameter values +params+
        # (the rest at their defaults) and the --bpm override +bpm+: the
        # line of a take recorded with --take (see #run_song), so a replay
        # plays the song the way the run did.  Loads the script (as if it
        # were run, without running it) unless it has already registered
        # its song.  Returns the block's result.
        def replay_song(path, params = {}, bpm: nil)
          file = script_path(path)
          entry = @songs[file] || begin
            old = Thread.current[:mb_sound_song_replay]
            Thread.current[:mb_sound_song_replay] = file
            load file
            @songs[file] or raise ArgumentError, "#{path} calls no song_script"
          ensure
            Thread.current[:mb_sound_song_replay] = old
          end

          decls, block = entry
          runner = new(:song, decls, argv: [], script: file)
          values = Values.new(runner.instance_variable_get(:@params).to_h.merge(params.transform_keys(&:to_sym)))
          MB::Sound.transport.override_bpm(bpm) if bpm
          block.call(values)
        end

        # The path a take line names script +file+ by: relative to
        # mb-sound's root when inside it (so takes keep working when the
        # checkout moves), else absolute.
        def take_path(file)
          full = File.expand_path(file)
          full.start_with?("#{ROOT}/") ? full.delete_prefix("#{ROOT}/") : full
        end

        private

        def script_path(path)
          return File.expand_path(path) if File.absolute_path?(path)
          [File.expand_path(path, ROOT), File.expand_path(path)].find { |f| File.exist?(f) } || File.expand_path(path, ROOT)
        end
      end

      # mb-sound's root directory (scripts in take lines are relative to it).
      ROOT = File.expand_path('../../..', __dir__)

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

      # Long options of song scripts, which parameters can't be named
      # (acid_song's old `master:` parameter shadowed --master).
      COMMON_SONG_LONG_OPTIONS = %w[bars bpm from to report master lufs ride seek take stems stem_gain].freeze

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

      # Raised for inputs that can't work (a missing file, -o without an
      # input file, a --from section the song doesn't have), checked before
      # anything is built: ScriptingMethods prints the message as one line
      # and exits with status 2 (ux-fix-1).
      class InputError < ArgumentError; end

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
      # allowed (an Integer or Range; nil for any number).  +description+
      # is the document description --save writes (a String, or a Proc
      # called with the parameters).
      def initialize(kind, params = {}, argv: ARGV, script: $0, input_channels: nil, live_channels: nil, args: nil, profile: nil, description: nil)
        raise ArgumentError, "Unknown script kind #{kind.inspect}" unless [:effect, :synth, :song, :script].include?(kind)

        @kind = kind
        @script = script
        @input_channels = input_channels
        @live_channels = live_channels
        @arg_count = args
        @profile = profile
        @description = description
        @declared_specs = params
        @section_back_at = nil # (song screens' Up key; see #ui_section_back)
        @section_back_depth = 0
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
        check_inputs
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
        result = block.call(input, @params)
        return save_graph(result, input: input) if @options[:save]

        graph = to_graph(result)
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
        check_inputs
        notes = @synth_notes = synth_midi
        @params.midi_source = -> { notes }
        result = block.arity == 1 ? block.call(notes) : block.call(notes, @params)
        return save_graph(result, midi: notes) if @options[:save]

        graph = to_graph(result)
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
        raise InputError, 'Pass --to or --bars, not both' if @options[:to] && @options[:bars]
        raise InputError, '--seek goes with --from' if @options[:seek] && !@options[:from]
        raise InputError, '--take records a whole run (not with --from or --to)' if @options[:take] && (@options[:from] || @options[:to])
        window_targets.each { |what, target| check_window_target(Session.current, target, what) unless target.is_a?(Symbol) }
        raise InputError, '--stems needs a render (-o FILE or an output file name)' if @options[:stems] && !@options[:output]
        raise InputError, '--report needs a render (-o FILE or an output file name)' if @options[:report] && !@options[:output]

        print_params
        open_song_graphviz(&block) if @options[:graphviz]

        if @options[:output]
          window = {}
          window[:exact_lanes] = true if @options[:take] # as the replay will (see Take::Replay)
          window[:report] = :tracks if @options[:report]
          window[:from] = @options[:from] if @options[:from]
          window[:preroll] = false if @options[:seek]
          if @options[:to]
            window[:to] = @options[:to]
          elsif @options[:from] && !@options[:bars] && bars
            # The song's own length still ends it (where bar bars + 1 starts)
            window[:to] = bars.to_r + 1
          else
            window[:bars] = @options[:bars] || bars
          end
          window[:master] = mastering_option if @options.key?(:master)
          window[:loudness] = @options[:lufs] if @options.key?(:lufs) && !(@options[:ride] && @options[:master])
          seconds = MB::Sound.render(@options[:output], **window, tail: true, overwrite: overwrite, stems: @options[:stems], stem_gain: (@options[:stem_gain] || 0).db) { arrange_song(&block) }
          puts "Rendered #{seconds.round(1)} seconds to #{@options[:output]}"
          puts "Stems in #{@options[:stems]}" if @options[:stems]
          save_take
        else
          MB::Sound.warm_up # before the first write to the output (see WarmUpMethods)
          Session.current.exact_lanes = true if @options[:take]
          if @options.key?(:master)
            Session.current.mastering_override = mastering_option
            # (a song that never sets master effects gets the preset too)
            Session.current.master(Session.current.mastering_override, on: :now) if Session.current.mastering_override
          end
          arrange_song(&block)
          start = @options[:from] ? seek_live(@options[:from]) : 0r
          if @options[:bars]
            stop_after_bars(@options[:bars], from: start)
          elsif @options[:to]
            stop_at(@options[:to], start)
          end
          begin
            live
          ensure
            save_take
          end
        end
      end

      private

      # The --master preset (a Mastering::Preset, with --ride and, when
      # riding, --lufs) or false for none.
      def mastering_option
        m = @options[:master]
        return false if m == :none
        raise ArgumentError, "Unknown mastering preset #{m.inspect} for --master (#{Mastering.names.join(', ')}, or none)" unless Mastering.preset?(m)
        options = {}
        if @options[:ride]
          options[:ride] = true
          options[:lufs] = @options[:lufs] if @options.key?(:lufs)
        end
        Mastering.preset(m, **options)
      end

      # Arranges a song with +block+ on the current session, at the --bpm
      # tempo if given.  --from/--to names are checked against the song's
      # form as it starts (before its warm-up; Arrangement#before_form),
      # and against the markers once the block has run, so live and render
      # runs print the same one line (InputError) before anything plays.
      def arrange_song(&block)
        return record_song_take(&block) if @options[:take]

        MB::Sound.transport.override_bpm(@options[:bpm]) if @options[:bpm]
        session = Session.current
        names = window_targets.select { |_, target| target.is_a?(Symbol) }
        return block.call(@params) if names.empty?

        check = session.arrangement.before_form { |form|
          names.each { |what, target| check_window_target(session, target, what, form: form) }
        }
        begin
          result = block.call(@params)
        ensure
          session.arrangement.remove_before_form(check)
        end
        names.each { |what, target| check_window_target(session, target, what) }
        result
      end

      # The --from and --to targets given, as { '--from' => target }.
      def window_targets
        { '--from' => @options[:from], '--to' => @options[:to] }.compact
      end

      # RenderWindow.check_target, raising an InputError (one line from
      # ScriptingMethods, exit 2) for a target the song doesn't have.
      def check_window_target(session, target, what, form: nil)
        RenderWindow.check_target(session, target, what, form: form)
      rescue RenderWindow::TargetError => e
        raise InputError, e.message
      end

      # --take: starts a Take on the current session and arranges the song
      # through one take line that runs it again by name (see
      # .replay_song), with the parameters given and the --bpm override,
      # so the saved replay plays the run's song exactly (with the MIDI
      # the session's inputs read, as console takes do).
      def record_song_take(&block)
        ScriptRunner.register_song(@script, @declared_specs, block)
        session = Session.current
        @take = Take.new(session: session)
        given = @params.to_h.reject { |k, v| @declared.find { |d| d.name == k }&.default == v }
        args = [ScriptRunner.take_path(@script).inspect]
        args << ruby_literal(given) unless given.empty?
        args << "bpm: #{ruby_literal(@options[:bpm])}" if @options[:bpm]
        code = "ScriptRunner.replay_song(#{args.join(', ')})"
        Session.with_context(session: session) { @take.line(code, Take.console_binding) }
      end

      # Saves the --take take (see #record_song_take), if any.
      def save_take
        return unless @take
        @take.save(@options[:take].is_a?(String) ? @options[:take] : nil)
      end

      # Ruby source for a parameter value in a take line.
      def ruby_literal(v)
        case v
        when Hash then "{ #{v.map { |k, x| "#{k}: #{ruby_literal(x)}" }.join(', ')} }"
        when Array then "[#{v.map { |x| ruby_literal(x) }.join(', ')}]"
        when Rational then v.denominator == 1 ? "#{v.numerator}r" : "#{v.numerator}/#{v.denominator}r"
        when Float, Integer, Symbol, String, true, false, nil then v.inspect
        when Range then "(#{ruby_literal(v.begin)}#{v.exclude_end? ? '...' : '..'}#{ruby_literal(v.end)})"
        else raise ArgumentError, "--take can't write parameter value #{v.inspect} into a take line"
        end
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
        src = @midi.stream.source
        src = src.live_source if src.respond_to?(:live_source)
        puts "\e[1mMIDI control enabled\e[0m (#{src.input.connections.join(', ')})" unless @options[:quiet]
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

        begin
          live_notes(input)
        rescue StandardError => e
          if input && !File.exist?(input) && !@options[:ui]
            raise InputError, "no file #{input.inspect} and no MIDI port named that (#{e.message.lines.first&.strip})"
          end
          raise unless @options[:ui]
          # --ui without a MIDI device: the screen's keyboard plays the
          # synth (its notes go to the session's default MIDI input)
          puts "\e[38;5;243mNo live MIDI (#{e.message.lines.first&.strip}); the screen's keyboard plays\e[0m" unless @options[:quiet]
          Notes.new(Session.current.midi_in.stream, sustain: true)
        end
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
      def stop_after_bars(bars, from: 0r)
        session = Session.current
        t = session.transport
        stop_song_at(t.bar_position(t.bar_at(from) + bars.to_r), "end of --bars #{bars}")
      end

      # Stops the song where --to +target+ starts (a bar number now, or a
      # section, label, or marker once the song gets there), after +from+.
      def stop_at(target, from)
        session = Session.current
        if target.is_a?(Symbol)
          session.markers.on(target) { |_m, pos| stop_song_at(pos, "--to #{target}") if pos > from }
        else
          stop_song_at(session.transport.bar_position(target), "--to bar #{target}")
        end
      end

      def stop_song_at(pos, description)
        session = Session.current
        session.schedule(pos, description: description, owner: :script) do
          session.reset_scheduler
          MB::Sound.stop(:all, fade: 0)
        end
      end

      # Live --from: seeks the song there (as `seek` in the console: fresh
      # state, the form plays on from there) and waits for the seek to
      # land.  Returns the timeline position it landed on.
      def seek_live(target)
        session = Session.current
        RenderWindow.check_target(session, target, '--from')
        seq = MB::Sound.seek(target).seq
        session.ensure_running
        sleep 0.005 while (entry = session.journal[seq]).queued?
        raise ArgumentError, "--from #{target.inspect}: the seek #{entry.status}" unless entry.landed?
        entry.lands.pos
      end

      # A --from/--to value: a bar number, or a section, label, or marker
      # name.
      def window_target(v)
        num = Float(v, exception: false)
        num ? num.rationalize(Rational(1, 1_000_000)) : v.to_sym
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
            o.on('--ui [LAYOUT]', 'Play live in a terminal screen (songs: :show, synths/effects: :play with the keyboard; q quits)') { |v| @options[:ui] = v ? v.delete_prefix(':').to_sym : :default }
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
            o.on(
              '--from WHERE',
              'Start at a section, label, or marker of the song (a name) or a bar number; renders play the song up to there ' \
              'without writing it, so the file is the song\'s own samples (--bars counts from there)'
            ) { |v| @options[:from] = window_target(v) }
            o.on('--to WHERE', 'End where a section, label, or marker (a name) or a bar number starts (with --from, or from the start)') { |v| @options[:to] = window_target(v) }
            o.on('--report', 'With a render: print a mix report (LUFS, short-term max, true peak, PLR per track and the mix, and per section)') { @options[:report] = true }
            o.on(
              '--master PRESET',
              "Master through a mastering preset (#{Mastering.names.join(', ')}; after the song's own master effects, replacing " \
              'its preset if it has one; none drops presets); renders reach its loudness target'
            ) { |v| @options[:master] = v.to_sym }
            o.on('--ride', 'With --master: ride the gain toward the target live (a slow rider; renders then run once instead of measuring)') { @options[:ride] = true }
            o.on('--lufs LUFS', 'Loudness target for a render (LUFS, or a name like spotify): the mastering preset\'s, else normalizes the file') { |v|
              @options[:lufs] = v.match?(/\A[-+]?\d/) ? Float(v) : v.to_sym
            }
            o.on('--seek', 'With --from in a render: seek there (faster, fresh state: no tails from before) instead of playing up to it') { @options[:seek] = true }
            o.on(
              '--take [FILE]',
              'Record the run as a take and save its replay script to FILE (default: the takes directory; replay with ' \
              '`ruby FILE -o out.flac`)'
            ) { |v| @options[:take] = v || true }
            o.on('--stems DIR', 'With a render: also write each track to DIR/<track>.<ext> (its part of the mix before the master chain)') { |v| @options[:stems] = v }
            o.on('--stem-gain DB', Float, 'Gain in dB for --stems (headroom for parts peaking over full scale before a master limiter)') { |v| @options[:stem_gain] = v }
          end

          if @kind == :effect || @kind == :synth
            o.on('--acid-xml FILE', "Write the MIDI controls as an ACID controller map ('-' prints it)") { |v| @options[:acid_xml] = v }
            o.on(
              '--save NAME',
              "Save the graph as a preset (a name, or a path ending in #{GraphIO::EXTENSION}) instead of playing; " \
              'numeric parameters the graph uses as constants become its knobs'
            ) { |v| @options[:save] = v }
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

      # Checks input files before anything is built (see InputError; called
      # first by #run_effect and #run_synth).
      def check_inputs
        name = File.basename(@script.to_s)
        input = @options[:input]
        case @kind
        when :effect
          if input && !File.exist?(input)
            raise InputError, "no file #{input.inspect}"
          elsif input && !File.readable?(input)
            raise InputError, "#{input.inspect} is not readable"
          elsif @options[:output] && input.nil? && ENV['INPUT_TYPE'].to_s.empty?
            raise InputError, "-o writes a file from an input file: give one (#{name} in.flac -o out.flac)"
          end

        when :synth
          if input && !File.exist?(input) && (input.downcase.end_with?('.mid', '.midi') || input.include?('/'))
            raise InputError, "no file #{input.inspect} (MIDI files end in .mid; other names are MIDI ports)"
          end
        end

        midi = @options[:midi]
        if midi && midi.downcase.end_with?('.mid', '.midi') && !File.exist?(midi)
          raise InputError, "no MIDI file #{midi.inspect}"
        end
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
        if @kind == :song && COMMON_SONG_LONG_OPTIONS.include?(name.to_s)
          raise ArgumentError, "Parameter #{name} can't be named like --#{name.to_s.tr('_', '-')}, a common option for song scripts"
        end

        param
      end

      # Saves the script block's +result+ as a graph document (--save; see
      # GraphIO.save) with +inputs+ ({ input: ... } or { midi: ... }).
      # Numeric parameters become params (knobs where the graph uses them
      # as Constants named after the parameter, e.g. Values#midi_cc
      # without MIDI or `p.drive.constant.named('drive')`; the rest are
      # baked in and listed as options), others are listed as options.
      # The script's description (see #initialize) goes in the header.
      # Prints and returns the path.
      def save_graph(result, inputs)
        params, options = graph_params
        description = @description.respond_to?(:call) ? @description.call(@params) : @description
        meta = description ? { description: description.to_s } : {}
        path = GraphIO.save(@options[:save], result, inputs: inputs, params: params, options: options, from: script_label, kind: @kind, meta: meta)
        puts "Saved #{File.basename(@script)}'s graph to #{path}"
        path
      end

      # [params, options] for #save_graph.
      def graph_params
        specs = @params.control_specs.to_h { |sp| [sp.name.to_sym, sp] }
        params = {}
        options = {}
        @declared.each do |p|
          v = @params[p.name]
          if v.is_a?(Numeric) && v.real?
            spec = { value: v }
            spec[:range] = p.allowed if p.allowed.is_a?(Range)
            spec[:description] = p.description if p.description
            if (cc = specs[p.name])
              spec[:cc] = cc.number
              spec[:range] = cc.range
            end
            params[p.name] = spec
          else
            options[p.name] = v
          end
        end
        [params, options]
      end

      # The script's path relative to the working directory when inside it.
      def script_label
        full = File.expand_path(@script)
        pwd = "#{Dir.pwd}/"
        full.start_with?(pwd) ? full.delete_prefix(pwd) : File.basename(full)
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
      #
      # With --plot, #wait runs in a thread and the plot stops when it
      # returns (visualize only returned on Ctrl-C before, so --plot scripts
      # never exited); Ctrl-C during the plot still stops only the plot.
      def live
        return live_ui(@options[:ui]) if @options[:ui]

        puts 'Playing (Ctrl-C to stop)' unless @options[:quiet]
        # Esc: all notes off (twice: all sound off), q quits, l recent MIDI
        keys = LiveKeys.new(Session.current).start if %i[synth effect].include?(@kind) && !@options[:plot]
        if @options[:plot]
          waiter = Thread.new { MB::Sound.wait }
          waiter.report_on_exception = false
          MB::Sound.visualize(stop: -> { !waiter.alive? })
          waiter.value
        else
          MB::Sound.wait
        end
      rescue Interrupt
        puts
      ensure
        keys&.stop
        waiter&.kill
      end

      # Plays live in a terminal screen without a console (ux-1 item 18,
      # `--ui [LAYOUT]`): UI::Tiles with repl: :none on +name+ (:default is
      # UI.show_layouts' :show for songs, :play for synths and effects,
      # which starts in KEYS mode with the keyboard playing the script's
      # MIDI input).  Keys come from UI::Keys::SONG_SCREEN and SYNTH_SCREEN
      # (also the hints and the `?` overlay), acting here: on
      # song screens q or Esc quits, Space pauses (the whole Session waits;
      # see Session#paused=), Left/Right step a bar (Scrub),
      # Up/Down or [ ] a section, PageUp/PageDown a scene; on synth and
      # effect screens Esc is all notes off; everywhere Ctrl-C quits,
      # Ctrl-] is NAV (zoom a pane, ...), F2 the keyboard.  When the song ends the screen
      # stays with its final meters until q.  What the script prints while
      # the screen is up goes to its messages pane.
      # The actions of UI::Keys::SONG_SCREEN and SYNTH_SCREEN that #live_ui
      # acts on (a spec checks the key tables bind no others).
      SCREEN_ACTIONS = %i[quit panic pause bar_back bar_forward section_prev section_next scene_prev scene_next].freeze

      def live_ui(name)
        name = @kind == :song ? :show : :play if name == :default
        layout = UI.show_layouts[name] || UI.layout_named(name)
        raise ArgumentError, "--ui #{name}: a band layout; use a tiled one (#{UI.show_layouts.keys.map(&:inspect).join(', ')}, ...)" unless layout.is_a?(UI::Viewports::Layout)

        session = Session.current
        waiter = Thread.new { MB::Sound.wait }
        waiter.report_on_exception = false
        quit = false
        tiles = nil
        panic = LiveKeys.new(session, out: UI::Messages::Writer.new(UI.messages, $stdout))
        scrub = Scrub.new(session.transport, seek: ->(bar) { MB::Sound.seek(bar) })
        on_key = ->(k) { quit = true if k == :interrupt }
        # The screen's keys come from UI::Keys::SONG_SCREEN or SYNTH_SCREEN
        # (also the hints and the `?` overlay); their actions land here
        on_action = ->(a) {
          case a.name
          when :quit then quit = true
          when :panic
            tiles.say(panic.key("\e") == :sound_off ? 'all sound off (CC 120)' : 'all notes off (Esc again: all sound off)', :warn)
          when :pause
            session.paused = !session.paused?
            tiles.note = session.paused? ? 'paused: Space plays on, q quits' : nil
          when :bar_back then ui_section(tiles) { tiles.say("bar #{scrub.press(:left)}", :dim) }
          when :bar_forward then ui_section(tiles) { tiles.say("bar #{scrub.press(:right)}", :dim) }
          when :section_prev then ui_section(tiles) { ui_section_back(tiles, session) }
          when :section_next then ui_section(tiles) { MB::Sound.skip }
          when :scene_prev then ui_section(tiles) { ui_scene(tiles, session, -1) }
          when :scene_next then ui_section(tiles) { ui_scene(tiles, session, 1) }
          end
        }
        play_keys = @kind == :song ? UI::Keys::SONG_SCREEN : UI::Keys::SYNTH_SCREEN
        UI.warm_up
        tiles = UI::Tiles.new(layout: layout, repl: :none, session: session, on_key: on_key, play_keys: play_keys, on_action: on_action, probe: $stdin.tty?)
        UI.instance_variable_set(:@tiles, tiles) # UI.screen: warnings and plots go to it
        out = $stdout
        $stdout = UI::Messages::Writer.new(UI.messages, out)
        tiles.start
        tiles.keys(patch: nil) if @kind != :song && layout.panes.include?(:keyboard) && !@options[:input]
        ended = false
        until quit
          if !ended && !waiter.alive?
            ended = true
            tiles.note = 'ended: q quits'
          end
          sleep 0.05
        end
      rescue Interrupt
        nil
      ensure
        session&.paused = false if session&.realtime?
        $stdout = out if out
        UI.off
        waiter&.kill
      end

      # Up or [ on a song screen: back to the start of the section playing,
      # or, within Scrub::GRACE of the last press (or right at its start),
      # to the section before it (from the form's history).
      def ui_section_back(tiles, session)
        pb = session.arrangement.playback
        return tiles.say('no form playing', :warn) unless pb && !pb.ended? && pb.section
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        chained = @section_back_at && now - @section_back_at <= Scrub::GRACE
        at_start = pb.pass_start && session.transport.position - pb.pass_start.to_r < 1/4r
        @section_back_at = now
        @section_back_depth = chained ? @section_back_depth.to_i + 1 : (at_start ? 1 : 0)
        hist = pb.history
        name = @section_back_depth.zero? ? pb.section : hist[-1 - @section_back_depth] || hist.first
        MB::Sound.seek(name)
        tiles.say("section #{name}", :dim)
      end

      # PageUp/PageDown on a song screen: launches the scene +dir+ (-1 or 1)
      # away from the current one (in definition order) at its launch point.
      def ui_scene(tiles, session, dir)
        arr = session.arrangement
        names = arr.scenes.keys
        return tiles.say('no scenes', :warn) if names.empty?
        i = names.index(arr.current_scene)
        name = names[i ? (i + dir).clamp(0, names.length - 1) : (dir > 0 ? 0 : names.length - 1)]
        MB::Sound.go(name)
        tiles.say("scene #{name}", :dim)
      end

      # Runs a section command for the script's screen, flashing errors
      # (no form, ...).
      def ui_section(tiles)
        yield
      rescue StandardError => e
        tiles.say("#{e.class}: #{e.message}", :warn)
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
