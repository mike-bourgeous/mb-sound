module MB
  module Sound
    # Creates fan-out branches from a signal node (any object that responds to
    # #sample and returns a single audio buffer, and ideally includes the
    # ArithmeticMixin module), using buffer copies to prevent parallel branches
    # from interfering with each other.
    #
    # The ideal way to create a Tee is with the ArithmeticMixin#tee method.
    #
    # Example:
    #     # Runnable in bin/sound.rb
    #     a, b, c = 200.hz.forever.tee(3) ; nil
    #     d = a * 100.hz + b * 200.hz + c * 300.hz ; nil
    #     play d
    class Tee
      # An individual branch of a Tee, returned by Tee#branches.
      class Branch
        include ArithmeticMixin

        attr_reader :need_sample

        # For internal use by Tee.  Initializes one parallel branch of the tee.
        def initialize(tee)
          @tee = tee
          @buf = nil
          @type = Numo::SFloat
        end

        # Retrieves the next buffer for this branch.  The Tee will print a
        # warning if any branch is sampled more than once without all branches
        # being sampled once.
        def sample(count)
          source_buf = @tee.internal_sample(self, count)
          return nil if source_buf.nil?

          @type = source_buf.class
          update_buffer(count)

          # This returns source_buf, not @buf, so we can't use this as the return line.
          @buf[] = source_buf

          @buf
        end

        # Returns an Array containing the source node feeding into the Tee.
        def sources
          @tee.sources
        end

        private

        # TODO: deduplicate buffer management/allocation/reallocation
        def update_buffer(count)
          if @buf.nil? || @type != @buf.class || count != @buf.length
            @buf = @type.zeros(count)
          end
        end
      end

      # The source node feeding into this Tee, in an array (see
      # ArithmeticMixin#sources).
      attr_reader :sources
      
      # The branches from the Tee (see ArithmeticMixin#tee).
      attr_reader :branches

      # Creates a Tee from the given +source+, with +n+ branches.  Generally
      # for internal use by ArithmeticMixin#tee.
      def initialize(source, n = 2)
        raise 'Source for a Tee must respond to #sample' unless source.respond_to?(:sample)

        @source = source
        @sources = [source].freeze
        @branches = n.times.map { Branch.new(self) }.freeze

        # List of branches that have already read the current buffer, to detect
        # when a new buffer is needed.
        @read_branches = Set.new
      end

      # For internal use by Branch#sample.  Returns the current buffer of
      # +count+ samples from the source node.  The +count+ must be the same for
      # every branch (TODO: a buffer-size adapter might be useful to allow
      # different size reads and writes; such a thing might already sort of
      # exist in ProcessMethods).  If the +branch+ has already seen this
      # buffer, or if the source buffer has not yet been read, then a new
      # buffer is read from the source node.
      def internal_sample(branch, count)
        if @read_branches.include?(branch)
          if @read_branches.length != @branches.length
            warn "Branch #{branch} on Tee #{self} sampled again with #{@read_branches.length} of #{@branches.length} sampled"
          end

          @read_branches.clear
          @buf = nil
        end

        if @buf && @buf.length != count
          raise "Branch #{branch} on Tee #{self} requested #{count} samples when the buffer has #{@buf.length}"
        end

        @read_branches << branch

        @buf ||= @source.sample(count)
      end
    end
  end
end
