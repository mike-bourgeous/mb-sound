module MB
  module Sound
    module GraphNode
      # Sums zero or more inputs that have a #sample method that takes a buffer
      # size parameter, such as an Oscillator.  One example use of this is as the
      # frequency input of an Oscillator.  See MB::Sound::Tone#fm.
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
        attr_accessor :constant

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

          raise 'Sample rate must be a positive numeric' unless @sample_rate.is_a?(Numeric) && @sample_rate > 0
          @sample_rate = @sample_rate.to_f
        end

        # Calls the #sample methods of all summands, applies gains, adds them all
        # to the initial #constant value, and returns the result.
        #
        # If any summand (or every summand if stop_early was set to false in the
        # constructor) returns nil or an empty buffer, then this method will
        # return nil.
        def sample(count)
          arithmetic_sample(count, sources: @gains, pad: 0, fill: @constant, stop_early: @stop_early) do |retbuf, inputs|
            inputs.each do |v, gain|
              tmpbuf = @tmpbuf[0...v.length]
              tmpbuf.fill(gain).inplace * v
              retbuf.inplace + tmpbuf
            end
          end
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
          samp = find_summand(summand, create: true)
          @gains[samp] = gain
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
        end

        # Removes all summands, but does not reset the constant, if set.
        def clear
          @gains.clear
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
          @gains.keys + [@constant]
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
