module MB
  module Sound
    # Methods for adjusting and normalizing the loudness of sounds.
    module GainMethods
      # Normalizes +channels+ (an Array of Numo::NArray) together to have a maximum
      # absolute value less than or equal to +limit+.  All channels receive the
      # same amplification.  This is most useful when applied to the time domain.
      #
      # If +louder+ is true, then quieter sounds will be amplified so that their
      # maximum absolute value equals +limit+.  If +louder+ is a Numeric, then the
      # scaling factor for quieter sounds will be blended between no modification
      # for louder = 0, and total normalization for louder = 1.  When applied in
      # overlapping windows, a fractional value for +louder+ acts similarly to a
      # volume leveler.
      #
      # Modifies data in place.
      def normalize_max(channels, limit = 1, louder: false)
        return normalize_max([channels], limit, louder: louder)[0] unless channels.is_a?(Array)

        max = channels.map { |c| c.not_inplace!.abs.max }.max

        return channels if max <= limit && !louder

        mult = max > 0 ? limit / max : 1
        mult = (1 - louder) + louder * mult if max < limit && louder.is_a?(Numeric)

        channels.each do |c|
          c.inplace * mult
        end
      end

      # Normalizes each channel separately to have a sum of absolute values less
      # than or equal to +max_sum+ (default is 1).  Does not make anything louder.
      # This is most useful when applied to the frequency domain.
      #
      # Modifies data in place.
      def normalize_max_sum(channels, max_sum = 1)
        channels.each do |c|
          c.not_inplace!
          sum = c.abs.sum
          if sum > max_sum
            c.inplace / sum
          end
        end
      end
    end
  end
end
