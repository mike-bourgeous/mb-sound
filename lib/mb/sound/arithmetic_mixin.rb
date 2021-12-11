module MB
  module Sound
    # Adds methods to any class that implements a :sample method to build
    # signal generation and processing graphs.  In combination with Tone, Note,
    # and the helper methods in MB::Sound, this creates a DSL that can quickly
    # generate complex sounds.
    #
    # Examples (run in the bin/sound.rb environment):
    #     # FM organ bass
    #     play F1.at(-6.db).fm(F2.at(300) * adsr(0, 0.1, 0.0, 0.5, auto_release: false)) * adsr(0, 0, 1, 0, auto_release: 0.25)
    #
    #     # FM classic synth bass
    #     cenv = adsr(0, 0.005, 0.5, 2.5).db(30)
    #     cenv2 = adsr(0, 0.01, 0.5, 2.5).db(60)
    #     c = cenv * C3.at(1).fm(cenv2 * C3.at(1)).forever; nil
    #     denv = adsr(0, 0.005, 0, 2).db(50)
    #     d = denv * Tone.new(frequency: C3.frequency.constant * 0.9996 - 0.22).at(1).forever; nil
    #     eenv = adsr(0, 3, 0.0, 2).db
    #     e = eenv * C2.at(1).fm(c * 4810 + d * 500).forever; nil
    #     fenv = adsr(0, 2, 0, 2).db
    #     f = C2.at(-10.db).fm(e * 250) * fenv; nil
    #     play f
    #
    # TODO: This DSL is pretty good at fan-in (having a bunch of sources all
    # combine to a single input), but can't really do fan-out because #sample
    # is not idempotent.  Either a Tee object is needed that prevents in-place
    # processing (and all processing classes would need to be tested and
    # updated to make sure they work with in-place processing), or each node
    # should use its own buffer and copy in the data, and #sample should be
    # paired with an #update method to tell everything to render another window
    # of audio.
    module ArithmeticMixin
      attr_reader :graph_node_name

      # Gives a name to this graph node to make it easier to retrieve later.
      def named(n)
        @graph_node_name = n&.to_s
        self
      end

      # Creates a mixer that adds this mixer's output to +other+.  Part of a
      # DSL experiment for building up a signal graph.
      def +(other)
        fixup_tones(false, self, other)
        Mixer.new([self, other])
      end

      # Creates a mixer that subtracts +other+ from this mixer's output.  Part
      # of a DSL experiment for building up a signal graph.
      def -(other)
        fixup_tones(false, self, other)
        Mixer.new([self, [other, -1]])
      end

      # Creates a multiplier that multiplies +other+ by this mixer's output.
      # Part of a DSL experiment for building up a signal graph.
      def *(other)
        fixup_tones(false, self)
        fixup_tones(true, other)
        Multiplier.new([self, other])
      end

      # Divides incoming data by +other+, which may be a Numeric or another
      # signal graph.
      def /(other)
        if other.respond_to?(:sample)
          self.proc { |v|
            v.inplace!
            v / other.sample(v.length)
            v.not_inplace!
          }
        else
          self.proc { |v|
            v.inplace!
            v / other
            v.not_inplace!
          }
        end
      end

      # Appends a node that raises the incoming values to +other+, which should
      # be either a numeric or another signal graph.
      def **(other)
        if other.respond_to?(:sample)
          self.proc(other) { |v|
            data = other.sample(v.length)
            if v.nil? || data.nil?
              nil
            else
              v.inplace!
              v ** data
              v.not_inplace!
            end
          }
        else
          self.proc(other) { |v|
            if v.nil?
              nil
            else
              v.inplace!
              v ** other
              v.not_inplace!
            end
          }
        end
      end

      # Appends a node that calculates the natural logarithm of values passing
      # through.
      def log
        self.proc { |v| MB::FastSound.narray_log(v) }
      end

      # Appends a node that calculates the base two logarithm of values passing
      # through.
      def log2
        self.proc { |v| MB::FastSound.narray_log2(v) }
      end

      # Appends a node that calculates the base two logarithm of values passing
      # through.
      def log10
        self.proc { |v| MB::FastSound.narray_log10(v) }
      end

      # Interprets incoming samples as a number of decibels, outputting the
      # corresponding linear amplitude.  This treats ADSREnvelope specially,
      # converting to an exponential envelope with a default range of -80dB
      # (controllable with the +env_range+ parameter).
      def db(env_range = nil)
        if self.is_a?(MB::Sound::ADSREnvelope)
          env_range ||= 80
          env_range = env_range.abs
          env_min = (-env_range).db
          env_comp = 1.0 / (1.0 - env_min)
          # TODO: Implement this in C if it's slow
          (10 ** ((self * env_range - env_range) / 20) - env_min) * env_comp
        else
          raise 'Do not specify envelope range if .db is not applied to an envelope' if env_range
          10 ** (self / 20)
        end
      end
      alias dB db

      # Wraps the numeric in a MB::Sound::Constant so that numeric values can
      # be listed first in signal graph arithmetic operations.
      def coerce(numeric)
        [numeric.constant, self]
      end

      # Adds a Ruby block to a processing chain.  The block will be called with
      # a Numo::NArray containing samples to be modified.  Note that this can
      # be very slow compared to the built-in algorithms implemented in C.
      def proc(*sources, &block)
        sources << self

        # TODO: Should this maybe be its own class?
        class << block
          include ArithmeticMixin

          attr_reader :sources, :orig, :callers

          def sample(count)
            data = @orig.sample(count)
            return nil if data.nil?
            call(data)
          end

          def sources
            @sources
          end
        end

        # TODO: is there a better way to pass a closure or otherwise pass a
        # value into a singleton class or singleton method?  It feels like I've
        # done this before somewhere but can't recall.
        block.instance_variable_set(:@orig, self)
        block.instance_variable_set(:@sources, sources)
        block.instance_variable_set(:@callers, caller_locations(4))

        block
      end

      # Applies the given filter (creating the filter if given a filter type)
      # to this sample source or sample chain.  If given a filter type, then a
      # dynamically updating filter is created where teh cutoff and quality are
      # controlled by the given sample sources (e.g. numeric value, tone
      # generator, audio input, or ADSR envelope).
      #
      # Defaults to generating a low-pass filter if given a frequency in Hz.
      #
      # Example:
      #     # Simple low-pass filter at 1200Hz center frequency
      #     MB::Sound.play 500.hz.ramp.filter(1200.hz)
      #
      #     # Low-pass filter with center frequency sweeping between 500 and 1000 Hz
      #     MB::Sound.play 500.hz.ramp.filter(cutoff: 0.2.hz.at(500), quality: 4)
      #
      #     # High-pass filter controlled by envelopes
      #     MB::Sound.play 500.hz.ramp.filter(:highpass, frequency: adsr() * 1000 + 100, quality: adsr() * -5 + 6)
      def filter(filter_or_type = :lowpass, cutoff: nil, quality: nil, in_place: true, rate: 48000)
        f = filter_or_type
        f = f.hz if f.is_a?(Numeric)
        f = f.lowpass if f.is_a?(Tone)

        case
        when f.is_a?(Symbol)
          raise 'Cutoff frequency must be given when creating a filter by type' if cutoff.nil?

          quality = quality || 0.5 ** 0.5
          f = MB::Sound::Filter::Cookbook.new(filter_or_type, rate, 1, quality: 1)
          MB::Sound::Filter::Cookbook::CookbookWrapper.new(filter: f, audio: self, cutoff: cutoff, quality: quality)

        when f.respond_to?(:wrap)
          if cutoff || quality
            raise 'Cutoff frequency and quality should only be specified when creating a new filter by type'
          end

          f.wrap(self, in_place: in_place)

        when f.respond_to?(:process)
          MB::Sound::SampleWrapper.new(f, self, in_place: in_place)

        else
          raise "Unsupported filter type: #{filter_or_type.inspect}"
        end
      end

      # Wraps this arithmetic signal graph in a softclip effect.
      def softclip(threshold = 0.25, limit = 1.0)
        MB::Sound::Filter::SampleWrapper.new(
          MB::Sound::SoftestClip.new(threshold: threshold, limit: limit),
          self
        )
      end

      # Overridden by users of this mixin to return the inputs to the current
      # object.  For example, a Mixer will return a list of objects that are
      # added together by that mixer, as well as any constant DC offset
      # applied.
      #
      # See #graph for a method that returns every source feeding into this
      # node.
      def sources
        []
      end

      # Returns a list of all nodes feeding into this node, either directly or
      # indirectly.
      def graph
        source_history = Set.new
        source_queue = [self]

        until source_queue.empty?
          s = source_queue.shift
          next if source_history.include?(s)

          source_history << s
          source_queue.concat(s.sources) if s.respond_to?(:sources)
        end

        source_history.to_a
      end

      # Looks for the first source node within the graph feeding into this node
      # with the given name.
      def find_by_name(name)
        graph.find { |s| s.respond_to?(:graph_node_name) && s.graph_node_name == name }
      end

      # Returns a String containing a GraphViz representation of the signal
      # graph.
      def graphviz
        source_history = Set.new
        source_queue = [self]

        digraph = "digraph {\n"

        until source_queue.empty?
          s = source_queue.shift
          next if source_history.include?(s)

          n2 = s.is_a?(Numeric) ? s.to_s : "#{s.class} (#{s.graph_node_name}/#{s.__id__})"
          digraph << "  #{n2.inspect};\n"

          source_history << s

          if s.respond_to?(:sources)
            s.sources.each do |src|
              n1 = src.is_a?(Numeric) ? src.to_s : "#{src.class} (#{src.graph_node_name}/#{src.__id__})"
              digraph << "  #{n1.inspect} -> #{n2.inspect};\n"
            end

            source_queue.concat(s.sources) if s.respond_to?(:sources)
          end
        end

        digraph << "}\n"

        digraph
      end

      private

      # Sets tones to play forever at full volume, if they don't have a fixed
      # volume and duration set.
      def fixup_tones(fix_amp, *tones)
        tones.each do |t|
          t.or_for(nil) if t.respond_to?(:or_for) # Default to playing forever
          t.or_at(1) if fix_amp && t.respond_to?(:or_at) # Default to full volume
        end
      end
    end
  end
end
