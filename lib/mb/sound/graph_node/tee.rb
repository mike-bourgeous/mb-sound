module MB
  module Sound
    module GraphNode
      # Creates fan-out branches from a signal node (any object that responds to
      # #sample and returns a single audio buffer, and ideally includes the
      # GraphNode module), using buffer copies to prevent parallel branches
      # from interfering with each other.
      #
      # The ideal way to create a Tee is with the GraphNode#tee method.
      #
      # Example:
      #     # Runnable in bin/sound.rb
      #     a, b, c = 200.hz.forever.tee(3) ; nil
      #     d = a * 100.hz + b * 200.hz + c * 300.hz ; nil
      #     play d
      class Tee
        # Raised when any branch's internal buffer overflows.  This could
        # happen if the downstream buffer size is significantly larger than the
        # Tee's internal buffer size, or if one branch is being read more than
        # another.
        class BranchBufferOverflow < MB::Sound::CircularBuffer::BufferOverflow; end

        # An individual branch of a Tee, returned by Tee#branches.
        class Branch
          include GraphNode

          attr_reader :index

          # For internal use by Tee.  Initializes one parallel branch of the tee.
          def initialize(tee, index)
            @tee = tee
            @index = index
          end

          # Retrieves the next buffer for this branch.  The Tee will print a
          # warning if any branch is sampled more than once without all branches
          # being sampled once.
          def sample(count)
            @tee.internal_sample(self, count)
          end

          # Returns an Array containing the source node feeding into the Tee.
          def sources
            @tee.sources
          end

          # Describes this branch as a String.
          def to_s
            "Branch #{@index + 1} of #{@tee.branches.count}#{graph_node_name && " (#{graph_node_name})"}"
          end
        end

        # The source node feeding into this Tee, in an array (see
        # GraphNode#sources).
        attr_reader :sources

        # The branches from the Tee (see GraphNode#tee).
        attr_reader :branches

        # Creates a Tee from the given +source+, with +n+ branches.  Generally
        # for internal use by GraphNode#tee.
        def initialize(source, n = 2, circular_buffer_size: 48000)
          raise 'Source for a Tee must respond to #sample (and not a Ruby Array)' unless source.respond_to?(:sample) && !source.is_a?(Array)

          @source = source
          @sources = [source].freeze
          @branches = Array.new(n) { |idx| Branch.new(self, idx) }.freeze

          @cbuf = CircularBuffer.new(buffer_size: circular_buffer_size)
          @readers = Array.new(n) { @cbuf.reader }

          @done = false
        end

        # For internal use by Branch#sample.  Fills the internal circular
        # buffer as needed until there are +count+ samples available for the
        # given branch, or the upstream returns nil or empty.  Returns the next
        # +count+ samples from the given branch's circular buffer reader (or
        # fewer if the upstream has stopped).
        def internal_sample(branch, count)
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
          elsif r.length < count
            # TODO: allow disabling padding?
            MB::M.zpad(r.read(r.length), count)
          else
            r.read(MB::M.min(r.length, count))
          end

        rescue MB::Sound::CircularBuffer::BufferOverflow
          raise BranchBufferOverflow, "Read of #{branch} overflowed internal buffer.  Buffers of all branches: #{@readers.map(&:length)}"
        end
      end
    end
  end
end
