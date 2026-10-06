module MB
  module Sound
    module GraphNode
      # Side outputs of a node that aren't audio channels (e.g. a tone's
      # sync pulses, Tone#wraps), so they aren't part of #outputs and
      # per-channel DSL calls don't fan them out.  Each port is a GraphNode
      # (a Port) made on first use, so it can be patched, plotted, or
      # counted like any signal; nodes that never use a port behave exactly
      # as before.
      #
      # Including classes declare ports with `port :name, 'description'`,
      # which defines an accessor (`node.wraps`), compute their main output
      # in #sample_main(count), define #sample(count) as
      # `port_frame(count) { sample_main(count) }`, and implement
      # #compute_ports(count) to fill #store_port for each port in use after
      # each frame (see Tone, Sequence::TempoNode).
      #
      # Once a port exists, the node computes its main output and ports in
      # frames: each reader (the main output and each port) reads each frame
      # once, and a reader asking again starts the next frame.  So every
      # reader must read every buffer, as a Session does (like the outputs of
      # a ChannelMixer).  A node read only through its ports (e.g. a phasor
      # used only for sync) still advances.
      #
      # Introspection for UIs: `node.ports` (the ports in use), and
      # `node.class.port_specs` / `node.port_info` (every declared port with
      # its description).
      #
      # Example (bin/sound.rb):
      #     plot 110.hz.phasor.wraps, samples: 2000
      module Ports
        # One port of a node (see Ports).
        class Port
          include GraphNode

          # The node this is a port of.
          attr_reader :owner

          # The port's name (e.g. :wraps).
          attr_reader :port_name

          def initialize(owner, name)
            @owner = owner
            @port_name = name
            @graph_node_name = "#{owner.graph_node_name}.#{name}"
          end

          # Returns +count+ samples of this port (see Ports).
          def sample(count)
            @owner.read_port(@port_name, count)
          end

          def sources
            { owner: @owner }
          end

          def sample_rate
            @owner.sample_rate
          end

          def sample_rate=(rate)
            @owner.sample_rate = rate
            self
          end
          alias at_rate sample_rate=
        end

        module ClassMethods
          # Declares a port +name+ with a +description+ (for #port_info), and
          # an accessor method of the same name.
          def port(name, description)
            port_specs[name] = description
            define_method(name) { port(name) }
          end

          # The declared ports: { name => description }, including those of
          # superclasses.
          def port_specs
            @port_specs ||= superclass.respond_to?(:port_specs) ? superclass.port_specs.dup : {}
          end
        end

        def self.included(base)
          base.extend(ClassMethods)
        end

        # Returns the Port named +name+, creating it on first use.
        def port(name)
          raise ArgumentError, "#{self.class} has no port #{name.inspect}" unless self.class.port_specs.include?(name)

          @ports ||= {}
          @ports[name] ||= Port.new(self, name).tap { port_setup }
        end

        # The ports in use: { name => Port }.
        def ports
          @ports || {}
        end

        # Every declared port's name and description.
        def port_info
          self.class.port_specs.map { |name, description| { name: name, description: description, in_use: ports.include?(name) } }
        end

        # For Port#sample: returns +count+ samples of port +name+ for the
        # current frame, starting the next frame if this port already read
        # the current one (see Ports).
        def read_port(name, count)
          next_frame(count) if @port_read[name] == @frame_number
          return nil if @main_data.nil?

          check_frame_count(count, name)
          @port_read[name] = @frame_number
          @port_data[name]
        end

        # Stores port +name+'s data for the current frame (from
        # #compute_ports).
        def store_port(name, data)
          @port_data[name] = data
        end

        private

        # Called by the including class's #sample around computing +count+
        # samples of its main output (the block).  Without ports this just
        # runs the block; with ports it returns the current frame's main
        # output if the main output hasn't read it yet.
        def port_frame(count)
          return yield if @ports.nil?

          if @main_read == @frame_number
            next_frame(count) { yield }
          end

          check_frame_count(count, :main)
          @main_read = @frame_number
          @main_data
        end

        def next_frame(count, &block)
          @frame_number += 1
          @frame_count = count
          @main_data = block ? block.call : sample_main(count)
          @frame_count = @main_data.length if @main_data
          compute_ports(@frame_count) if @main_data
        end

        def check_frame_count(count, reader)
          return if @main_data.nil? || count == @frame_count

          raise ArgumentError, "#{reader} of #{self} read #{count} samples, but this frame has #{@frame_count} (every reader of a node with ports must read the same buffer size)"
        end

        def port_setup
          return if @frame_number

          @frame_number = 0
          @main_read = 0
          @frame_count = nil
          @main_data = nil
          @port_read = Hash.new(0)
          @port_data = {}
        end
      end
    end
  end
end
