module MB
  module Sound
    module GraphNode
      # Sums zero or more inputs that have a #sample method that takes a buffer
      # size parameter, such as a Tone.  One example use of this is as the
      # frequency input of a Tone.  See MB::Sound::Tone#fm.
      #
      # This is taking a step further into the territory of composable signal
      # graphs.  If I redesigned mb-sound from scratch, I would definitely design
      # everything as nodes within a signal graph, kind of like some of my old
      # (unreleased) projects, or like Pure Data.
      #
      # Also see the Multiplier class.
      class Mixer
        include GraphNode
        include BufferHelper
        include SampleRateHelper
        include ArithmeticNodeHelper

        # The constant value added to the output sum before any summands.
        attr_reader :constant

        # Changes the constant term.
        def constant=(value)
          @constant = value
          Plan.changed(self, structure: false)
        end

        # Creates a Mixer with the given inputs, which must be either Numeric
        # values or objects that have a #sample method.  Each input may have an
        # associated gain.  The summands, gains, or numeric constants may all
        # have complex values.  At present, no attempt is made to detect cycles
        # in the signal graph.
        #
        # The +summands+ must be either an Array of objects responding to
        # :sample, in which case every summand will have a gain of 1.0, an Array
        # of two-element Arrays of the form [summand, gain], or a Hash from
        # summand to gain (yes, this is a bit redundant for Numeric summands).
        #
        # If +:stop_early+ is true, then any summand returning nil or an empty
        # NArray from its #sample method will cause this #sample method to
        # return nil.  Otherwise (a sum that rings), a summand that returns
        # a short buffer or nil has ended (zeros pad it, and it isn't
        # sampled again), and #sample returns nil once every summand has
        # ended.  The default (nil) rings, unless sums end with their first
        # input where the mixer is made (see .ring_mode: Mixer.with_ring,
        # Session#ring, render(ring: :first)); GraphNode#ring changes it
        # later.
        #
        # Numeric summands are rolled into the constant value.  Duplicated
        # GraphNode summands will have their gains summed and only a single
        # copy of the summand added.
        # How sums end (see GraphNode#ring): :all (the default: when every
        # input has ended) or :first (when any input ends, the old
        # default).
        RING_MODES = [:all, :first].freeze

        # The ring mode new Mixers made without +:stop_early+ get on this
        # thread: the innermost .with_ring block's, else the ring of the
        # Session the code runs for (Session#ring, set by render(ring:)),
        # else :all.
        def self.ring_mode
          return Thread.current[:mb_sound_mixer_ring] if Thread.current[:mb_sound_mixer_ring]

          session = MB::Sound::Session.context&.[](:session)
          (session.respond_to?(:ring) && session.ring) || :all
        end

        # Makes sums built in the block (`a + b`, `a - b`, Mixers without
        # +:stop_early+) end with their first input to end (+mode+ :first,
        # or false) or ring until every input ends (:all, or true; the
        # default).  Returns the block's result.
        #
        #     g = Mixer.with_ring(:first) { drone + hit }   # ends with the hit
        def self.with_ring(mode)
          mode = ring_value(mode)
          old = Thread.current[:mb_sound_mixer_ring]
          Thread.current[:mb_sound_mixer_ring] = mode
          yield
        ensure
          Thread.current[:mb_sound_mixer_ring] = old
        end

        # Returns +mode+ as a ring mode (see RING_MODES; true is :all, false
        # is :first), raising for anything else.
        def self.ring_value(mode)
          mode = :all if mode == true
          mode = :first if mode == false
          return mode if RING_MODES.include?(mode)
          raise ArgumentError, "ring is :all (or true: until every input ends, the default) or :first (or false: with the first), got #{mode.inspect}"
        end

        def initialize(summands, sample_rate: nil, stop_early: nil)
          # Ending with the first input because of the ring mode (not an
          # explicit stop_early:): recipes print it as .ring(:first), see
          # #ring_implied?
          @ring_implied = stop_early.nil? && Mixer.ring_mode != :all
          @implied_ring_call = nil
          stop_early = Mixer.ring_mode != :all if stop_early.nil?
          @constant = 0
          @ended = nil # summands that have ended, without stop_early
          @live = nil # @gains without the ended summands (see #live_gains)
          @steady = nil # summands that never end, by stored node (see #steady?)
          @gains = {}
          @orig_to_samp = {}

          setup_buffer(length: 1024, temp: true)

          @stop_early = stop_early

          summands = [summands] unless summands.is_a?(Array) || summands.is_a?(Hash)

          @sample_rate = sample_rate

          summands.each_with_index do |(s, gain), idx|
            gain ||= 1.0

            check_rate(s)

            case
            when s.is_a?(Numeric)
              @constant += s * gain

            when s.is_a?(Array)
              raise "Multiplicand cannot be an Array, even though it responds to :sample"

            when s.respond_to?(:sample)
              if @orig_to_samp.include?(s)
                self[s] += gain
              else
                self[s] = gain
              end

            else
              raise ArgumentError, "Summand #{s.inspect} at index #{idx} is not a Numeric and does not respond to :sample"
            end
          end

          raise "Sample rate must be a positive numeric (got #{sample_rate})" unless @sample_rate.is_a?(Numeric) && @sample_rate > 0
          @sample_rate = @sample_rate.to_f
        end

        # True if the sum ends with its first input to end (see #initialize
        # and GraphNode#ring).
        def stop_early?
          @stop_early
        end

        # True if this sum ends with its first input only because it was made
        # where sums end that way (Mixer.with_ring(:first), Session#ring,
        # graph documents before format 4), and that matters: it has two or
        # more inputs that can end (constants and knobs can't).  Recipes
        # print it as `.ring(:first)` (Recipe.note_implied_ring), so a saved
        # copy keeps the ending.
        def ring_implied?
          @ring_implied && @stop_early && summands.count { |s| !(s.is_a?(Constant) || s.is_a?(Knob) || s.is_a?(Knob::Reader)) } >= 2
        end

        # Internal (Recipe.note_implied_ring): the `.ring(:first)` call
        # recorded for #ring_implied?, or nil.
        attr_accessor :implied_ring_call

        # Internal (see GraphNode#ring): ends with the first input to end
        # (true) or with the last (false).
        def stop_early=(stop)
          @stop_early = !!stop
          @ring_implied = false
          @ended = nil
          @live = nil
          Plan.changed(self)
        end

        # The gains of the summands that are still playing (all of them for
        # a sum that ends with its first input; see #initialize).
        def live_gains
          return @gains if @stop_early || @ended.nil?
          @live ||= @gains.reject { |s, _| @ended.key?(s) }
        end

        # Calls the #sample methods of all summands, applies gains, adds them all
        # to the initial #constant value, and returns the result.
        #
        # If any summand (or every summand if stop_early was set to false in the
        # constructor) returns nil or an empty buffer, then this method will
        # return nil.
        def sample(count)
          gains = live_gains
          # Every summand of a ringing sum ended (steady ones don't count)
          return nil if @ended && gains.each_key.all? { |s| steady?(s) }
          sampled = arithmetic_inputs(count, gains)
          return sample_ended(count, sampled, gains) if !@stop_early && ending?(count, sampled)

          # Fast path: the same arithmetic as below without the general
          # bookkeeping, when every input is a full buffer of our type; a
          # gain of 1 skips its multiply (1 * v == v exactly).  The C kernel
          # allocates nothing; the Numo version (its mirror) takes inputs it
          # can't read directly.
          fast = arithmetic_fast?(count, sampled, @constant)
          if fast
            retbuf = arithmetic_view(@buf, count, :buf)
            return retbuf.not_inplace! if MB::Sound::FastArithmetic.mix(retbuf, @constant, sampled)
          end

          if fast && @tmpbuf.class == @buf.class && @tmpbuf.length >= count
            BufferHelper.fill(retbuf, @constant)
            tmpbuf = nil
            sampled.each do |v, gain|
              if gain == 1
                retbuf.inplace + v
              else
                tmpbuf ||= arithmetic_view(@tmpbuf, count, :tmp)
                BufferHelper.fill(tmpbuf, gain).inplace * v
                retbuf.inplace + tmpbuf
              end
            end
            return retbuf.not_inplace!
          end

          arithmetic_combine(count, sampled, sources: gains, pad: 0, fill: @constant, stop_early: @stop_early) do |retbuf, inputs|
            inputs.each do |v, gain|
              tmpbuf = @tmpbuf[0...v.length]
              BufferHelper.fill(tmpbuf, gain).inplace * v
              retbuf.inplace + tmpbuf
            end
          end
        end

        # True if a summand of a ringing sum gave a short buffer or nil.
        def ending?(count, sampled)
          sampled.any? { |v, _| v.nil? || v.length < count }
        end

        # A block of a ringing sum where summands end: a summand that gives
        # a short buffer or nil has ended (a node's last short read is its
        # end), is padded with zeros, and isn't sampled again; the sum goes
        # on until every summand has ended.  The plan layer rebuilds
        # without the ended summands (see Plan::Region#gather).
        #
        # Steady summands (constants and knobs, which never end, e.g. the 200
        # of `200 + 2000 * env`) don't keep the sum going: the sum is as long
        # as its longest other summand in this block, and ends when every
        # other summand has ended, as an offset ended with its signal before
        # sums rang.
        def sample_ended(count, sampled, gains)
          keys = gains.keys
          longest = 0
          others = false
          sampled.each_with_index do |(v, _), idx|
            unless steady?(keys[idx])
              others = true
              longest = v.length if v && v.length > longest
            end
            next unless v.nil? || v.length < count
            (@ended ||= {}.compare_by_identity)[keys[idx]] = true
          end
          @live = nil
          Plan.changed(self, structure: :ended)
          return nil if others && longest == 0

          out = arithmetic_combine(count, sampled, sources: gains, pad: 0, fill: @constant, stop_early: false) do |retbuf, inputs|
            inputs.each do |v, gain|
              tmpbuf = @tmpbuf[0...v.length]
              BufferHelper.fill(tmpbuf, gain).inplace * v
              retbuf.inplace + tmpbuf
            end
          end
          others && out && out.length > longest ? out[0...longest] : out
        end

        # True for summands that never end (constants and knobs; see
        # #sample_ended), by the summand as stored (maybe a Tee branch).
        def steady?(samp)
          @steady ||= {}.compare_by_identity
          return @steady[samp] if @steady.key?(samp)

          orig = @orig_to_samp.key(samp) || samp
          @steady[samp] = orig.is_a?(Constant) || orig.is_a?(Knob) || orig.is_a?(Knob::Reader)
        end

        # Plan layer (see MB::Sound::Plan): the constant plus each term in
        # order (an input times its gain unless the gain is 1), as the fast
        # path computes it.
        include Plan::Describable

        def plan_describe(p)
          live_gains.reduce(p.const(@constant, complex: plan_complex_buffer?)) { |sum, (m, gain)|
            sum + (gain == 1 ? p[m] : p[m] * gain)
          }
        end

        def plan_inputs
          live_gains.keys
        end

        def plan_unsupported_reason
          # A ringing sum whose summands have all ended returns nil (unfused)
          return 'every summand has ended' if @ended && live_gains.each_key.all? { |x| steady?(x) }
          return "a #{@buf.class} buffer" unless @buf.is_a?(Numo::SFloat) || @buf.is_a?(Numo::SComplex)
          return 'a non-numeric gain' unless @gains.each_value.all? { |g| g.is_a?(Numeric) }

          nil
        end

        def plan_output_type
          plan_complex_buffer? || @constant.is_a?(Complex) || @gains.each_value.any? { |g| g.is_a?(Complex) } ? :complex : :real
        end

        # Returns the gain value for the given +summand+, or nil if the summand
        # is not present.  The +summand+ may be an Integer to refer to a summand
        # by insertion order (starting at 0).
        def [](summand)
          @gains[find_summand(summand)]
        end

        # Sets the gain value for the given +summand+ (which must respond to the
        # :sample method), adding it to the mixer if it is not already present.
        # The +summand+ may be an Integer to refer to a summand by insertion
        # order (starting at 0).
        #
        # Note that it's only possible to change the gain of the last instance
        # of a summand by reference if it was added more than once.  Use
        # indices instead, or use standalone addition and multiplication.
        def []=(summand, gain)
          # TODO: smooth gain changes
          known = summand.is_a?(Integer) || @orig_to_samp.include?(summand)
          samp = find_summand(summand, create: true)
          @gains[samp] = gain
          @live = nil
          Plan.changed(self, structure: !known)
        end

        # Removes the given +summand+ from the mixer.  The +summand+ may be an
        # Integer to refer to a summand by insertion order (starting at 0), in
        # which case summands added after this one will have their index
        # decremented by one.
        #
        # Note that it's only possible to remove the last instance of a summand
        # bu reference if it was added more than once.  Use indices instead in
        # that case.
        def delete(summand)
          samp = find_summand(summand)
          @gains.delete(samp)
          @orig_to_samp.delete_if { |_, v| v == samp }
          samp.destroy
          @ended&.delete(samp)
          @live = nil
          Plan.changed(self)
        end

        # Removes all summands, but does not reset the constant, if set.
        def clear
          @gains.each do |samp, _|
            samp.destroy
          end

          @gains.clear
          @orig_to_samp.clear
          @ended = nil
          @live = nil
          Plan.changed(self)
        end

        # Returns the number of summands (excluding a possible constant value).
        def count
          @gains.length
        end
        alias length count

        # Returns true if there are no summands (apart from a possible constant
        # value).
        def empty?
          @gains.empty?
        end

        # Returns an Array of the original summands in this mixer (without
        # their gains).
        def summands
          @orig_to_samp.keys
        end

        # See GraphNode#sources
        def sources
          {
            constant: @constant,
            **@gains.keys.map.with_index { |src, idx|
              [:"input_#{idx + 1}", src]
            }.to_h
          }
        end

        # Returns an Array of the gains in this mixer (without their summands).
        def gains
          @gains.values
        end

        # Returns true if the +other+ summand is already an input to this
        # Mixer.
        def include?(other)
          @orig_to_samp.include?(other)
        end

        # Adds the arithmetic form of the mixer to GraphNode#to_s.
        def to_s
          "#{super} -- #{arithmetic_string}"
        end

        # Appends the arithmetic form of the mixer after
        # GraphNode#to_s_graphviz.
        def to_s_graphviz
          <<~EOF
          #{super}---------------
          #{arithmetic_string("\n")}
          EOF
        end

        # Returns a String showing the math under the hood of this Mixer.
        #
        # Named nodes will show up as their names, so you can name an
        # arithmetic node to prevent joining the arithmetic terms past that
        # node.
        def arithmetic_string(separator = ' ')
          arithmetic_terms(separator).join(" +#{separator}").gsub("+#{separator}-", "-#{separator}")
        end

        # Returns an Array of terms that can be joined with pluses to produce a
        # mathematical statement, for #to_s and #to_s_graphviz.
        #
        # See #arithmetic_string.
        def arithmetic_terms(separator)
          terms = @gains.map { |src, g|
            src = climb_tee_tree(src)
            str = make_source_name(src, separator: separator)

            case g
            when 1
              str

            when -1
              "-#{str}"

            else
              "#{make_source_name(g)} * #{str}"
            end
          }

          terms << make_source_name(@constant) unless @constant == 0

          terms
        end

        private

        # Looks for a summand by identity or index.  This is needed because the
        # @gains map uses GraphNode#get_sampler rather than the original
        # summand.
        #
        # Returns the internal get_sampler summand reference.
        def find_summand(summand, create: false)
          if summand.is_a?(Integer)
            @gains.keys[summand]
          else
            raise 'Summand must respond to :sample' unless summand.respond_to?(:sample)

            if create
              @orig_to_samp[summand] ||= summand.get_sampler
            else
              @orig_to_samp.fetch(summand)
            end
          end
        end
      end
    end
  end
end
