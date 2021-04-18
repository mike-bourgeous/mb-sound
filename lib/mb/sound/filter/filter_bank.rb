module MB
  module Sound
    class Filter
      # An array of identical filters.  When called with an array of data to
      # process, each filter receives its corresponding element of the array.
      class FilterBank < Filter
        class << self
          # Used by #butterworth and #cookbook to scale filter frequency across
          # the filter bank.  Yields the index and scaled f_center for the index,
          # if f_center is a Range.
          def freq_scaled(size, f_center)
            MB::Sound::Filter::FilterBank.new(size) { |idx|
              f_center = f_center..f_center unless f_center.is_a?(Range)
              fc = MB::M.scale(idx, 0..(size - 1), f_center)
              yield idx, fc
            }
          end

          # Initializes a bank of +size+ identical Butterworth filters with the
          # given parameters (see Sound::Filter::Butterworth).  If +f_center+ is
          # a range, then the filter center frequencies are scaled from the start
          # of the range at the beginning of the fitler bank, to the end of the
          # range at the end of the filter bank.  The +reset+ parameter sets the
          # initial state of the filters.
          def butterworth(size, filter_type, order, f_samp, f_center, reset: 0)
            bank = freq_scaled(size, f_center) { |idx, fc|
              f = MB::Sound::Filter::Butterworth.new(filter_type, order, f_samp, fc)
              f.reset(reset)
              f
            }

            bank.process(Numo::SFloat.zeros(size).fill(reset)) if reset != 0

            bank
          end

          # Initializes a bank of +size+ identical cookbook filters with the given
          # parameters (see Sound::Filter::Cookbook).  The +reset+ parameter sets
          # the initial state of the filters and the last_result from the filter
          # bank.  If +f_center+ is a Range, then the filter frequencies will
          # vary across the filter bank.
          def cookbook(size, filter_type, f_samp, f_center, db_gain: nil, quality: nil, bandwidth_oct: nil, shelf_slope: nil, reset: 0)
            bank = freq_scaled(size, f_center) { |idx, fc|
              f = MB::Sound::Filter::Cookbook.new(filter_type, f_samp, fc, db_gain: db_gain, quality: quality, bandwidth_oct: bandwidth_oct, shelf_slope: shelf_slope)
              f.reset(reset)
              f
            }

            # This populates the #last_result array with the reset value
            bank.process(Numo::SFloat.zeros(size).fill(reset)) if reset != 0

            bank
          end
        end

        # The previous output result, or if process hasn't been called, all
        # zeros.
        attr_reader :last_result

        # The number of filters.
        attr_reader :size

        # The raw array of filters (do not modify).
        attr_reader :filters

        # Initializes a filter bank with +size+ filters.  Pass a block that
        # constructs the desired filter.  The block will be yielded to with the
        # index of the filter (so a different filter could be created for each
        # index, if desired).
        def initialize(size)
          raise 'Size must be a positive integer' unless size.is_a?(Integer) && size > 0
          raise 'A block must be given to construct each filter' unless block_given?
          @size = size
          @filters = Array.new(size) do |idx|
            yield idx
          end

          @last_result = Numo::SFloat.zeros(size)

          raise 'Filters must respond to the #process method' unless @filters.all? { |f| f.respond_to?(:process) }
        end

        # Returns the first filter in the bank.
        def first
          @filters.first
        end

        # Returns the last filter in the bank.
        def last
          @filters.last
        end

        # Returns the +idx+-th filter in the bank.
        def [](idx)
          @filters[idx]
        end

        # Processes samples in +data+, which would generally be an array of real
        # numeric values.  If the underlying filters can process multiple
        # samples, then each element in +data+ may be an array of samples.
        def process(data)
          weighted_process(data, 1.0)
        end

        # Like #process, but a strength factor may be specified either for all
        # filters (as a number) or for each filter individually (as an array).
        # This strength factor is passed into each filter's weighted_process
        # method, if it has one (an error will be raised if any filter does not
        # support weighted processing and the +strength+ is not 1.0).
        def weighted_process(data, strength = 1.0)
          raise 'Data size does not match filter bank size' unless data.size == @size

          @filters.each_with_index do |f, idx|
            d = data[idx]
            if d.respond_to?(:length) || strength == 1.0
              raise 'Weight is not supported with multi-sample processing' if strength != 1.0
              d = Numo::NArray[d] unless d.respond_to?(:length)
              @last_result[idx] = f.process(d)
            elsif 
              w = strength.respond_to?(:length) ? strength[idx] : strength
              @last_result[idx] = f.weighted_process(data[idx], w)
            end
          end

          @last_result
        end
      end
    end
  end
end
