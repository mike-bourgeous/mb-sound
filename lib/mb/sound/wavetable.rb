module MB
  module Sound
    # Methods related to saving, loading, generating, and sampling from
    # wavetables.
    #
    # See MB::Sound::GraphNode::Wavetable.
    # See bin/make_wavetable.rb.
    module Wavetable
      # Loads an existing wavetable from the given +filename+, using the
      # mb_sound_wavetable_period metadata tag to slice the file.
      #
      # TODO: If the file does not have the mb_sound_wavetable_period tag, then
      # the audio is passed into Wavetable.make_wavetable to create a wavetable
      # from a normal sound file.
      def self.load_wavetable(filename)
        metadata = {}
        data = MB::Sound.read(filename, metadata_out: metadata)
        data = data.sum / data.length

        period = metadata[:mb_sound_wavetable_period]&.to_i
        raise 'Wavetable period must be greater than 1' if period.is_a?(Integer) && period <= 1

        if period
          count = data.length / period
          data[0...(count * period)].reshape(count, period)
        else
          raise NotImplementedError, "#{filename.inspect} is not an mb-sound wavetable.  TODO: implement on-the-fly wavetable conversion"
        end
      end

      # Saves 2D NArray +data+ containing a wavetable to the given sound
      # +filename+, using the mb_sound_wavetable_period tag to record the
      # correct shape of the wavetable.  The rows of the NArray are the entries
      # in the table, and the columns are the audio samples over time.
      def self.save_wavetable(filename, data, sample_rate: 48000)
        raise 'Data must be a 2D Numo::NArray' unless data.is_a?(Numo::NArray) && data.ndim == 2

        period = data.shape[1]
        total = data.length
        MB::Sound.write(filename, data.reshape(total), sample_rate: sample_rate, metadata: { mb_sound_wavetable_period: period })
      end

      # TODO: functions to sort wavetables by brightness, etc.?
      # TODO: functions to shuffle wavetables?
      # TODO: move make_wavetable.rb functionality into a function here
      # TODO: optimized C version?

      # Performs a fractional wavetable lookup with wraparound.
      #
      # :number - A 1D Numo::NArray with the wave number (from 0..1) over time
      # :phase - A 1D Numo::NArray with the wave phase (from 0..1)over time
      #
      # TODO: bouncing or zero-extending?
      #
      # See MB::Sound::GraphNode#wavetable.
      def self.wavetable_lookup(wavetable:, number:, phase:)
        raise 'Number and phase must be the same size array' unless number.length == phase.length

        number.map_with_index do |num, idx|
          phi = phase[idx]
          outer_lookup(wavetable: wavetable, number: num, phase: phi)
        end
      end

      # Blends two columns within a single row of the wavetable.  You should
      # probably use .wavetable_lookup or .outer_lookup.
      #
      # :number - The wave number index, which should be an integer.
      # :phase - Time index from 0 to 1.
      #
      # TODO: bouncing or zero-extending?
      def self.inner_lookup(wavetable:, number:, phase:)
        row = number.floor

        fcol = (phase % 1.0) * wavetable.shape[1]
        col1 = fcol.floor
        col2 = fcol.ceil
        col1 %= wavetable.shape[1]
        col2 %= wavetable.shape[1]

        ratio = fcol - col1

        val1 = wavetable[row, col1]
        val2 = wavetable[row, col2]

        val2 * ratio + val1 * (1.0 - ratio)
      end

      # Blends two waves using #inner_lookup.  See also #wavetable_lookup.
      #
      # :number - Fractional wave number from 0 to 1.
      # :phase - Time index from 0 to 1.
      def self.outer_lookup(wavetable:, number:, phase:)
        wave_count = wavetable.shape[0]
        frow = (number * wave_count) % wave_count
        row1 = frow.floor
        row2 = frow.ceil
        row1 %= wave_count
        row2 %= wave_count

        ratio = frow - row1

        val1 = inner_lookup(wavetable: wavetable, number: row1, phase: phase)
        val2 = inner_lookup(wavetable: wavetable, number: row2, phase: phase)

        val2 * ratio + val1 * (1.0 - ratio)
      end
    end
  end
end
