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
