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
      # The CircularBuffer and the branches' readers (a second-long buffer
      # each) are made when the Tee first leaves lockstep, so Tees that
      # never do (every Tee in the bin/ scripts measured 2026-10-09) cost
      # no memory for them (sq80_voice: 719 Tees, 324 MB before).
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
      # Sample rates: a branch asked for another rate changes the rate of
      # the source and everything upstream (so every branch follows),
      # except while an oversample region applies its rate (2026-10-11; see
      # GraphNode#oversample and Tee.pin_rates): a node read both
      # inside the region and outside it keeps its rate, and the region's
      # branch is pinned to the region's rate, reading the source through
      # its own resampler (Branch#resampled?; libsamplerate's best sinc, or
      # a zero-order hold for Constants).  So a node shared between an
      # oversampled region and a plain branch (or two oversample regions)
      # runs once at its own rate and each consumer reads it at its own
      # rate; nodes only read inside the region run at the higher rate.
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

        # A branch's reader until the Tee first leaves lockstep and makes its
        # CircularBuffer (see #buffers!): nothing buffered, never overflowed.
        class IdleReader
          def length = 0
          alias count length

          def empty? = true
          def overflowed? = false
          def closed? = false
          def close; end
        end

        class << self
          # Whether lockstep branches share one buffer (default true; false
          # with MB_SOUND_SHARED_TEE=0).
          attr_accessor :shared

          # Whether to verify that shared buffers weren't modified: nil (off),
          # :raise, or :warn (see the class description).
          attr_accessor :shared_check
        end

        class << self
          # The Branch => true set of branches #pin_rates is pinning on
          # this thread, or nil.
          def rate_pins
            Thread.current[:mb_sound_tee_rate_pins]
          end

          # Runs the block (oversample regions setting the rates of their
          # inputs +upstreams+ to one rate; see Resample.apply_pending) with
          # the regions' branches of shared nodes pinned: walking the graph
          # from +upstreams+ through #sources (stopping at Resample nodes),
          # a Tee whose every branch is reached is inside the regions and
          # the walk continues from its source; branches of the other Tees
          # reached are pinned to the rate asked of them (read through
          # their own resamplers) instead of passing it upstream, so shared
          # nodes keep their rate.
          def pin_rates(upstreams)
            raise 'Nested Tee.pin_rates' if rate_pins

            seen = {}.compare_by_identity
            reached = {}.compare_by_identity
            inside = {}.compare_by_identity
            stack = Array(upstreams).dup
            loop do
              while (node = stack.pop)
                next if seen[node]

                seen[node] = true
                if node.is_a?(Branch)
                  reached[node] = true
                  next
                end
                next if node.is_a?(Resample)
                next unless node.respond_to?(:sources)

                srcs = node.sources
                next unless srcs.respond_to?(:each_value)

                srcs.each_value { |v| (v.is_a?(Array) ? v : [v]).each { |n| stack << n if n.respond_to?(:sample) || n.is_a?(Tee) } }
              end

              progress = false
              reached.each_key.map(&:owner_tee).uniq.each do |tee|
                next if inside[tee] || !tee.branches.all? { |b| reached[b] }

                inside[tee] = true
                progress = true
                stack << tee.sources[:input]
              end
              break unless progress
            end

            pins = reached.reject { |b, _| inside[b.owner_tee] }.compare_by_identity
            begin
              Thread.current[:mb_sound_tee_rate_pins] = pins
              yield
            ensure
              Thread.current[:mb_sound_tee_rate_pins] = nil
            end
          end

          # A count of branches added to and removed from every Tee, for
          # callers that cache something derived from Tee#branches (see
          # Synth#boundary).
          attr_accessor :branch_changes

          # Runs the block, returning an ObjectSpace::WeakMap (Branch =>
          # true, by identity) of the branches made on this thread while it
          # ran (nested calls add theirs to the outer map too).  Weak, so
          # branches nothing reads are still collected (a Notes node's
          # stream reader held here would hold its stream back from
          # ending).  Graphs that skip work while
          # idle (Synth lanes, drum voices) use it to tell a branch made
          # while building them but left unread (e.g. `band * 0.5` made in a
          # voice block and never used) from a reader elsewhere, which they
          # must keep in step with while skipped.
          def collect_branches
            outer = Thread.current[:mb_sound_tee_new_branches]
            made = ObjectSpace::WeakMap.new
            Thread.current[:mb_sound_tee_new_branches] = made
            yield
            made
          ensure
            Thread.current[:mb_sound_tee_new_branches] = outer
            made&.each { |b, v| outer[b] = v } if outer
          end
        end

        self.branch_changes = 0
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
          attr_reader :index, :reader

          # The Tee this branch belongs to (not +tee+, which is the DSL method
          # that splits this branch again).
          def owner_tee = @tee

          # For internal use by Tee: the branch's CircularBuffer reader (an
          # IdleReader until the Tee leaves lockstep for the first time).
          attr_writer :reader

          # For internal use by Tee: the last shared frame this branch read.
          attr_accessor :frame

          # For internal use by the plan layer (MB::Sound::Plan::Region): a
          # buffer the next #sample returns instead of reading the Tee, so
          # a region that already read its boundary inputs can run its nodes
          # unfused on the same data (ENDED replays an ended read: nil).
          attr_accessor :replay

          # A #replay value standing for a read that returned nil.
          ENDED = Object.new.freeze

          def_delegators :@tee, :reset, :original_source
          def_delegators :@reader, :count, :length

          attr_reader :sources

          # For internal use by Tee.  Initializes one parallel branch of the tee.
          # Frames kept of where each branch was made (see #initialize).
          TRACE_DEPTH = 24

          def initialize(tee, index, reader)
            @owner = tee
            @tee = tee
            @index = index
            @reader = reader
            # Where the branch was made, for error messages (the nearest
            # TRACE_DEPTH frames: a full backtrace from deep inside a synth
            # lane build cost ~5 us per branch, ~10% of a voice build)
            @trace = caller_locations(1, TRACE_DEPTH)
            @sources = { tee: @tee }
            @rate = nil
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
            if (r = @replay)
              @replay = nil
              return r.equal?(ENDED) ? nil : r
            end

            raise BranchDestroyedError, "Branch #{index} has been destroyed." unless @reader

            return resampler.sample(count) if @rate && @rate != @tee.sample_rate

            @tee.internal_sample(self, count)
          end

          # The rate this branch gives: the source's, unless an oversample
          # region pinned it (see the Tee class description).
          def sample_rate
            @rate || @tee.sample_rate
          end

          # Sets the rate of this branch's source and everything upstream
          # (and so of every unpinned branch), as before, except while an
          # oversample region applies its rate (Tee.pin_rates; see the
          # Tee class description).
          def sample_rate=(new_rate)
            if (pins = Tee.rate_pins) && pins.key?(self)
              pin_rate(new_rate.to_f == @tee.sample_rate.to_f ? nil : new_rate)
            else
              pin_rate(nil)
              @tee.sample_rate = new_rate
            end
          end

          # Sets the rate (see #sample_rate=), returning self.
          def at_rate(new_rate)
            self.sample_rate = new_rate
            self
          end

          # True if this branch reads the Tee's source through its own
          # resampler (pinned at another rate than the source's; see the
          # Tee class description).  Resampled branches are plan
          # boundaries.
          def resampled?
            !@rate.nil? && @rate != @tee.sample_rate
          end

          # For internal use: gives this branch its own
          # +rate+ (nil to follow the source again).
          def pin_rate(rate)
            rate = rate&.to_f
            return if rate == @rate

            @rate = rate
            Plan.changed(self)
          end

          # Moves this branch forward to the furthest-ahead other branch of
          # its Tee, discarding the frames it skips (exactly: its next read
          # gives the frames the leader reads next), for a branch whose
          # graph hasn't played yet and should start in step with the
          # others (see Session::Strip#catch_up_waiting).  A branch that
          # overflowed gets a new reader there.  Returns the number of
          # frames skipped (nil if it had overflowed; 0 if it was already
          # level with or ahead of every other branch).
          def catch_up
            raise BranchDestroyedError, "Branch #{index} has been destroyed." unless @reader

            @tee.catch_up(self)
          end

          # For internal use by RateReader.
          def internal_raw_sample(count)
            @tee.internal_sample(self, count)
          end

          private

          # The resampler from the source's rate to this branch's (made
          # again if either rate changed).
          def resampler
            from = @tee.sample_rate.to_f
            unless @resampler && @resampler_from == from && @resampler.sample_rate == @rate
              mode = @tee.original_source.is_a?(Constant) ? :libsamplerate_zoh : Resample::DEFAULT_MODE
              @resampler = Resample.new(upstream: RateReader.new(self), sample_rate: @rate, mode: mode)
              @resampler_from = from
            end
            @resampler
          end

          public

          # Describes this branch as a String.
          def to_s
            "Branch #{@index + 1} of #{@tee.branches.count}#{graph_node_name && " (#{graph_node_name})"}"
          end

          # Pass unknown methods through to the upstream node.
          def method_missing(m, *a, **ka)
            original_source.send(m, *a, **ka)
          end
        end

        # The source side of a resampled Branch (see Branch#sample_rate=):
        # reads the branch's share of the Tee at the source's rate.
        class RateReader
          def initialize(branch)
            @branch = branch
          end

          def sample(count)
            @branch.internal_raw_sample(count)
          end

          def sample_rate
            @branch.owner_tee.sample_rate
          end

          def get_sampler
            self
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

          # Made when first needed (#buffers!)
          @cbuf = nil
          @cbuf_size = circular_buffer_size

          @branch_index = 0
          @branches = []
          n.times { add_branch }

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
          reader = @cbuf ? @cbuf.reader : IdleReader.new
          branch = Branch.new(self, @branch_index, reader)
          branch.frame = @frame || 0

          @branch_index += 1
          Tee.branch_changes += 1

          @branches << branch
          if (made = Thread.current[:mb_sound_tee_new_branches])
            made[branch] = true
          end
          Plan.changed(self)
          Plan.changed(@source)

          branch
        end

        # For internal use by Branch#destroy.
        def remove_branch(b)
          @branches.delete(b)
          Tee.branch_changes += 1
          Plan.changed(self)
          Plan.changed(@source)
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

        # For internal use by Branch#catch_up: moves +branch+ to the
        # furthest-ahead other branch.  In lockstep a branch lags at most
        # the current shared buffer (the leader's next read would have left
        # lockstep otherwise); while buffered, the leader is the
        # non-overflowed reader with the least left to read (all readers
        # share one write position).
        def catch_up(branch)
          return 0 if @branches.length <= 1

          if @buffered
            lead = nil
            @branches.each do |b|
              next if b.equal?(branch) || b.reader.overflowed?

              len = b.reader.length
              lead = len if lead.nil? || len < lead
            end
            return 0 if lead.nil?

            r = branch.reader
            if r.overflowed?
              r.close
              branch.reader = @cbuf.reader(lead)
              skipped = nil
            else
              skipped = r.length - lead
              return 0 if skipped <= 0

              r.discard(skipped)
            end
            resume_lockstep
            return skipped
          end

          skipped = 0
          if branch.reader.overflowed?
            # Every other reader is empty in lockstep
            branch.reader.close
            branch.reader = @cbuf.reader
            skipped = nil
          end

          if branch.frame < @frame
            skipped &&= @frame_data&.length || 0
            branch.frame = @frame
          end

          skipped
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

        # Makes the CircularBuffer and a reader for each branch, the first
        # time the Tee leaves lockstep (nothing was ever written before, so
        # every reader starts empty at the start of the buffer, as readers
        # made with the Tee would be).
        def buffers!
          return if @cbuf

          @cbuf = CircularBuffer.new(buffer_size: @cbuf_size)
          @branches.each { |b| b.reader = @cbuf.reader }
        end

        # Leaves lockstep: puts the current shared buffer into the
        # CircularBuffer for the branches that haven't read it, then serves
        # +branch+ from the CircularBuffer.
        def switch_to_buffer(branch, count)
          buffers!
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
          buffers!
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

          resume_lockstep
          data
        end

        # Goes back to sharing buffers once every branch has read everything
        # buffered (or has overflowed).
        def resume_lockstep
          return unless @buffered && Tee.shared && @branches.all? { |b| b.reader.overflowed? || b.reader.empty? }

          @buffered = false
          @branches.each { |b| b.frame = @frame }
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
