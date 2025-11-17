require 'forwardable'

module MB
  module Sound
    module GraphNode
      # Creates fan-out branches from a signal node (any object that responds to
      # #sample and returns a single audio buffer, and ideally includes the
      # GraphNode module), using buffer copies to prevent parallel branches
      # from interfering with each other.
      #
      # The ideal way to create a Tee is with the GraphNode#tee method or
      # GraphNode#get_sampler method.
      #
      # Note that if a downstream node tries to change the sample rate for one
      # branch, it will change it for all branches and upstream nodes.  So add
      # a .resample node to a branch if you want different branches at
      # different sample rates.
      #
      # Example:
      #     # Runnable in bin/sound.rb
      #     a, b, c = 200.hz.forever.tee(3) ; nil
      #     d = a * 100.hz + b * 200.hz + c * 300.hz ; nil
      #     play d
      class Tee
        extend Forwardable

        # Raised when any branch's internal buffer overflows.  This could
        # happen if the downstream buffer size is significantly larger than the
        # Tee's internal buffer size, or if one branch is being read more than
        # another.
        class BranchBufferOverflow < MB::Sound::CircularBuffer::BufferOverflow; end

        # An individual branch of a Tee, returned by Tee#branches.
        class Branch
          extend Forwardable

          include GraphNode

          attr_reader :index

          def_delegators :@tee, :sample_rate, :sample_rate=, :reset

          # For internal use by Tee.  Initializes one parallel branch of the tee.
          def initialize(tee, index)
            @tee = tee
            @index = index
            @trace = caller_locations
          end

          # Retrieves the next buffer for this branch.
          #
          # Raises BranchBufferOverflow if the read would not fit in the tee's
          # internal buffer, or if any of the other tee branches have not been
          # read for a long time.
          def sample(count)
            @tee.internal_sample(self, count)
          end

          # Returns an Array containing the source node feeding into the Tee.
          def sources
            @tee.sources
          end

          # Returns the next upstream node that is not a branch of a Tee.
          def original_source
            @tee.original_source
          end

          # Wraps upstream #at_rate to return self instead of upstream.
          def at_rate(new_rate)
            @tee.at_rate(new_rate)
            self
          end

          # Describes this branch as a String.
          def to_s
            "Branch #{@index + 1} of #{@tee.branches.count}#{graph_node_name && " (#{graph_node_name})"}"
          end

          # Resets the internal done flag to allow this tee to flow data again,
          # then passes the given duration to upstream nodes.
          def for(duration, recursive: true)
            @tee.reset
            super
          end
        end

        # The source node feeding into this Tee, in an array (see
        # GraphNode#sources).
        attr_reader :sources

        # The branches from the Tee (see GraphNode#tee).
        attr_reader :branches

        def_delegators :@source, :sample_rate, :sample_rate=

        # Creates a Tee from the given +source+, with +n+ branches.  Generally
        # for internal use by GraphNode#tee and GraphNode#get_sampler.
        def initialize(source, n = 2, circular_buffer_size: 48000)
          raise "Source #{source} for a Tee must respond to #sample (and not be a Ruby Array)" unless source.respond_to?(:sample) && !source.is_a?(Array)
          raise "Source #{source} for a Tee must respond to #sample_rate" unless source.respond_to?(:sample_rate)

          @source = source
          @sources = [source].freeze
          @branches = Array.new(n) { |idx| Branch.new(self, idx) }

          @cbuf = CircularBuffer.new(buffer_size: circular_buffer_size)
          @readers = Array.new(n) { @cbuf.reader }

          @done = false
        end

        # Returns the next upstream source that is not a tee branch.
        def original_source
          src = @sources[0]
          src = src.sources[0] while src.is_a?(MB::Sound::GraphNode::Tee::Branch)
          src
        end

        # Adds a new branch to the Tee and returns it.
        #
        # This is part of the code to allow multiple references to a single
        # graph node without explicit teeing.
        def add_branch
          branch = Branch.new(self, @branches.length)
          reader = @cbuf.reader

          @branches << branch
          @readers << reader

          branch
        end

        # Wraps upstream #at_rate to return self instead of upstream.
        def at_rate(new_rate)
          @source.at_rate(new_rate)
          self
        end

        # For internal use by Branch#sample.  Fills the internal circular
        # buffer as needed until there are +count+ samples available for the
        # given branch, or the upstream returns nil or empty.  Returns the next
        # +count+ samples from the given branch's circular buffer reader (or
        # fewer if the upstream has stopped).
        def internal_sample(branch, count)
          return @source.sample(count) if @branches.count == 1

          # TODO: maybe dedupe with InputChannelSplit?
          # TODO: should we grow the buffer automatically?

          r = @readers[branch.index]

          while !@done && r.length < count
            buf = @source.sample(count)
            if buf.nil? || buf.empty?
              @done = true
            else
              @cbuf.write(buf)
            end
          end

          if r.empty?
            nil
          else
            r.read(MB::M.min(r.length, count))
          end

        rescue MB::Sound::CircularBuffer::BufferOverflow
          src = original_source

          raise BranchBufferOverflow, <<~EOF
          Read of #{branch} overflowed internal buffer.  This may mean a branch is not being read.  Buffers of all branches: #{@readers.map(&:length)}

            Source node: #{src}

            Tee creation traces:
            #{@branches.map.with_index { |b|
              "\n\e[1m#{b}\e[0m:\n\t#{MB::U.highlight(b.instance_variable_get(:@trace))}\n\n"
            }.join}
          EOF
        end

        # Clears the "done" flag that returns nil if upstreams return nil, in
        # case the upstreams were restarted.
        def reset
          @done = false
        end
      end
    end
  end
end
