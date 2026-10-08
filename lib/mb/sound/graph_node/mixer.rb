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
        # If +:stop_early+ is true (the default), then any summand returning nil
        # or an empty NArray from its #sample method will cause this #sample
        # method to return nil.  Otherwise, the #sample method only returns nil
        # when all summands return nil or empty.
        #
        # Numeric summands are rolled into the constant value.  Duplicated
        # GraphNode summands will have their gains summed and only a single
        # copy of the summand added.
        def initialize(summands, sample_rate: nil, stop_early: true)
          @constant = 0
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

        # Calls the #sample methods of all summands, applies gains, adds them all
        # to the initial #constant value, and returns the result.
        #
        # If any summand (or every summand if stop_early was set to false in the
        # constructor) returns nil or an empty buffer, then this method will
        # return nil.
        def sample(count)
          sampled = arithmetic_inputs(count, @gains)

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
            retbuf.fill(@constant)
            tmpbuf = nil
            sampled.each do |v, gain|
              if gain == 1
                retbuf.inplace + v
              else
                tmpbuf ||= arithmetic_view(@tmpbuf, count, :tmp)
                tmpbuf.fill(gain).inplace * v
                retbuf.inplace + tmpbuf
              end
            end
            return retbuf.not_inplace!
          end

          arithmetic_combine(count, sampled, sources: @gains, pad: 0, fill: @constant, stop_early: @stop_early) do |retbuf, inputs|
            inputs.each do |v, gain|
              tmpbuf = @tmpbuf[0...v.length]
              tmpbuf.fill(gain).inplace * v
              retbuf.inplace + tmpbuf
            end
          end
        end

        # Plan layer (see MB::Sound::Plan): the constant plus each term in
        # order (an input times its gain unless the gain is 1), as the fast
        # path computes it.
        include Plan::Describable

        def plan_describe(p)
          @gains.reduce(p.const(@constant, complex: plan_complex_buffer?)) { |sum, (m, gain)|
            sum + (gain == 1 ? p[m] : p[m] * gain)
          }
        end

        def plan_inputs
          @gains.keys
        end

        def plan_unsupported_reason
          return 'stop_early: false' unless @stop_early
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
          Plan.changed(self)
        end

        # Removes all summands, but does not reset the constant, if set.
        def clear
          @gains.each do |samp, _|
            samp.destroy
          end

          @gains.clear
          @orig_to_samp.clear
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
