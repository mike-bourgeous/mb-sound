module MB
  module Sound
    module GraphNode
      # Reusable frozen, read-only views of a node's reused output buffer,
      # with generation counters that say when a view's contents changed
      # (omnibus14, maintainer 2026-10-26: "The implicit mismatch in
      # behavior is risky").
      #
      # A Tee shares one frozen view of its source's buffer with every
      # branch.  It used to make a new view (`buf[0..].freeze`) every
      # buffer, so a frozen buffer's identity implied its contents: the same
      # frozen object again meant the same values, and steady-input caches
      # (CurveShaper, Length scaling, note-value lengths, ...) compared
      # identity alone.  Now the view is reused while the source returns the
      # same buffer object, and each reuse bumps the view's generation, so
      # "unchanged" is explicit: a cache keys on the buffer and its
      # generation (FrozenView::Key), never on identity alone
      # (spec/lib/mb/sound/graph_node/frozen_view_spec.rb's guard scans lib/
      # for that).
      #
      # Frozen buffers that were never handed out by #of (a Constant's or a
      # Notes node's steady buffer, which is replaced rather than rewritten
      # when its value changes) have generation 0 forever.
      class FrozenView
        # Views handed out by any FrozenView, to the Gen holding their
        # current generation (identity-keyed and weak, so views are freed
        # with their owners).
        VIEWS = ObjectSpace::WeakMap.new

        # A view's mutable generation.
        class Gen
          attr_accessor :value

          def initialize(value)
            @value = value
          end
        end

        @next = 0

        class << self
          # The generation of frozen buffer +buf+: 0 unless it is a reused
          # view from #of, else a number unique to its current contents
          # (generations are drawn from one counter, so no two contents of
          # any views share one).
          def generation(buf)
            g = VIEWS[buf]
            g ? g.value : 0
          end

          # For internal use: the next generation number.
          def next_generation
            @next += 1
          end
        end

        # How many parent buffers each FrozenView remembers views of (nodes
        # with several outputs alternate two sets of output buffers; see
        # GraphNode::ChannelMixer).
        SLOTS = 2

        def initialize
          @parents = Array.new(SLOTS)
          @views = Array.new(SLOTS)
          @gens = Array.new(SLOTS)
          @last = 0
        end

        # Returns a frozen view of all of +buf+ (an unfrozen NArray), reusing
        # the view made last time for the same buffer object of the same
        # length, with a new generation (its contents may have changed).
        def of(buf)
          i = 0
          while i < SLOTS
            p = @parents[i]
            if p && p.equal?(buf) && @views[i].length == buf.length
              @gens[i].value = FrozenView.next_generation
              @last = i
              return @views[i]
            end
            i += 1
          end

          i = (@last + 1) % SLOTS
          view = buf[0..].freeze
          gen = Gen.new(FrozenView.next_generation)
          VIEWS[view] = gen
          @parents[i] = buf
          @views[i] = view
          @gens[i] = gen
          @last = i
          view
        end

        # A steady-input cache key: remembers a frozen buffer and its
        # generation, and tells whether a later buffer is the same buffer
        # with the same contents.  Unfrozen buffers never match (their
        # owners reuse them).
        class Key
          def initialize
            @buf = nil
            @gen = 0
          end

          # True if +buf+ is the frozen buffer last given to #set, with the
          # same contents (the same generation).
          def match?(buf)
            !@buf.nil? && buf.equal?(@buf) && FrozenView.generation(buf) == @gen
          end

          # Remembers +buf+ if it is frozen (else forgets); returns +buf+.
          def set(buf)
            if buf.frozen?
              @buf = buf
              @gen = FrozenView.generation(buf)
            else
              @buf = nil
            end
            buf
          end

          # Forgets the remembered buffer.
          def clear
            @buf = nil
          end

          # The remembered buffer, or nil.
          def buffer
            @buf
          end
        end
      end
    end
  end
end
