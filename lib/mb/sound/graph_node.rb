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
    # TODO: Pass default sample rate through from source nodes or have a
    # graph-global sample rate
    #
    # TODO: Document methods that nodes must implement or override
    module GraphNode
      attr_reader :graph_node_name

      # Gives a name to this graph node to make it easier to retrieve later.
      def named(n)
        @graph_node_name = n&.to_s
        @named = true
        self
      end

      # Returns true if the graph node has been given a custom name.
      def named?
        @named ||= false
      end

      # Returns the class name of the node plus the node's assigned name.
      def to_s
        @graph_node_name ||= nil
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
        Tee.new(get_sampler, n).branches
      end

      # Creates and returns a tee branch from this node.  This is used by
      # consumers of upstream graph nodes like Tone, CookbookWrapper, etc. to
      # allow implicit branching of node outputs.
      #
      # If you need to call this outside of mb-sound internal code or your own
      # custom GraphNode implementations, that's _probably_ a bug in mb-sound.
      def get_sampler
        # TODO: maybe rename to #get_branch to match Tee's naming??
        # TODO: maybe ignore abandoned branches acquired from get_sampler instead of raising a buffer error in Tee?
        @internal_tee ||= Tee.new(self, 0)
        @internal_tee.get_sampler
      end

      # Creates a mixer that adds this node's #sample output to +other+ (a
      # numeric constant or another GraphNode).
      def +(other)
        fixup_tones(false, self, other)
        Mixer.new([self, other], sample_rate: self.sample_rate)
      end

      # Creates a mixer that subtracts +other+ (a numeric constant or another
      # GraphNode) from this node's #sample output.
      def -(other)
        fixup_tones(false, self, other)
        Mixer.new([self, [other, -1]], sample_rate: self.sample_rate)
      end

      # Creates a multiplier that multiplies +other+ (a numeric constant or
      # another GraphNode) by this node's #sample output.
      def *(other)
        fixup_tones(false, self)
        fixup_tones(true, other)
        Multiplier.new([self, other], sample_rate: self.sample_rate)
      end

      # Divides incoming data by +other+, which may be a Numeric or another
      # signal graph.  For signal graphs, each numerator value is divided
      # by the corresponding denominator value at the same index.
      def /(other)
        # TODO: can we deduplicate arithmetic proc nodes?
        if other.respond_to?(:sample)
          self.proc(other) { |v|
            next nil if v.nil? || v.empty?

            data = other.sample(v.length)

            if data.nil? || data.empty?
              nil
            else
              if data.length != v.length
                # TODO: allow choosing between zero padding and truncation?
                min_length = MB::M.min(data.length, v.length)
                data = data[0...min_length]
                v = v[0...min_length]
              end

              # We can't return v in case types differ, as the type promotion
              # will create a new object.
              # TODO: should we be operating in place here?  This could modify
              # the source of an upstream ArrayInput for example.
              v.inplace!
              (v / data).not_inplace!
            end
          }
        else
          self.proc(other) { |v|
            if v.nil? || v.empty?
              nil
            else
              v.inplace!
              (v / other).not_inplace!
            end
          }
        end
      end

      # Appends a node that raises the incoming values to +other+, which should
      # be either a numeric or another signal graph.
      def **(other)
        # TODO: can we deduplicate arithmetic proc nodes?
        if other.respond_to?(:sample)
          self.proc(other) { |v|
            next nil if v.nil? || v.empty?

            data = other.sample(v.length)

            if data.nil? || data.empty?
              nil
            else
              if data.length != v.length
                # TODO: allow choosing between zero padding and truncation?
                min_length = MB::M.min(data.length, v.length)
                data = data[0...min_length]
                v = v[0...min_length]
              end

              # We can't return v in case types differ, as the type promotion
              # will create a new object.
              # TODO: should we be operating in place here?  This could modify
              # the source of an upstream ArrayInput for example.
              v.inplace!
              (v ** data).not_inplace!
            end
          }
        else
          self.proc(other) { |v|
            if v.nil? || v.empty?
              nil
            else
              v.inplace!
              (v ** other).not_inplace!
            end
          }
        end
      end

      # Appends a node that returns the real value of a complex signal, or the
      # unmodified value of a real signal.
      def real
        MB::Sound::GraphNode::ComplexNode.new(self, mode: :real)
      end

      # Appends a node that returns the real value of a complex signal, or
      # zeros for a real signal.
      def imag
        MB::Sound::GraphNode::ComplexNode.new(self, mode: :imag)
      end

      # Appends a node that returns the magnitude of a complex signal, or the
      # absolute value of a real signal.
      def abs
        MB::Sound::GraphNode::ComplexNode.new(self, mode: :abs)
      end

      # Appends a node that returns the instantaneous phase of a complex
      # signal, or zeros or Math::PI for a real signal.
      def arg
        MB::Sound::GraphNode::ComplexNode.new(self, mode: :arg)
      end

      # Truncates values from the node to the next lower integer.
      def floor
        self.proc(&:floor)
      end

      # Raises values from the node to the next higher integer.
      def ceil
        self.proc(&:ceil)
      end

      # Rounds values from the node to the nearest integer.
      def round
        self.proc(&:round)
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

      # Appends a node that calculates the base ten logarithm of values passing
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
          # TODO: Do this with polymorphism? (move to ADSREnvelope)
          # TODO: This interface for converting an envelope to logarithmic doesn't feel quite right; it shouldn't be called db.
          # TODO: Maybe create an exponential envelope?  Or allow shaping individual phases within the ADSREnvelope?
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
        [numeric.constant(sample_rate: self.sample_rate), self]
      end

      # Adds a Ruby block to a processing chain.  The block will be called with
      # a Numo::NArray containing samples to be modified.  Note that this can
      # be very slow compared to the built-in algorithms implemented in C.
      def proc(*sources, &block)
        ProcNode.new(self, sources, sample_rate: self.sample_rate, &block)
      end

      # If this node (or its inputs) have a finite length of audio data
      # available (e.g. a sound file), then when they run out of data then the
      # given +sources+ (other graph nodes that respond to :sample) will be
      # played after this node finishes.
      def and_then(*sources)
        raise 'No sources were given' if sources.empty?
        MB::Sound::GraphNode::NodeSequence.new([self, *sources])
      end

      # Calls #sample with +count+ requested samples +times+ times,
      # concatenating the results into a single array.
      def multi_sample(count, times)
        raise "Count must be a positive Integer (got #{count.inspect})" unless count.is_a?(Integer) && count > 0
        raise "Times must be a positive Integer (got #{count.inspect})" unless times.is_a?(Integer) && times > 0

        ret = nil
        endidx = 0

        for i in 0...times
          idx = endidx

          d = sample(count)
          break if d.nil? || d.empty?

          ret ||= d.class.zeros(count * times)

          endidx = idx + d.length
          ret[idx...endidx] = d
        end

        ret[0...endidx] if ret
      end

      # Appends a BufferAdapter to the graph with this node as its upstream
      # source, using the given +length+ as the upstream frame size.  When
      # downstream nodes sample the adapter, the adapter will sample the
      # upstream node in +length+-sized chunks.  This allows running a node
      # graph with a shorter internal buffer size than the sound card input or
      # output buffer size, for example.
      def with_buffer(length)
        MB::Sound::GraphNode::BufferAdapter.new(upstream: self, upstream_count: length)
      end

      # Adds a resampling filter to the graph with the given new sample rate.
      # All nodes added after the resampling node must use the new sample rate.
      #
      # The resampling +:mode+ must be one of the supported modes listed in
      # MB::Sound::GraphNode::Resample::MODES (e.g. :libsamplerate_best).
      def resample(sample_rate = self.sample_rate, mode: MB::Sound::GraphNode::Resample::DEFAULT_MODE)
        MB::Sound::GraphNode::Resample.new(upstream: self, sample_rate: sample_rate, mode: mode)
      end

      # Tells this node and all upstream nodes to run at +multiplier+ times the
      # current sample rate, then appends a Resample node to restore the
      # current sample rate.  The +multiplier+ may also be less than one to
      # undersample, and may be fractional (for most node types).
      #
      # For example, compare the sound of the following (turn volume down):
      #
      #     # No oversampling; has prominent lower frequency aliasing
      #     play 355.hz.pm(630.hz.at(100) * 0.5.hz.drumramp.at(0.9..1).filter(10.hz.lowpass)).forever
      #     # With oversampling; does not have the same aliasing
      #     play 355.hz.pm(630.hz.at(100) * 0.5.hz.drumramp.at(0.9..1).filter(10.hz.lowpass)).oversample(16).forever
      def oversample(multiplier, mode: MB::Sound::GraphNode::Resample::DEFAULT_MODE)
        current_rate = self.sample_rate
        self.at_rate(current_rate * multiplier).resample(current_rate, mode: mode)
      end

      # Multiplies this envelope by an ADSR envelope with the given +attack+,
      # +decay+, +sustain+, and +release+ parameters, with times in seconds,
      # and +sustain+ ranging from 0 to 1 (typically).
      #
      # If +:log+ is given, then the envelope will be converted to a
      # logarithmic envelope ranging from +:log+ decibels (e.g. `-30`) to 1.0.
      #
      # If the +:auto_release+ parameter is a number of seconds (defaults to 2x
      # attack + decay, or 0.25, whichever is longer; set it to false to
      # disable), then the envelope will release automatically after that time.
      def adsr(attack, decay, sustain, release, log: nil, auto_release: nil, filter_freq: 10000)
        if auto_release.nil?
          auto_release = 2.0 * (attack + decay)
          auto_release = 0.1 if auto_release < 0.1
        end

        env = MB::Sound::ADSREnvelope.new(
          attack_time: attack,
          decay_time: decay,
          sustain_level: sustain,
          release_time: release,
          sample_rate: self.sample_rate,
          filter_freq: filter_freq
        )

        env.trigger(1.0, auto_release: auto_release)

        # TODO: this log parameter still doesn't seem like the right interface
        env = env.db(log) if log

        self * env
      end

      # Applies the given filter (creating the filter if given a filter type)
      # to this sample source or sample chain.  If given a filter type, then a
      # dynamically updating filter is created where the cutoff and quality are
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
      def filter(filter_or_type = :lowpass, cutoff: nil, quality: nil, gain: nil, in_place: true)
        f = filter_or_type
        f = f.hz if f.is_a?(Numeric)
        f = f.lowpass if f.is_a?(Tone)

        if f.respond_to?(:sample_rate)
          if f.sample_rate != self.sample_rate
            if f.respond_to?(:sample_rate=)
              f.sample_rate = self.sample_rate
            elsif f.respond_to?(:at_rate)
              f = f.at_rate(self.sample_rate)
            else
              warn "Filter #{f} sample rate is #{f.sample_rate} while node #{self} sample rate is #{self.sample_rate}"
            end
          end
        end

        case
        when f.is_a?(Symbol)
          raise 'Cutoff frequency must be given when creating a filter by type' if cutoff.nil?

          quality = quality || 0.5 ** 0.5
          # TODO: Support graph node sources for filter gain
          f = MB::Sound::Filter::Cookbook.new(filter_or_type, sample_rate, 1, quality: 1, db_gain: gain&.to_db)
          MB::Sound::Filter::Cookbook::CookbookWrapper.new(filter: f, audio: self, cutoff: cutoff, quality: quality)

        when f.respond_to?(:wrap)
          if cutoff || quality || gain
            raise 'Cutoff, gain, and quality should only be specified when creating a new filter by type'
          end

          # FIXME: use CookbookWrapper if given a Cookbook filter

          f.wrap(self, in_place: in_place)

        when f.respond_to?(:process)
          if cutoff || quality || gain
            raise 'Cutoff, gain, and quality should only be specified when creating a new filter by type'
          end

          MB::Sound::SampleWrapper.new(f, self, in_place: in_place)

        else
          raise "Unsupported filter type: #{filter_or_type.inspect}"
        end
      end

      # Adds a filter chain that applies parametric peaking EQ.  The +pairs+
      # parameter should be a Hash mapping a frequency in Hz (or a Tone) to a
      # linear gain, or an Array with gain and bandwith in octaves (the default
      # bandwidth is 1/3 octave).
      #
      # Example:
      #     # Reduce second harmonic (or first if you count from zero)
      #     100.hz.ramp.peq(200.hz => -6.db)
      #
      #     # Cut mids
      #     100.hz.ramp.peq(500.hz => [-10.db, 4])
      def peq(pairs)
        raise "PEQ frequency/gain pairs must be a Hash from frequency to gain (got #{pairs.class})" unless pairs.is_a?(Hash)

        filters = pairs.map { |freq, gain|
          freq = freq.frequency if freq.is_a?(Tone)
          freq = freq.to_f

          if gain.is_a?(Array)
            gain, bandwidth = gain
          else
            bandwidth = 1.0 / 3.0
          end

          MB::Sound::Filter::Cookbook.new(:peak, self.sample_rate, freq, db_gain: gain.to_db, bandwidth_oct: bandwidth)
        }

        # TODO: Expose PEQ parameters for MIDI control
        chain = MB::Sound::Filter::FilterChain.new(filters)

        self.filter(chain)
      end

      # Applies an IIR phase difference network to remove negative frequencies
      # and produce a Complex-valued analytic signal.
      #
      # See MB::Sound::Filter::HilbertIIR.
      def hilbert_iir(sample_rate: 48000)
        filter(MB::Sound::Filter::HilbertIIR.new(sample_rate: sample_rate))
      end

      # Adds a MB::Sound::Filter::Smoothstep filter to the chain, smoothing
      # over the given number of samples or seconds.
      #
      # TODO: instead of reacting to step changes in the input, use an FIR
      # filter whose step response is the smoothstep function.
      def smooth(samples: nil, seconds: nil, sample_rate: 48000)
        filter(MB::Sound::Filter::Smoothstep.new(sample_rate: sample_rate, samples: samples, seconds: seconds))
      end

      # Adds a MB::Sound::Filter::Delay to the signal chain with a delay of the
      # given number of +:seconds+ or +:samples+.
      #
      # See MB::Sound::Filter::Delay#initialize for a description of the
      # +:smoothing+ parameter.
      def delay(seconds: nil, samples: nil, sample_rate: 48000, smoothing: true, max_delay: 1.0)
        if samples
          samples = samples.to_f if samples.is_a?(Numeric)
          seconds = samples / sample_rate
        else
          seconds = seconds.to_f if seconds.is_a?(Numeric)
        end

        filter(MB::Sound::Filter::Delay.new(delay: seconds, sample_rate: sample_rate, smoothing: smoothing, buffer_size: sample_rate.ceil * max_delay))
      end

      # Adds a multi-tap delay with the given delay sources, returning an Array
      # of nodes representing the taps.  The +delays+ may be numeric values in
      # seconds, or graph nodes that produce a number of seconds as output.
      #
      # To smooth delay values, use #clip_rate, #smooth, #filter, or similar
      # methods (unlike the filter used by #delay, the
      # MB::Sound::GraphNode::MultitapDelay does not do built-in smoothing).
      def multitap(*delays, sample_rate: 48000, name: nil, initial_buffer_seconds: 1)
        MB::Sound::GraphNode::MultitapDelay.new(
          self,
          *delays,
          sample_rate: sample_rate,
          initial_buffer_seconds: initial_buffer_seconds
        ).named(name).taps
      end

      # Hard-clips the output of this node to the given min and max, one of
      # which may be nil to disable clipping in that direction.
      def clip(min, max)
        self.proc { |v| v.clip(min, max) }
      end

      # Hard-clips the slope of the output of this node to the given +max_rise+
      # and +max_fall+, in units per second.  If only one value is specified,
      # then the other value will be set to its negative.
      #
      # A value of zero for +max_fall+ outputs a cumulative maximum value, and
      # similarly for +max_rise+.
      #
      # The +:reset+ parameter may be used to set an initial value for the
      # output before any slope limiting is applied.
      #
      # This method is useful for interpolating changes to constant values (see
      # also #smooth and #filter).
      #
      # Uses MB::Sound::Filter::LinearFollower.
      def clip_rate(max_rise, max_fall = nil, reset: nil, sample_rate: 48000)
        max_fall ||= -max_rise
        max_rise ||= -max_fall
        f = MB::Sound::Filter::LinearFollower.new(sample_rate: sample_rate, max_rise: max_rise, max_fall: max_fall)
        f.reset(reset) if reset
        self.filter(f)
      end

      # Adds a soft-clipper to the graph.  Values greater than +threshold+ will
      # be smoothly compressed downward, with a value of infinity producing an
      # output of +limit+.
      def softclip(threshold = 0.25, limit = 1.0)
        MB::Sound::Filter::SampleWrapper.new(
          MB::Sound::SoftestClip.new(threshold: threshold, limit: limit),
          self
        )
      end

      # Adds a quantizer to the node graph.  Values will be rounded to the
      # nearest multiple of +increment+.  To quantize to a given number of
      # bits, use e.g. `5.bits`.  An +increment+ of zero means no quantization.
      #
      # The +increment+ may be another GraphNode to apply a time-varying
      # quantization amount.
      def quantize(increment)
        MB::Sound::GraphNode::Quantize.new(upstream: self, increment: increment)
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
                  @graph_spies.each_with_index do |s, idx|
                    begin
                      s.call(b)
                    rescue => e
                      warn "Spy #{idx}/#{s} raised #{MB::U.highlight(e)}"
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

      # Prints changes to the first sample of each buffer to STDOUT, or yields
      # the new value to the block if given.  This is mostly useful for
      # debugging control values, not so useful for oscillators or sound
      # signals.
      def spy_changes
        current_value = nil
        self.spy { |buf|
          if current_value != buf[0]
            current_value = buf[0]

            if block_given?
              yield current_value
            else
              puts "#{graph_node_name} value is now #{current_value}"
            end
          end
        }
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
      # indirectly, plus this node itself, without duplication.  Also may
      # include numeric values used as parameters to some of the nodes.
      #
      # Entries in the returned list should be in order of increasing distance
      # from this node, but if there are loops in the graph this is not
      # guaranteed.
      def graph(include_tees: true)
        # TODO: use a linked list for deletion and reinsertion if this method
        # becomes too slow, or weaken return ordering and memoize in each
        # instance and call graph instead of sources to get sources?
        source_list = []
        source_history = Set.new
        source_queue = [self]

        until source_queue.empty?
          s = source_queue.shift
          s = s.round if s.is_a?(Numeric) && s.respond_to?(:round) && s.round == s

          # TODO: have a separate configuration for manual tees and implied
          # branches from get_sampler, and default to ignoring get_sampler?
          unless include_tees
            s = climb_tee_tree(s)
          end

          if source_history.include?(s)
            source_list.delete(s)
            source_list << s
            next
          end

          source_history << s
          source_list << s

          source_queue.concat(s.sources) if s.respond_to?(:sources)
        end

        source_list
      end

      # Returns a Hash from source node to a Set of destination nodes
      # describing all connections upstream of this graph node.
      def graph_edges(include_tees: true)
        edges = {}

        graph(include_tees: include_tees).each do |n|
          next unless n.respond_to?(:sources)

          # TODO: it would be cool if #sources could give a name to each source
          n.sources.each do |s|
            s = s.round if s.is_a?(Numeric) && s.respond_to?(:round) && s.round == s

            unless include_tees
              s = climb_tee_tree(s)
            end

            edges[s] ||= Set.new
            edges[s] << n
          end
        end

        edges
      end

      # Finds the lowest numeric value greater than zero for any graph nodes
      # that have a #buffer_size method.  The idea is that sound card inputs
      # will have the smallest buffer size of any input.
      #
      # If there is no graph node with a buffer_size method, then this method
      # returns nil.
      #
      # TODO: what should this return when the graph contains a buffer adapter?
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

      # Returns all nodes within this nodes input graph matching the given
      # name.
      def find_all_by_name(name)
        graph.select { |s| s.respond_to?(:graph_node_name) && s.graph_node_name == name }
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

      # Sets all Tones in the graph to continue playing forever.
      def for(duration, recursive: true)
        if recursive
          graph.each do |n|
            next if n == self
            n.for(duration, recursive: false) if n.respond_to?(:for)
          end
        end

        self
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

      # Walk up sources until a non-Tee::Branch node is found.  Used by #graph.
      def climb_tee_tree(branch)
        while branch.is_a?(MB::Sound::GraphNode::Tee::Branch)
          branch = branch.sources[0]
        end
        branch
      end
    end

    # GN is a shorthand alias for GraphNode
    GN = GraphNode
  end
end

require_relative 'graph_node/arithmetic_node_helper'
require_relative 'graph_node/sample_rate_helper'

require_relative 'graph_node/constant'
require_relative 'graph_node/input_channel_split'
require_relative 'graph_node/io_sample_mixin'
require_relative 'graph_node/mixer'
require_relative 'graph_node/multiplier'
require_relative 'graph_node/node_sequence'
require_relative 'graph_node/proc_node'
require_relative 'graph_node/tee'
require_relative 'graph_node/multitap_delay'
require_relative 'graph_node/complex_node'
require_relative 'graph_node/buffer_adapter'
require_relative 'graph_node/resample'
require_relative 'graph_node/quantize'
