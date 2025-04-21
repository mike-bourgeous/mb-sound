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
        def initialize(summands, sample_rate:, stop_early: true)
          @constant = 0
          @summands = {}

          @complex = false

          @stop_early = stop_early

          raise 'Sample rate must be a positive numeric' unless sample_rate.is_a?(Numeric) && sample_rate > 0
          @sample_rate = sample_rate.to_f

          # TODO: Allow variable length argument lists (kind of tricky to detect
          # the different cases of arrays vs hashes vs varargs accurately)
          summands = [summands] unless summands.is_a?(Array) || summands.is_a?(Hash)

          summands.each_with_index do |(s, gain), idx|
            gain ||= 1.0

            @complex = true if gain.is_a?(Complex)

            case
            when s.is_a?(Numeric)
              @constant += s * gain

            when s.is_a?(Array)
              raise "Multiplicand cannot be an Array, even though it responds to :sample"

            when s.respond_to?(:sample)
              raise "Duplicate summand #{s} at index #{idx}" if @summands.include?(s)
              @summands[s] = gain

            else
              raise ArgumentError, "Summand #{s.inspect} at index #{idx} is not a Numeric and does not respond to :sample"
            end
          end

          @buf = nil
        end

        # Calls the #sample methods of all summands, applies gains, adds them all
        # to the initial #constant value, and returns the result.
        #
        # If any summand (or every summand if stop_early was set to false in the
        # constructor) returns nil or an empty buffer, then this method will
        # return nil.
        def sample(count)
          @complex ||= @constant.is_a?(Complex)

          inputs = @summands.map { |s, gain|
            v = s.sample(count)&.not_inplace!
            next if v.nil? || v.empty?
            @complex ||= gain.is_a?(Complex) || v.is_a?(Numo::SComplex) || v.is_a?(Numo::DComplex)
            v = MB::M.zpad(v, count) if v && v.length > 0 && v.length < count
            [v, gain]
          }

          inputs.compact!

          if @stop_early
            return nil if inputs.length != @summands.length
          else
            return nil if inputs.empty? && !@summands.empty?
          end

          setup_buffer(length: count, complex: @complex, temp: true)

          @buf.fill(@constant)

          inputs.each do |v, gain|
            next if v.nil? || v.empty?
            @tmpbuf.fill(gain).inplace * v
            @buf.inplace + @tmpbuf
          end

          @buf.not_inplace!
        end

        # Returns the gain value for the given +summand+, or nil if the summand
        # is not present.  The +summand+ may be an Integer to refer to a summand
        # by insertion order (starting at 0).
        def [](summand)
          summand = @summands.keys[summand] if summand.is_a?(Integer)
          @summands[summand]
        end

        # Sets the gain value for the given +summand+ (which must respond to the
        # :sample method), adding it to the mixer if it is not already present.
        # The +summand+ may be an Integer to refer to a summand by insertion
        # order (starting at 0).
        def []=(summand, gain)
          # TODO: smooth gain changes
          summand = @summands.keys[summand] if summand.is_a?(Integer)
          @complex = true if gain.is_a?(Complex)
          raise "Summand #{summand} must respond to :sample" unless summand.respond_to?(:sample)
          @summands[summand] = gain
        end

        # Removes the given +summand+ from the mixer.  The +summand+ may be an
        # Integer to refer to a summand by insertion order (starting at 0), in
        # which case summands added after this one will have their index
        # decremented by one.
        def delete(summand)
          summand = @summands.keys[summand] if summand.is_a?(Integer)
          @summands.delete(summand)
        end

        # Removes all summands, but does not reset the constant, if set.
        def clear
          @summands.clear
        end

        # Returns the number of summands (excluding a possible constant value).
        def count
          @summands.length
        end
        alias length count

        # Returns true if there are no summands (apart from a possible constant
        # value).
        def empty?
          @summands.empty?
        end

        # Returns an Array of the summands in this mixer (without their gains).
        def summands
          @summands.keys
        end

        # See GraphNode#sources
        def sources
          @summands.keys + [@constant]
        end

        # Returns an Array of the gains in this mixer (without their summands).
        def gains
          @summands.values
        end

        # Adds the given +other+ sample source to this mixer with a gain of 1.0.
        def +(other)
          if other.is_a?(Numeric)
            @constant += other
          else
            raise "Summand #{other} is already present on mixer #{self}" if @summands.include?(other)
            other.or_for(nil) if other.respond_to?(:or_for) # Default to playing forever
            self[other] = 1.0
          end

          self
        end

        # Adds the given +other+ sample source to this mixer with a gain of -1.0.
        def -(other)
          if other.is_a?(Numeric)
            @constant -= other
          else
            raise "Summand #{other} is already present on mixer #{self}" if @summands.include?(other)
            other.or_for(nil) if other.respond_to?(:or_for) # Default to playing forever
            self[other] = -1.0
          end

          self
        end
      end
    end
  end
end
