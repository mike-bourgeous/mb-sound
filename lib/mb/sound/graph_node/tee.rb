require 'forwardable'

module MB
  module Sound
    module GraphNode
      # Creates fan-out branches from a signal node (any object that responds
      # to #sample and returns a single audio buffer).
      #
      # When every branch reads each buffer once with the same count
      # (lockstep, the usual case in a Session), the source is sampled once
      # and every branch gets the same frozen, read-only view of the source's
      # output buffer, valid until the next buffer like any #sample result.
      # Otherwise (a branch reads again before another has read, asks for a
      # different count, or the source returns a short buffer) that buffer
      # goes into a CircularBuffer and each branch reads its own copy, until
      # all branches have caught up.  A branch that is never read keeps the
      # Tee in that mode until its reader falls a whole CircularBuffer behind
      # (it then raises BranchBufferOverflow if it ever reads, as before).
      #
      # Nodes must not modify a frozen buffer they are given (copy it first;
      # see the nodes that process in place).  Numo raises for most writes to
      # a frozen view, but not for in-place arithmetic (`buf.inplace * 2`), so
      # with Tee.shared_check set (or MB_SOUND_CHECK_SHARED=1 in the
      # environment) each shared buffer is checked when the next one starts:
      # :raise raises naming the branches; :warn warns once and makes that Tee
      # copy for each branch instead (bin/sound.rb uses :warn, so a live set
      # keeps playing).  Tee.shared = false (MB_SOUND_SHARED_TEE=0) turns
      # sharing off.
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
      #     a, b, c = 200.hz.tee(3) ; nil
      #     d = a * 100.hz + b * 200.hz + c * 300.hz ; nil
      #     play d
      class Tee
        extend Forwardable

        include Nameable
        include Traversable
        include MultiOutput

        # Raised when reading from a branch after its internal buffer
        # overflows.  This could happen if the downstream buffer size is
        # significantly larger than the Tee's internal buffer size, or if one
        # branch is being read more often than another.
        class BranchBufferOverflow < MB::Sound::CircularBuffer::BufferOverflow; end

        # Raised when trying to read from a branch that has been destroyed.
        class BranchDestroyedError < MB::Sound::CircularBuffer::ReaderClosedError; end

        # Raised (with Tee.shared_check :raise) when a downstream node
        # modified a buffer shared by all branches.
        class SharedBufferModified < RuntimeError; end

        class << self
          # Whether lockstep branches share one buffer (default true; false
          # with MB_SOUND_SHARED_TEE=0).
          attr_accessor :shared

          # Whether to verify that shared buffers weren't modified: nil (off),
          # :raise, or :warn (see the class description).
          attr_accessor :shared_check
        end

        self.shared = ENV['MB_SOUND_SHARED_TEE'] != '0'
        self.shared_check = case ENV['MB_SOUND_CHECK_SHARED']
                            when nil, '', '0' then nil
                            when 'warn' then :warn
                            else :raise
                            end

        # An individual branch of a Tee, returned by Tee#branches.
        class Branch
          extend Forwardable

          include GraphNode
          include NodeOutput

          # Values for internal use by Tee.
          attr_reader :index, :reader, :tee

          # For internal use by Tee: the last shared frame this branch read.
          attr_accessor :frame

          def_delegators :@tee, :sample_rate, :sample_rate=, :reset, :original_source
          def_delegators :@reader, :count, :length

          attr_reader :sources

          # For internal use by Tee.  Initializes one parallel branch of the tee.
          def initialize(tee, index, reader)
            @owner = tee
            @tee = tee
            @index = index
            @reader = reader
            @trace = caller_locations
            @sources = { tee: @tee }
            @node_type_name = 'Branch'
          end

          # Inform the tee that this branch will no longer be used.  This may
          # be useful for dynamically changing routing (see e.g. how
          # bin/fm_synth.rb interacts with Mixer).
          def destroy
            @tee.remove_branch(self)
            @reader.close
            @reader = nil
          end

          # Retrieves the next buffer for this branch.
          #
          # Raises BranchBufferOverflow if the read would not fit in the tee's
          # internal buffer, or if this branch has not been read for a long
          # time and has fallen too far behind.
          def sample(count)
            raise BranchDestroyedError, "Branch #{index} has been destroyed." unless @reader

            @tee.internal_sample(self, count)
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

          # Pass unknown methods through to the upstream node.
          def method_missing(m, *a, **ka)
            original_source.send(m, *a, **ka)
          end
        end

        # The source node feeding into this Tee, in an array (see
        # GraphNode#sources).
        attr_reader :sources

        # The next upstream source that is not a Tee branch.
        attr_reader :original_source

        # The branches from the Tee (see GraphNode#tee).
        attr_reader :branches
        alias outputs branches

        def_delegators :@source, :sample_rate, :sample_rate=

        # Creates a Tee from the given +source+, with +n+ branches.  Generally
        # for internal use by GraphNode#tee and GraphNode#get_sampler.
        def initialize(source, n = 2, circular_buffer_size: 48000)
          raise "Source #{source} for a Tee must respond to #sample (and not be a Ruby Array)" unless source.respond_to?(:sample) && !source.is_a?(Array)
          raise "Source #{source} for a Tee must respond to #sample_rate" unless source.respond_to?(:sample_rate)

          @source = source
          @sources = { input: source }.freeze
          @original_source = @source
          @original_source = @original_source.original_source while @original_source.is_a?(Branch)

          @cbuf = CircularBuffer.new(buffer_size: circular_buffer_size)

          @branch_index = 0
          @branches = []
          for i in 0...n
            add_branch
          end

          @done = false

          # Shared fan-out state (see the class description)
          @frame = 0
          @frame_data = nil
          @frame_count = nil
          @frame_snapshot = nil
          @buffered = false
          @copying = false
        end

        # Adds a new branch to the Tee and returns it.
        #
        # This is part of the code to allow multiple references to a single
        # graph node without explicit teeing.
        def add_branch
          reader = @cbuf.reader
          branch = Branch.new(self, @branch_index, reader)
          branch.frame = @frame || 0

          @branch_index += 1

          @branches << branch

          branch
        end

        # For internal use by Branch#destroy.
        def remove_branch(b)
          @branches.delete(b)
        end

        # Wraps upstream #at_rate to return self instead of upstream.
        def at_rate(new_rate)
          @source.at_rate(new_rate)
          self
        end

        # For internal use by Branch#sample.  Returns the next +count+ samples
        # for +branch+ (fewer, or nil, once the source ends): the shared
        # buffer in lockstep, otherwise from the CircularBuffer (see the class
        # description).
        def internal_sample(branch, count)
          return @source.sample(count) if @branches.count == 1
          return buffered_sample(branch, count) if @buffered || !Tee.shared || branch.reader.overflowed?

          # This branch hasn't read the current shared buffer yet
          if branch.frame < @frame && @frame_data
            return switch_to_buffer(branch, count) if count != @frame_count

            branch.frame = @frame
            return frame_data_for_branch
          end

          # This branch wants the next buffer: share it if the others are done
          # with this one (or have fallen a whole CircularBuffer behind)
          if @frame_data && @branches.any? { |b| b.frame < @frame && !b.reader.overflowed? }
            return switch_to_buffer(branch, count)
          end

          next_frame(count)
          return nil if @frame_data.nil?

          # A short read before the end goes through the CircularBuffer, which
          # fills the request from later buffers
          return switch_to_buffer(branch, count) if @frame_data.length < count

          branch.frame = @frame
          frame_data_for_branch

        rescue BranchBufferOverflow
          raise

        rescue MB::Sound::CircularBuffer::BufferOverflow
          raise_overflow(branch)
        end

        private

        # Samples the source for the next shared buffer, checking the last one
        # first (see Tee.shared_check).
        def next_frame(count)
          check_frame if @frame_snapshot

          @frame += 1
          @frame_count = count
          @frame_data = nil
          @frame_snapshot = nil
          return if @done

          buf = @source.sample(count)
          if buf.nil? || buf.empty?
            @done = true
            return
          end

          # A frozen source buffer is shared as it is, so consumers can tell
          # an unchanged buffer by identity (e.g. Notes nodes' constant
          # buffers)
          @frame_data = buf.frozen? ? buf : buf[0..].freeze
          @frame_snapshot = buf.to_binary if Tee.shared_check && !@copying
        end

        # The shared buffer, or a copy for each branch once a Tee has been
        # caught modifying its shared buffer with :warn.
        def frame_data_for_branch
          @copying ? @frame_data.dup : @frame_data
        end

        # Raises or warns if the last shared buffer was modified.
        def check_frame
          return if @frame_data.to_binary == @frame_snapshot

          message = "A node downstream of #{original_source} modified the buffer shared by its #{@branches.count} branches " \
            "(copy a frozen input before modifying it).  Branch creation traces:\n" +
            @branches.map { |b| "#{b}:\n\t#{b.instance_variable_get(:@trace)&.first(6)&.join("\n\t")}" }.join("\n")

          if Tee.shared_check == :warn
            warn "#{message}\nCopying the buffer for each branch of this Tee from now on."
            @copying = true
          else
            raise SharedBufferModified, message
          end
        end

        # Leaves lockstep: puts the current shared buffer into the
        # CircularBuffer for the branches that haven't read it, then serves
        # +branch+ from the CircularBuffer.
        def switch_to_buffer(branch, count)
          check_frame if @frame_snapshot
          @frame_snapshot = nil

          if @frame_data
            @cbuf.write(@frame_data)
            @branches.each do |b|
              b.reader.discard(@frame_data.length) if b.frame >= @frame && !b.reader.overflowed?
            end
          end

          @frame_data = nil
          @buffered = true
          buffered_sample(branch, count)
        end

        # Reads +count+ samples for +branch+ from the CircularBuffer, sampling
        # the source as needed, and returns to lockstep once every branch has
        # caught up.
        def buffered_sample(branch, count)
          r = branch.reader

          while !@done && r.length < count
            buf = @source.sample(count)
            if buf.nil? || buf.empty?
              @done = true
            else
              @cbuf.write(buf)
            end
          end

          data = r.empty? ? nil : r.read(MB::M.min(r.length, count))

          if @buffered && Tee.shared && @branches.all? { |b| b.reader.overflowed? || b.reader.empty? }
            @buffered = false
            @branches.each { |b| b.frame = @frame }
          end

          data
        end

        def raise_overflow(branch)
          src = original_source

          raise BranchBufferOverflow, <<~EOF
          Read of #{branch} overflowed internal buffer.  This may mean a branch is not being read.  Buffers of all branches: #{@branches.map(&:reader).map(&:length)}

            Source node: #{src}

            Tee creation traces:
            #{@branches.map.with_index { |b|
              "\n\e[1m#{b}\e[0m:\n\t#{MB::U.highlight(b.instance_variable_get(:@trace))}\n\n"
            }.join}
          EOF
        end

        public

        # Clears the "done" flag that returns nil if upstreams return nil, in
        # case the upstreams were restarted.
        def reset
          @done = false
        end
      end
    end
  end
end
