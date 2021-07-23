module MB
  module Sound
    # Interpolates values using keyframes along a timeline using linear,
    # smoothstep, or other interpolation techniques.
    #
    # Note that :catmull_rom is quite a bit slower than other methods.
    #
    # Examples:
    #     # The :blend value controls the segment after the given keyframe.
    #     # The :time unit is arbitrary; just be consistent (always seconds, or
    #     # always frames, etc.)
    #     ti = MB::Sound::TimelineInterpolator.new([
    #       { time: 0.0, data: [ 0, 0, 0 ], blend: :linear },
    #       { time: 1.0, data: [ 1, -1, 0 ], blend: :smoothstep },
    #       { time: 2.5, data: [ -1, 1, -1 ], blend: :smootherstep },
    #       { time: 5.0, data: [ 0, 0, 1 ], blend: :catmull_rom, alpha: 0.5 },
    #       { time: 8.0, data: [ 1, 2, 3 ] },
    #     ])
    #
    #     ti.value(0.5)
    #     # => [ 0.5, -0.5, 0.0 ]
    class TimelineInterpolator
      INTERPOLATORS = [
        :catmull_rom,
        :linear,
        :smoothstep,
        :smootherstep,
      ]

      # Initializes a timeline interpolator with the given Array of
      # +keyframes+.  A keyframe is a Hash containing the time and an Array
      # with the values to interpolate.
      #
      # If different values need different keyframes, use more than one
      # TimelineInterpolator.
      #
      # The +:default_blend+ parameter specifies the default method for
      # interpolating keyframes.
      #
      # The +:default_alpha+ parameter controls the alpha value given to
      # MB::M::InterpolationMethods#catmull_rom (or other future interpolators
      # that accept a parameter) if a keyframe does not specify its own alpha
      # value.
      def initialize(keyframes, default_blend: :smootherstep, default_alpha: 0.5)
        raise "Unsupported blending mode #{default_blend.inspect}" unless INTERPOLATORS.include?(default_blend)
        @default_blend = default_blend

        raise "Default alpha value must be numeric" unless default_alpha.is_a?(Numeric)
        @default_alpha = default_alpha

        raise "A keyframe is missing its :time" unless keyframes.all? { |k| k.include?(:time) }
        raise "A keyframe is missing its :data" unless keyframes.all? { |k| k.include?(:data) }
        @keyframes = keyframes.sort_by { |s| s[:time] }

        # Keyframes in Catmull-Rom-compatible format, with an extra copy of the first and last frames.
        # Technically we only need these modified keyframes around :catmull_rom segments
        @crframes = @keyframes.map { |k|
          Numo::NArray.cast(k[:data]).freeze
        }
        # FIXME: this doesn't do a good job of making :catmull_rom work at start or end segments
        # tried using time as a dimension; maybe try using index as a dimension?
        # FIXME: catmull_rom blows up if sequential points are identical
        first_frame = @crframes[0].map { |v| v - 1 }
        last_frame = @crframes[-1].map { |v| v + 1 }
        @crframes.unshift(first_frame.freeze)
        @crframes.push(last_frame.freeze)

        @min_time = @keyframes[0][:time]
        @max_time = @keyframes[-1][:time]

        unless @keyframes.all? { |k| INTERPOLATORS.include?(k[:blend] || @default_blend) }
          raise "A keyframe has an invalid :blend"
        end

        num_values = @keyframes.map { |k| k[:data].respond_to?(:length) ? k[:data].length : 1 }.uniq
        raise "All keyframes must have the same number of data values" unless num_values.length == 1
        raise "There must be at least one data value to interpolate" unless num_values[0] >= 1
      end

      # Returns an interpolated keyframe at the given +time+ (in arbitrary
      # units as determined at construction, e.g. seconds, samples, frames),
      # which may be an Array or Numo::NArray to evaluate multiple times.
      def value(time)
        if time.respond_to?(:map)
          return time.to_a.map { |t| value(t) }
        end

        case
        when time <= @keyframes[0][:time]
          return @keyframes[0][:data]

        when time >= @keyframes[-1][:time]
          return @keyframes[-1][:data]

        else
          idx = @keyframes.bsearch_index { |k| k[:time] > time } || @keyframes.length - 1
        end

        idx0 = idx - 2
        idx1 = idx - 1
        idx2 = idx
        idx3 = idx + 1
        k1 = @keyframes[MB::M.clamp(idx1, 0, @keyframes.length - 1)]
        k2 = @keyframes[MB::M.clamp(idx2, 0, @keyframes.length - 1)]

        time_span = k2[:time] - k1[:time]
        time_offset = time - k1[:time]
        index_offset = time_span == 0 ? 0 : time_offset.to_f / time_span

        raise "BUG: Index offset #{index_offset} at time #{time} is not 0..1" if index_offset < 0 || index_offset > 1

        case k1[:blend] || @default_blend
        when :linear
          MB::M.interp(k1[:data], k2[:data], index_offset)

        when :smoothstep
          MB::M.interp(k1[:data], k2[:data], MB::M.smoothstep(index_offset))

        when :smootherstep
          MB::M.interp(k1[:data], k2[:data], MB::M.smootherstep(index_offset))

        when :catmull_rom
          # TODO: this is probably not accounting for time correctly; the derivatives don't look super smooth
          v0 = @crframes[MB::M.clamp(idx0 + 1, 0, @crframes.length - 1)]
          v1 = @crframes[MB::M.clamp(idx1 + 1, 0, @crframes.length - 1)]
          v2 = @crframes[MB::M.clamp(idx2 + 1, 0, @crframes.length - 1)]
          v3 = @crframes[MB::M.clamp(idx3 + 1, 0, @crframes.length - 1)]

          v = MB::M.catmull_rom(v0, v1, v2, v3, index_offset, k1[:alpha] || @default_alpha)
          v = v.to_a if k1[:data].is_a?(Array)
          v

        else
          raise "BUG: Unsupported blending mode #{k1[:blend] || @default_blend}"
        end
      end
    end
  end
end
