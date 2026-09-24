require 'shellwords'

require_relative 'graph_node/nameable'
require_relative 'graph_node/traversable'
require_relative 'graph_node/node_output'
require_relative 'graph_node/multi_output'
require_relative 'graph_node/routing_methods'
require_relative 'graph_node/arithmetic_methods'
require_relative 'graph_node/synthesis_methods'
require_relative 'graph_node/resample_methods'
require_relative 'graph_node/filter_methods'

module MB
  module Sound
    # Adds methods to any class that implements a :sample method to build
    # signal generation and processing graphs.  In combination with Tone, Note,
    # and the helper methods in MB::Sound, this creates a DSL that can quickly
    # generate complex sounds.
    #
    # Examples (run in the bin/sound.rb environment):
    #     # FM organ bass
    #     mod = F2.at(300) * adsr(0, 0.1, 0.0, 0.5, auto_release: false)
    #     play F1.at(-6.db).fm(mod) * adsr(0, 0, 1, 0, auto_release: 0.25)
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
    # TODO: Document methods that nodes must implement or override
    #
    # TODO: Split methods in this module into groups and/or related classes
    # (e.g. #wavetable could go into GraphNode::Wavetable)
    module GraphNode
      include Nameable
      include Traversable
      include RoutingMethods
      include ArithmeticMethods
      include SynthesisMethods
      include ResampleMethods
      include FilterMethods

      # Returns the class name, or a custom name set by the subclass (e.g. '/'
      # for a division proc node).
      def node_type_name
        @node_type_name ||= self.class.name.rpartition('::').last
      end

      # Returns the class name of the node plus the node's assigned name or
      # object ID.
      def to_s
        @graph_node_name ||= nil
        "#{node_type_name}/#{@graph_node_name || "id=#{__id__}"}"
      end

      # Returns a multiline description of a node suitable for display in a
      # GraphViz visualization (see #graphviz).
      def to_s_graphviz
        to_s # populate @node_type_name

        <<~EOF
        #{@node_type_name}
        #{@graph_node_name || "id=#{__id__}"}
        #{MB::M.sigformat(sample_rate)}Hz
        EOF
      end

      # Adds a MB::Sound::Filter::Delay to the signal chain with a delay of the
      # given number of +:seconds+ or +:samples+.
      #
      # See MB::Sound::Filter::Delay#initialize for a description of the
      # +:smoothing+ parameter.
      #
      # This can be used for spectral distortion:
      #
      #     graph = (60.hz * 0.5.hz.ramp.at(1..0).with_phase(-Math::PI))
      #       .proc { |v| MB::Sound.real_fft(v) }
      #       .delay(samples: 3208.4, feedback: 0.9, dry: 1, wet: 1)
      #       .proc { |v| MB::Sound.real_ifft(MB::M.shl(v, 0)) }
      def delay(seconds: nil, samples: nil, sample_rate: 48000, smoothing: true, max_delay: 1.0, feedback: false, dry: 0, wet: 1)
        if samples
          samples = samples.to_f if samples.is_a?(Numeric)
          seconds = samples / sample_rate
        else
          seconds = seconds.to_f if seconds.is_a?(Numeric)
        end

        seconds = seconds.or_for(nil) if seconds.respond_to?(:or_for)

        filter(MB::Sound::Filter::Delay.new(
          delay: seconds, sample_rate: sample_rate, smoothing: smoothing,
          delay_buffer_size: sample_rate.ceil * max_delay, feedback: feedback,
          dry: dry, wet: wet
        ))
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

      # Appends a reverb to this node.  Named presets change default
      # parameters, but you can override any of the preset's parameters.
      #
      # If this is a multi-output node (e.g. a splittable input object), then
      # the outputs are broken out as a multichannel input to the Reverb.
      #
      # Presets: :room, :hall, :stadium, :space, :default.  See
      # Reverb::PRESETS.
      #
      # See MB::Sound::GraphNode::Reverb#initialize for parameter descriptions.
      #
      # The +:extra_time+ parameter controls how much time to add to input
      # objects to allow the reverb to decay.
      #
      # If +:output_channels+ is greater than one, then this method returns an
      # Array of output nodes.  Otherwise it returns a single output node.
      #
      # Example (bin/sound.rb):
      #     play file_input('sounds/drums.flac').reverb
      #     play file_input('sounds/piano0.flac').reverb(:space)
      def reverb(preset = :default, extra_time: nil, output_channels: 1, channels: nil, stages: nil, diffusion_range: nil, feedback_range: nil, feedback_gain: nil, feedback_enabled: nil, predelay: nil, wet: nil, dry: nil, seed: nil, show_internals: false)
        MB::Sound::GraphNode::Reverb.reverb(
          preset,
          input: self,
          extra_time: extra_time,
          output_channels: output_channels,
          channels: channels,
          stages: stages,
          diffusion_range: diffusion_range,
          feedback_range: feedback_range,
          feedback_gain: feedback_gain,
          feedback_enabled: feedback_enabled,
          predelay: predelay,
          wet: wet,
          dry: dry,
          seed: seed,
          show_internals: show_internals
        )
      end

      # Adds a reverb effect to this node using diffusion stages and a
      # feedback delay network.  See GraphNode::FdnReverb for details.
      #
      # When called on a MultiOutput node (e.g. from InputChannelSplit),
      # the individual outputs are automatically used as separate input
      # channels to the reverb.
      #
      # When +tail+ is given (in seconds), the reverb continues processing
      # silence after the inputs end, allowing the reverb tail to decay.
      # Defaults to +decay + 0.5+.  Set +tail: 0+ or +tail: false+ to
      # disable.
      #
      # Example:
      #     play 440.hz.sine.for(0.5).fdn_reverb(room_size: 0.8, decay: 3.0)
      #
      #     # Stereo file input -> stereo reverb
      #     play file_input('sounds/synth0.flac').fdn_reverb
      def fdn_reverb(room_size: 0.5, decay: 2.0, damping: 0.5, diffusion_steps: 4, channels: 8, output_channels: nil, wet: 0.3, dry: 0.7, seed: 0, sample_rate: 48000, tail: nil)
        tail = decay + 0.5 if tail.nil?
        tail = 0 if tail == false

        input = if self.is_a?(MultiOutput)
          self.outputs.map { |out|
            node = out.get_sampler
            tail > 0 ? node.and_then(0.constant.for(tail)) : node
          }
        else
          tail > 0 ? self.and_then(0.constant.for(tail)) : self
        end

        MB::Sound::GraphNode::FdnReverb.new(
          input,
          room_size: room_size,
          decay: decay,
          damping: damping,
          diffusion_steps: diffusion_steps,
          channels: channels,
          output_channels: output_channels,
          wet: wet,
          dry: dry,
          seed: seed,
          sample_rate: sample_rate
        )
      end

      # Hard-clips the output of this node to the given min and max, one of
      # which may be nil to disable clipping in that direction.
      def clip(min, max)
        self
          .proc(type_name: 'clip') { |v| v.clip(min, max) }
          .named("clamp #{min}..#{max}")
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
      # You can specify a minimum +:interval+ in seconds to reduce CPU load,
      # and your spy won't be called until at least that amount of time has
      # elapsed, or the value spied changes to/from nil.
      #
      # If you'll need to remove specific spies later, pass a +:handle+.  This
      # may be an object instance, a Symbol, etc.
      #
      # The +:phase+ argument may be :pre to receive the number of samples
      # before a node executes, or :post to receive a copy of the data the node
      # returns.
      #
      # See #clear_spies.
      #
      # TODO: accomplish this without monkey patching, and maybe use a module
      # interface rather than a proc (for better rubyprof traces)
      def spy(handle: nil, interval: false, phase: :post, &block)
        @handled_spies ||= nil

        if @handled_spies.nil?
          @handled_spies = {}

          class << self
            def sample(count)
              call_spies(count, :pre)

              super(count).tap { |buf|
                MB::M.with_inplace(buf, false) do |data|
                  call_spies(data, :post)
                end
              }
            end
          end
        end

        @handled_spies[handle] ||= []
        @handled_spies[handle] << [block, interval, phase, Time.now - (interval || 1), false]

        self
      end

      # Used by #spy.
      private def call_spies(data, phase)
        now = Time.now
        now_nil = data.nil?

        @handled_spies.each do |origin, spies|
          info = origin ? " from #{origin}" : ''

          spies.each_with_index do |spy_info, idx|
            s, interval, spy_phase, last_time, was_nil = spy_info
            next unless spy_phase == phase

            begin
              if !interval || (now - last_time) >= interval || was_nil != now_nil
                s.call(data)
                spy_info[-2] = now
                spy_info[-1] = now_nil
              end
            rescue => e
              warn "Spy #{idx}/#{s}#{info} raised #{MB::U.highlight(e)}"
            end
          end
        end
      end

      # Clears any spies attached to this graph node (see #spy), or just spies
      # associated with the given +:handle+.
      def clear_spies(handle: nil)
        @handled_spies ||= nil

        if handle
          if @handled_spies && @handled_spies.include?(handle)
            @handled_spies[handle].clear
            @handled_spies.delete(handle)
          end
        else
          @handled_spies&.clear
        end

        self
      end

      # Logs the first, last, min, max, and mean values for each buffer from
      # this node.
      def debug
        debug_iter = 0
        spy { |v|
          if v
            s = "f/l: #{v[0]}/#{v[-1]} m/m: #{v.minmax} avg: #{v.mean}"
          else
            s = 'nil'
          end

          puts "DEBUG: #{__id__}/#{self} frame #{debug_iter}: #{s}"

          debug_iter += 1
        }
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

      # Sets all Tones in the graph to continue playing for +duration+.
      def for(duration, recursive: true)
        if recursive
          graph.each do |n|
            next if n == self
            n.for(duration, recursive: false) if n.respond_to?(:for)
          end
        end

        self
      end

      # Sets all Tones in the graph to play for +duration+ by default unless
      # the tone was specifically given a duration.
      def or_for(duration, recursive: true)
        if recursive
          graph.each do |n|
            next if n == self
            n.or_for(duration, recursive: false) if n.respond_to?(:or_for)
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

      # Walk up sources until a "real" node is found, skipping over
      # housekeeping nodes like Tee::Branch.  Used by #graph.
      def self.climb_tee_tree(branch)
        branch = branch.original_source while climb_over?(branch)
        branch
      end

      # Returns true if the given branch should be skipped normally when doing
      # a non-verbose traversal of a node graph.  This e.g. skips tees,
      # branches, adapters, etc.  See .climb_tee_tree and NodeOutput.
      def self.climb_over?(branch)
        branch.is_a?(MB::Sound::GraphNode::NodeOutput)
      end

      # Create a list of upstream nodes from the given graph node.  See #graph.
      def self.graph(node, include_tees: true)
        # TODO: use a linked list for deletion and reinsertion if this method
        # becomes too slow, or weaken return ordering and memoize in each
        # instance and call graph instead of sources to get sources?
        #
        # Start self at -1 visits to preserve ordering when breaking feedback
        # loops
        source_history = { node => -1 }
        source_queue = [node]
        source_list = []

        until source_queue.empty?
          s = source_queue.shift
          s = s.round if s.is_a?(Numeric) && s.respond_to?(:round) && s.finite? && s.round == s

          # TODO: have a separate configuration for manual tees and implied
          # branches from get_sampler, and default to ignoring get_sampler?
          # TODO: allow climbing past nodes of any type or based on any
          # condition, e.g. to skip mixers and multipliers that were created by
          # an internal arithmetic step inside or for another node.  e.g. #adsr
          # creates a multiplier to icombine the input with the envelope.
          # TODO: automatically differentiate between nodes created directly by
          # the user and nodes created implicitly by other nodes?  e.g. could
          # wrap internal node creation within a block that marks those nodes
          # as invisible by default?
          unless include_tees
            s = climb_tee_tree(s)
          end

          # If we encounter a source again, move it to the end of the source
          # list and look at its sources again.
          if source_history.include?(s)
            # TODO: only look at a source if all paths from it have been traveled
            # TODO: this would all be easier if source/dest links were bidirectional
            # TODO: is this a reasonable number?
            if source_history[s] > 50 + source_list.length
              # FIXME: node graph iteration is reporting possible infinite loops on reverb which shouldn't have any loops
              # FIXME: only re-traverse a node if doing so would change its
              # depth; I suspect we're doing an exponential traversal of all
              # possible edge combinations in the reverb graph.
              warn "Possible infinite loop on #{s} (started from #{self}; seen #{source_history[s]} times of #{source_list.length})"
              next
            end

            source_list.delete(s)
          else
            source_history[s] = 0
          end

          source_history[s] += 1
          source_list << s

          source_queue.concat(s.sources.values) if s.respond_to?(:sources)
        end

        source_list
      end

      # Create a rank list for the given graph node (or similar object that
      # responds to #graph).  See #graph_ranks.
      def self.graph_ranks(node, include_tees: true)
        rank_map = { node => 0 }

        (node.graph(include_tees: include_tees) | [node]).each do |dest|
          next if dest.is_a?(Numeric)

          rank_map[dest] ||= 0
          next_rank = rank_map[dest] + 1

          dest.sources.each do |_name, src|
            next if src.is_a?(Numeric)

            src = climb_tee_tree(src) unless include_tees

            rank_map[src] ||= next_rank
            rank_map[src] = MB::M.max(rank_map[src], next_rank)
          end
        end

        ranks = []
        rank_map.each do |n, rank|
          ranks[rank] ||= []
          ranks[rank] << n
        end

        ranks.compact.reverse
      end

      private

      # Instance-method alias for the class method of the same name.
      def climb_tee_tree(branch)
        MB::Sound::GraphNode.climb_tee_tree(branch)
      end

      # Turns a node source, whether Numeric or another node, into a reasonable
      # String representation, skipping Tee branches.
      #
      # The +:separator+ is used for joining terms in arithmetic nodes.
      def make_source_name(numeric_or_node, separator: ' ')
        s = climb_tee_tree(numeric_or_node)
        case
        when s.respond_to?(:graph_node_name) && s.named?
          s.graph_node_name

        when s.respond_to?(:arithmetic_string)
          parenthesize(s.arithmetic_string(separator))

        when s.respond_to?(:name_or_id)
          s.name_or_id

        when s.is_a?(Complex)
          s.to_s

        when s.is_a?(Numeric)
          s.to_nice_s(4)

        else
          s.to_s
        end
      end

      # Adds parentheses around a mathematical statement if it contains any
      # operators or spaces.
      def parenthesize(str)
        if str.match?(/[[:space:][:punct:]]/)
          # TODO: maybe count parenthetical nestings to see if there's already
          # a global parenthesis
          "(#{str})"
        else
          str
        end
      end
    end

    # GN is a shorthand alias for GraphNode
    GN = GraphNode
  end
end

require_relative 'graph_node/arithmetic_node_helper'
require_relative 'graph_node/sample_rate_helper'
require_relative 'graph_node/graph_node_array_mixin'

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
require_relative 'graph_node/data_shuffler'
require_relative 'graph_node/wavetable'
require_relative 'graph_node/matrix_mixer'
require_relative 'graph_node/reverb'
require_relative 'graph_node/fdn_reverb'

require_relative 'graph_node/graph_clock'
