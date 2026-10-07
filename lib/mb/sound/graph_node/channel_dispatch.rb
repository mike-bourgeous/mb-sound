module MB
  module Sound
    module GraphNode
      # Per-channel values given as an argument to a DSL method, created by
      # MB::Sound#channels with numbers or other non-node values (e.g.
      # `channels(0.010, 0.013)` or `channels(3.n16, 5.n16)`).  The method
      # runs once per channel with each value (see ChannelDispatch).
      class ChannelValues
        # The values, one per channel.
        attr_reader :values

        def initialize(values)
          raise ArgumentError, 'Per-channel values need at least one value' if values.empty?
          @values = values.freeze
        end

        # The number of channels these values are for.
        def size
          @values.length
        end

        # The value for channel +index+ of +count+.
        def value(index, _count)
          @values[index]
        end

        def to_s
          @values.map(&:to_s).join(' | ')
        end
      end

      # Values spread evenly across however many channels a DSL method runs
      # on, created by MB::Sound#spread (e.g. `spread(0..Math::PI)` gives 0
      # and PI for two channels, 0, PI/2, and PI for three).
      class ChannelSpread
        # The range of values.
        attr_reader :range

        def initialize(range)
          raise ArgumentError, "Spread takes a Range (got #{range.inspect})" unless range.is_a?(Range)
          @range = range
        end

        # A spread fits any channel count.
        def size
          nil
        end

        # The value for channel +index+ of +count+.
        def value(index, count)
          return @range.begin if count == 1
          @range.begin + (@range.end - @range.begin) * index / (count - 1).to_f
        end

        def to_s
          "spread(#{@range})"
        end
      end

      # The nodes made by one per-channel DSL call (see ChannelDispatch), so
      # graph visualizations can show them as one box (see
      # Traversable#graphviz).  +inputs+ are the channels the method ran on,
      # +members+ the resulting nodes, +params+ descriptions of the
      # arguments that differed per channel, and +arg_nodes+ graph nodes
      # passed as arguments (which stay visible outside the box).
      ChannelGroup = Struct.new(:method_name, :inputs, :members, :params, :arg_nodes) do
        # A label like "filter ×2\ncutoff: 800, 1200".
        def label
          ["#{method_name} ×#{members.length}", *params].join("\n")
        end
      end

      # Runs DSL methods once per channel when they are called on a
      # multichannel node (e.g. a stereo bundle) or given per-channel
      # arguments (bundles, ChannelValues, or ChannelSpread), returning a
      # Channels bundle of the results.  Single-channel nodes without
      # per-channel arguments run the method unchanged.
      #
      # Channel counts combine like NumPy broadcasting: single channels are
      # used for every channel, equal counts go channel by channel, and
      # other mismatches raise an error.
      #
      # The per-channel versions are generated from the public methods of
      # every *Methods module included in GraphNode (see .refresh!), except
      # EXCLUDED methods that don't make sense per channel or that handle
      # channels themselves (e.g. #reverb).  They are prepended to GraphNode
      # and included in Channels.  Including a new *Methods module in
      # GraphNode refreshes them automatically; call .refresh! after adding
      # methods to an existing module.
      module ChannelDispatch
        # DSL methods that never run per channel.
        EXCLUDED = [
          :get_sampler, :tee, :as_input, :multi_sample, :coerce,
          :spy, :debug, :clear_spies,
          :reverb, :fdn_reverb, :multitap, :multitap_delay,
          :samples, :seconds,
          :loudness_meter, :lufs_meter,
        ].freeze

        # Modules included in GraphNode that aren't per-channel DSL methods.
        NOT_DSL = [:ChannelMethods].freeze

        # Defines per-channel versions of every DSL method that doesn't have
        # one yet.  Returns the names defined.
        def self.refresh!
          names = GraphNode.included_modules
            .select { |m| m.name&.end_with?('Methods') && m.name.start_with?('MB::Sound::GraphNode::') }
            .reject { |m| NOT_DSL.include?(m.name.rpartition('::').last.to_sym) }
            .flat_map { |m| m.public_instance_methods(false) }
            .uniq - EXCLUDED

          (names - Generated.instance_methods(false)).each do |name|
            Generated.define_method(name) do |*args, **kwargs, &block|
              ChannelDispatch.call(self, name, args, kwargs, block) { super(*args, **kwargs, &block) }
            end
          end
        end

        # Runs +name+ per channel if +receiver+ or the arguments are
        # multichannel, or yields to run it normally otherwise.
        def self.call(receiver, name, args, kwargs, block)
          count = channel_count(receiver, args, kwargs)
          if count == 1 && !receiver.is_a?(Channels) && receiver.channel_count == 1
            return yield
          end

          inputs = receiver.outputs
          channel_inputs = []
          picked = []
          results = Array.new(count) { |i|
            channel = inputs.length == 1 ? inputs[0] : inputs[i]
            channel_args = args.map { |a| pick(a, i, count) }
            channel_kwargs = kwargs.transform_values { |v| pick(v, i, count) }
            channel_inputs << channel
            picked << [channel_args, channel_kwargs]
            channel.public_send(name, *channel_args, **channel_kwargs, &block)
          }

          arg_nodes = picked.flat_map { |(pa, pk)| (pa + pk.values).grep(GraphNode) }
          group = ChannelGroup.new(name, channel_inputs, results, per_channel_params(args, kwargs, picked), arg_nodes)
          results.each { |r| r.channel_group = group if r.respond_to?(:channel_group=) }

          Channels.new(results)
        end

        # Describes the arguments that differ per channel, e.g.
        # "cutoff: 800, 1200", for graph visualizations (| would split the
        # record-shaped GraphViz nodes).
        def self.per_channel_params(args, kwargs, picked)
          described = args.each_with_index.filter_map { |a, idx|
            next unless per_channel?(a)
            "arg #{idx + 1}: #{picked.map { |(pa, _)| describe(pa[idx]) }.join(', ')}"
          }
          described + kwargs.filter_map { |k, v|
            next unless per_channel?(v)
            "#{k}: #{picked.map { |(_, pk)| describe(pk[k]) }.join(', ')}"
          }
        end

        # True if +value+ is a per-channel argument.
        def self.per_channel?(value)
          value.is_a?(ChannelSpread) || !size_of(value).nil?
        end

        # A short description of an argument value.
        def self.describe(value)
          case value
          when Float then MB::M.sigfigs(value, 4).to_s
          when Numeric, Sequence::Duration then value.to_s
          when GraphNode then value.graph_node_name || value.node_type_name
          else value.class.name.rpartition('::').last
          end
        end

        # Returns the channel count for running a method on +receiver+ with
        # +args+ and +kwargs+ (see the module description).
        def self.channel_count(receiver, args, kwargs)
          sizes = [receiver.channel_count] + (args + kwargs.values).filter_map { |v| size_of(v) }
          counts = sizes.uniq - [1]
          raise ArgumentError, "Can't combine #{counts.join(' and ')} channels; convert one first (e.g. .mono or .stereo)" if counts.length > 1

          count = counts.first || 1
          if count == 1 && (args + kwargs.values).any?(ChannelSpread)
            raise ArgumentError, 'spread(...) needs a multichannel signal to spread over (e.g. call .stereo first)'
          end
          count
        end

        # The channel count of a per-channel argument, or nil.
        def self.size_of(value)
          case value
          when ChannelValues
            value.size
          when Channels, MultiOutput
            value.channel_count
          when GraphNode
            value.channel_count > 1 ? value.channel_count : nil
          end
        end

        # The argument for channel +index+ of +count+.  Filter objects (e.g.
        # 150.hz.highpass) are copied for every channel after the first so
        # the channels don't share filter state.
        def self.pick(value, index, count)
          case value
          when ChannelValues, ChannelSpread
            value.value(index, count)
          when Channels, MultiOutput
            outputs = value.outputs
            outputs.length == 1 ? outputs[0] : outputs[index]
          when GraphNode
            value.channel_count > 1 ? value.outputs[index] : value
          else
            index > 0 && filter_object?(value) ? copy_filter(value) : value
          end
        end

        # True for stateful filter objects that aren't graph nodes.
        def self.filter_object?(value)
          value.is_a?(MB::Sound::Filter) && !value.is_a?(GraphNode)
        end

        # Returns a deep copy of a filter object for another channel.
        def self.copy_filter(filter)
          Marshal.load(Marshal.dump(filter))
        rescue TypeError => e
          raise ArgumentError, "#{filter.class} can't be copied for each channel (#{e.message}); build one per channel, e.g. with channels(...)"
        end

        # Holds the generated per-channel methods (see .refresh!).
        module Generated
        end
      end

      # Only graph nodes and channel bundles get the DSL; internal multi-output
      # plumbing like Tee doesn't.  Methods that return several outputs (e.g.
      # split inputs, multitap taps) return Channels bundles.
      GraphNode.prepend(ChannelDispatch::Generated)
      Channels.include(ChannelDispatch::Generated)

      # Refresh the per-channel methods when GraphNode gains a DSL module.
      class << GraphNode
        def include(*modules)
          super.tap { ChannelDispatch.refresh! if defined?(ChannelDispatch::Generated) }
        end
      end

      ChannelDispatch.refresh!
    end
  end
end
