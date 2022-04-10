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
    # There are more examples in the bin/ directory, such as bin/flanger.rb
    #
    # TODO: Standardize a way to modify an existing graph, e.g. to inject a
    # tee, filter, or tap.
    #
    # TODO: Standardize a way to detect controls on a node and their data types
    # and ranges.  E.g. maybe a #controls method that returns a map from method
    # name to an array of ranges (or, lol, a ClassyHash array schema)
    #
    # TODO: In-line method to create a meter?
    #
    # TODO: Rename this module to GraphNodeMixin or similar?
    module GraphNode
      attr_reader :graph_node_name

      # Gives a name to this graph node to make it easier to retrieve later.
      def named(n)
        @graph_node_name = n&.to_s
        self
      end

      # Returns the class name of the node plus the node's assigned name.
      def to_s
        "#{self.class.name}/#{@graph_node_name || __id__}"
      end

      # Returns +n+ (default 2) fan-out readers for creating branching signal
      # graphs.  This is useful because the #sample method can only be called
      # once per frame because it updates the internal state of signal nodes.
      # Each fan-out reader gets a copy of the input buffer, so downstream
      # nodes can call #sample (once per cycle!) on their branch of the tee and
      # modify the resulting buffer without affecting parallel branches of the
      # graph.
      #
      # Example (for bin/sound.rb):
      #     # AM and tremolo added together for some reason
      #     a, b = 120.hz.tee ; nil
      #     c = a * 150.hz.at(0.5..1) + b * 0.5.hz.at(0.25..1) ; nil
      #     play c
      def tee(n = 2)
        Tee.new(self, n).branches
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

      # Uses this node as the frequency value for an oscillator.
      def tone
        MB::Sound::Tone[self]
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

      # Wraps the numeric in a MB::Sound::GraphNode::Constant so that numeric values can
      # be listed first in signal graph arithmetic operations.
      def coerce(numeric)
        [numeric.constant, self]
      end

      # Adds a Ruby block to a processing chain.  The block will be called with
      # a Numo::NArray containing samples to be modified.  Note that this can
      # be very slow compared to the built-in algorithms implemented in C.
      def proc(*sources, &block)
        ProcNode.new(self, sources, &block)
      end

      # If this node (or its inputs) have a finite length of audio data
      # available (e.g. a sound file), then when they run out of data then the
      # given +sources+ (other graph nodes that respond to :sample) will be
      # played after this node finishes.
      def and_then(*sources)
        raise 'No sources were given' if sources.empty?
        MB::Sound::GraphNode::NodeSequence.new([self, *sources])
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

      # Adds a MB::Sound::Filter::Smoothstep filter to the chain, smoothing
      # over the given number of samples or seconds.
      #
      # TODO: instead of reacting to step changes in the input, use an FIR
      # filter whose step response is the smoothstep function.
      def smooth(samples: nil, seconds: nil, rate: 48000)
        filter(MB::Sound::Filter::Smoothstep.new(rate: rate, samples: samples, seconds: seconds))
      end

      # Adds a MB::Sound::Filter::Dealy to the signal chain with a delay of the
      # given number of seconds.
      def delay(seconds: nil, samples: nil, rate: 48000, smoothing: true)
        if samples
          samples = samples.to_f if samples.is_a?(Numeric)
          seconds = samples / rate
        else
          seconds = seconds.to_f if seconds.is_a?(Numeric)
        end

        filter(MB::Sound::Filter::Delay.new(delay: seconds, rate: rate, smoothing: smoothing))
      end

      # Hard-clips the output of this node to the given min and max, one of
      # which may be nil.
      def clip(min, max)
        self.proc { |v| v.clip(min, max) }
      end

      # Wraps this arithmetic signal graph in a softclip effect.
      def softclip(threshold = 0.25, limit = 1.0)
        MB::Sound::Filter::SampleWrapper.new(
          MB::Sound::SoftestClip.new(threshold: threshold, limit: limit),
          self
        )
      end

      # Calls the given block with each sample buffer whenever #sample is
      # called.  Returns self to allow chaining, but this method is also useful
      # after a chain has been constructed for spying on a specific object's
      # output.
      #
      # This is like adding a trace point to tap into a circuit, and allows
      # intermediate values in a signal graph to be plotted or saved.
      #
      # The block should not modify the buffer, and should not retain a
      # reference to the buffer.  Instead, the buffer may be copied to an
      # existing buffer using Numo::NArray#[]=:
      #
      #     block_buf[] = spy_buf
      #
      # TODO: accomplish this without monkey patching
      def spy(&block)
        @graph_spies ||= nil

        if @graph_spies.nil?
          @graph_spies = []

          class << self
            def sample(count)
              super(count).tap { |buf|
                MB::M.with_inplace(buf, false) do |b|
                  @graph_spies.each do |s|
                    begin
                      s.call(b)
                    rescue => e
                      warn "Spy #{s} raised #{MB::U.highlight(e)}"
                    end
                  end
                end
              }
            end
          end
        end

        @graph_spies << block

        self
      end

      # Clears any spies attached to this graph node (see #spy).
      def clear_spies
        @graph_spies ||= nil
        @graph_spies&.clear

        self
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

      # Finds the lowest numeric value greater than zero for any graph nodes
      # that have a #buffer_size method.  The idea is that sound card inputs
      # will have the smallest buffer size of any input.
      #
      # If there is no graph node with a buffer_size method, then this method
      # returns nil.
      #
      # TODO: A buffer adapter might be useful.  The MB::Sound::Filter::Delay
      # class is already kind of like one.
      def graph_buffer_size
        size = nil

        graph.each do |n|
          nsize = n.respond_to?(:buffer_size) ? n.buffer_size : nil
          if nsize && nsize > 0 && (size.nil? || nsize < size)
            size = nsize
          end
        end

        size
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

      # Sets all Tones in the graph (or anything else with a #forever method
      # that takes a :recursive parameter) to continue playing forever.
      def forever(recursive: true)
        if recursive
          graph.each do |n|
            n.forever(recursive: false) if n.respond_to?(:forever)
          end
        end

        self
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

    # GN is a shorthand alias for GraphNode
    GN = GraphNode
  end
end

require_relative 'graph_node/constant'
require_relative 'graph_node/input_channel_split'
require_relative 'graph_node/io_sample_mixin'
require_relative 'graph_node/mixer'
require_relative 'graph_node/multiplier'
require_relative 'graph_node/node_sequence'
require_relative 'graph_node/proc_node'
require_relative 'graph_node/tee'
require_relative 'graph_node/multitap_delay'
