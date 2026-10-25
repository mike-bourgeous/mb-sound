require 'tempfile'

module MB
  module Sound
    # Library plumbing that used to be console commands (MB::Sound extended
    # itself with the modules that defined them, so they filled the
    # console's tab completion and help; maintainer decision 2026-10-13,
    # research-api-surface P8).  Not extended into MB::Sound: call them as
    # MB::Sound::Internal.name(...).  Pry completes a bare word from private
    # methods too, so making them private wouldn't have hidden them.
    #
    # Also holds the state behind RandomMethods (the root random generator)
    # and PlotMethods#plotter (the shared plotters).
    module Internal
      module_function

      # Added to an error raised inside .quiet_stderr: the text C libraries
      # printed to stderr meanwhile.
      module CapturedStderr
        attr_accessor :captured_stderr

        # The captured lines, stripped, without repeats, joined with "; ".
        def stderr_summary
          captured_stderr.to_s.lines.map(&:strip).reject(&:empty?).uniq.join('; ')
        end
      end

      # Runs the block with $stdout going nowhere (e.g. a render's second
      # pass, whose blocks print what the first pass printed).  Returns the
      # block's value.
      def without_stdout
        saved = $stdout
        File.open(File::NULL, 'w') do |null|
          $stdout = null
          yield
        ensure
          $stdout = saved
        end
      end

      # Runs the block with the process's stderr (file descriptor 2)
      # captured, since C libraries (ALSA, RtMidi, miniaudio) print their
      # errors there: an error of one of +error_classes+ (default
      # StandardError) raised by the block is raised again extended with
      # CapturedStderr (#captured_stderr holds the text), so the caller can
      # print one line instead of a wall of ALSA messages (no sound card:
      # 35 lines per attempt, ux-review-1); on success the text is printed
      # after all.  Other threads' output to stderr in the meantime is held
      # until the block returns.
      def quiet_stderr(*error_classes)
        error_classes = [StandardError] if error_classes.empty?
        $stderr.flush
        STDERR.flush
        saved = STDERR.dup
        Tempfile.create('mb_sound_stderr') do |f|
          error = nil
          begin
            STDERR.reopen(f)
            result = yield
          rescue *error_classes => e
            error = e
          ensure
            STDERR.flush
            STDERR.reopen(saved)
            saved.close
          end

          f.rewind
          text = f.read
          if error
            error.extend(CapturedStderr)
            error.captured_stderr = text
            raise error
          end

          STDERR.write(text) unless text.empty?
          result
        end
      end

      # Where +error+ came from in the user's code ("(pry):3",
      # "songs/x.rb:12"): its first backtrace frame outside mb-sound's lib/
      # and installed gems, or nil (a failing patch's line, for messages
      # that name it: the UI's capture and swap, Arrangement#capture).
      def error_origin(error)
        location_outside(error.backtrace_locations || [])
      end

      # The first of +locations+ (Thread::Backtrace::Location) outside
      # mb-sound's lib/ and installed gems, as "path:line", or nil.
      def location_outside(locations)
        lib = File.expand_path('..', __dir__)
        loc = locations.find do |l|
          path = l.absolute_path || l.path.to_s
          !path.start_with?(lib) && !path.include?('/gems/') && !path.start_with?('<internal')
        end
        return nil unless loc
        path = (loc.absolute_path || loc.path).to_s.delete_prefix("#{Dir.pwd}/")
        "#{path}:#{loc.lineno}"
      end

      # mb-sound's lib/mb/sound directory, for .creation_trace.
      SOUND_LIB = File.expand_path('.', __dir__).freeze

      # Library files .creation_trace always leaves out: plumbing every node
      # passes through (constructors' ivar presets, recipe recorders,
      # get_sampler), which says nothing about where a node came from.
      TRACE_PLUMBING = %w[graph_node.rb graph_node/ivar_preset.rb graph_node/recipe.rb graph_node/recipe/surface.rb]
        .map { |f| File.join(SOUND_LIB, f).freeze }.freeze

      # Where a node or Tee branch is being made, for its error messages
      # (Tee::Branch, ProcNode; omnibus13): one frozen String of
      # "path:line" lines from the nearest +depth+ frames above the caller,
      # the first +library+ in lib/mb/sound (which node and DSL method;
      # plumbing and +skip+ files left out), then, past an "..." line for
      # library frames left out, the first +outside+ frames outside it (the
      # user's script or console line).  It keeps one object, shared by
      # every call with the same frames (an interned String), where an
      # Array of Locations kept 25 for the graph's life (~50k old objects
      # per tunnel_vision run), and allocates about as much while it runs
      # (the same caller_locations, the String, cached line numbers).
      def creation_trace(skip: nil, library: 4, outside: 5, depth: 24)
        s = String.new(capacity: 512)
        lib = 0
        out = 0
        elided = false
        caller_locations(2, depth)&.each do |l|
          path = l.path
          if path.start_with?(SOUND_LIB)
            next if TRACE_PLUMBING.include?(path) || skip&.include?(path)
            if lib >= library
              elided = true
              next
            end
            lib += 1
          else
            if elided
              s << TRACE_ELIDED
              elided = false
            end
            out += 1
          end
          s << path << TRACE_COLON << line_string(l.lineno) << TRACE_NEWLINE
          break if out >= outside
        end
        s.chomp!
        -s # (deduplicated: rebuilds of a patch share one String)
      end

      # Frozen decimal strings of line numbers, for .creation_trace (no
      # String per frame).
      LINE_STRINGS = Array.new(4096) { |i| i.to_s.freeze }.freeze
      TRACE_ELIDED = "...\n".freeze
      TRACE_COLON = ':'.freeze
      TRACE_NEWLINE = "\n".freeze

      def line_string(n)
        LINE_STRINGS[n] || n.to_s
      end

      # Warns +message+ once per line of user code calling into mb-sound
      # (the first caller outside lib/), as "path:line: warning: message"
      # (ux-fix-1: `at(-20)` and `delay(96)`, valid but usually typos; also
      # deprecated keywords).  +key+ separates kinds of warning.  Returns
      # true if it warned.
      def warn_once_per_site(key, message)
        site = location_outside(caller_locations(1) || []) || '(unknown)'
        first = WARNED_LOCK.synchronize {
          @warned_sites ||= {}
          @warned_sites.key?([key, site]) ? false : (@warned_sites[[key, site]] = true)
        }
        warn "#{site}: warning: #{message}" if first
        first
      end

      WARNED_LOCK = Mutex.new

      # Returns true if the given Array looks like a (possibly nested)
      # numeric array, false if it's not an array or contains non-numeric
      # data.  Only checks the first element of an array.
      def is_numeric_array?(array)
        return false unless array.is_a?(Array)

        case array[0]
        when Array
          is_numeric_array?(array[0])

        when Numeric
          true

        else
          false
        end
      end

      # Converts a single Tone, Pitch, or Numeric Array to NArray (a String
      # is read as a sound file).  If given an Array of these, returns an
      # Array of NArray.
      def convert_sound_to_narray(sound, depth = 0)
        case sound
        when Tone, Pitch
          # One second, so FFT bins are 1 Hz apart
          sound.sample(sound.sample_rate.round)

        when String
          # If the filename is within an array, only return the first channel
          MB::Sound.read(sound).yield_self { |v| depth > 0 ? v[0] : v }

        when Array
          if is_numeric_array?(sound)
            Numo::NArray.cast(sound)
          else
            sound.map { |el| convert_sound_to_narray(el, depth + 1) }
          end

        when GraphNode
          # TODO: this could be improved for plotting or saving signal chains/graphs
          sound.sample(960)

        else
          sound
        end
      end

      # Like #any_sound_to_array, but ensures everything is in a Hash.  If
      # given an Array, returns a Hash mapping array indices to the
      # converted sounds.
      def any_sound_to_hash(sounds)
        if sounds.is_a?(Array) && !sounds[0].is_a?(Numeric)
          sounds = sounds.map.with_index { |v, idx|
            case v
            when String
              k = "#{idx}: #{File.basename(v)}"

            when Tone
              k = "#{idx}: #{v.frequency.round(2)}Hz #{v.wave_type}"

            when Pitch
              k = "#{idx}: #{v.frequency.round(2)}Hz"

            else
              k = idx
            end

            [k, v]
          }.to_h
        elsif !sounds.is_a?(Hash)
          sounds = {0 => sounds}
        end

        any_sound_to_array(sounds)
      end

      # Like #convert_sound_to_narray, but wraps everything in a top-level
      # Array if it is not already in one.  If given a Hash, then preserves
      # the keys and maps them to the new values.
      def any_sound_to_array(array)
        if array.is_a?(Hash)
          return array.keys.zip(any_sound_to_array(array.values)).to_h
        end

        convert_sound_to_narray(array).yield_self { |v| v.is_a?(Array) ? v : [v] }
      end

      # Returns a Symbol describing the type of input that should be used:
      # INPUT_TYPE, :null for a +device+ of 'null', else :device.  See
      # IOMethods#input.
      def detect_input(device)
        return ENV['INPUT_TYPE'].gsub(/^:/, '').to_sym if ENV['INPUT_TYPE']
        return :null if device == 'null' || device == ':null' || device == :null

        :device
      end

      # Where help and console preferences keep per-user state (see
      # Help.data_dir): $MB_SOUND_HELP_DIR, else the user data directory.
      def help_data_dir
        env = ENV['MB_SOUND_HELP_DIR']
        return File.expand_path(env) unless env.to_s.empty?
        if RbConfig::CONFIG['host_os'] =~ /darwin/
          File.join(Dir.home, 'Library', 'Application Support', 'mb-sound', 'help')
        else
          base = ENV['XDG_DATA_HOME'].to_s.empty? ? File.join(Dir.home, '.local', 'share') : ENV['XDG_DATA_HOME']
          File.join(base, 'mb-sound', 'help')
        end
      end

      # Returns a Symbol describing the type of output that should be used:
      # OUTPUT_TYPE, else :device (see IOMethods#output).
      def detect_output
        return ENV['OUTPUT_TYPE'].gsub(/^:/, '').to_sym if ENV['OUTPUT_TYPE']

        :device
      end

      # Generates negative frequencies from the given FFT data with only
      # positive frequencies.  Not needed with FFTMethods#real_fft and
      # #real_ifft.
      def generate_negative_freqs(data, odd_length: false)
        raise NotImplementedError, 'Only one dimension supported at this time' if data.ndim != 1

        neg = data[1..(odd_length ? -1 : -2)].reverse
        data.concatenate(neg.conj)
      end

      # The root seed at startup: RANDOM_SEED from the environment, or
      # RandomMethods::DEFAULT_SEED (the specs restore it before every
      # example with `MB::Sound.seed(MB::Sound::Internal.default_seed)`).
      def default_seed
        ENV['RANDOM_SEED'] ? Integer(ENV['RANDOM_SEED']) : RandomMethods::DEFAULT_SEED
      end

      # Restarts the root random generator from +seed+ (see
      # RandomMethods#seed).  Returns the seed.
      def reseed(seed)
        @root_seed = Integer(seed)
        @root_rng = Random.new(@root_seed)
        @root_seed
      end

      # The root seed (see RandomMethods#seed).
      def root_seed
        root_rng
        @root_seed
      end

      # The root random number generator (a Random; see RandomMethods), for
      # library code that can control the order of its draws.
      def root_rng
        reseed(default_seed) if @root_rng.nil?
        @root_rng
      end

      # Replaces the root generator and its seed (RandomMethods#with_seed
      # and #keeping_random_state put the old ones back; a take's replay
      # restores the generator it saved).
      def restore_rng(rng, seed = @root_seed)
        @root_rng = rng
        @root_seed = seed
      end

      # The shared plotters behind PlotMethods#plotter: a terminal text
      # plotter, or an image plotter if +graphical+ is true (+kwargs+ go to
      # the constructor the first time).
      def plotter(graphical: false, **kwargs)
        @pt ||= Plot::Plotter.terminal(height_fraction: 0.8, **(graphical ? {} : kwargs))
        @pg ||= Plot::Plotter.graphical(**kwargs) if graphical
        graphical ? @pg : @pt
      end

      # The shared text plotter if one was made, else nil.
      def text_plotter
        @pt
      end

      # Closes the shared plotters without creating new ones (e.g. between
      # tests); +text:+ or +graphical:+ false keeps that one.
      def close_plotter(text: true, graphical: true)
        if text
          @pt&.close
          @pt = nil
        end
        if graphical
          @pg&.close
          @pg = nil
        end
      end

      # Waits +seconds+ of audio for code that waits on a Session (foreground
      # #play, #wait, take replays): wall-clock sleep, or on an output that
      # keeps a virtual clock (NullOutput sleep: :virtual) lets that much
      # audio through and waits until it was written (see
      # NullOutput#consume), so specs of these waits run as fast as the
      # render and see the same frames every time.
      def wait_audio(session, seconds)
        out = session&.instance_variable_get(:@output)
        if out.respond_to?(:virtual?) && out.virtual? && !out.closed?
          out.consume(seconds)
        else
          sleep seconds
        end
        nil
      end
    end
  end
end
