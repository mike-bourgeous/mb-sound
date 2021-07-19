module MB
  module Sound
    # Interpolates values using keyframes along a timeline using linear,
    # smoothstep, or other interpolation techniques.
    #
    # Examples:
    #     # The :blend value controls the segment after the given keyframe.
    #     # The :time unit is arbitrary; just be consistent (always seconds, or
    #     # always frames, etc.)
    #     ti = MB::Sound::TimelineInterpolator.new([
    #       { time: 0.0, data: [ 0, 0, 0 ], blend: :linear },
    #       { time: 1.0, data: [ 1, -1, 0 ], blend: :smoothstep },
    #       { time: 5.0, data: [ 0, 0, 1] },
    #     ])
    #
    #     ti.value(0.5) # FIXME TODO correct return
    #     # => [ 0.5, -0.5, 0 ]
    class TimelineInterpolator
      INTERPOLATORS = [
        :catmull_rom,
        :linear,
        :smoothstep,
        :smootherstep,
      ]

      # Initializes a timeline interpolator with the given Array of
      # +keyframes+.  A keyframe is a Hash containing the time and an Array
      # with the values to interpolate.  If different values need different
      # keyframes, use more than one TimelineInterpolator.  The
      # +:default_blend+ parameter specifies the default method for
      # interpolating keyframes.
      def initialize(keyframes, default_blend: :smootherstep)
        raise "Unsupported blending mode #{default_blend.inspect}" unless INTERPOLATORS.include?(default_blend)
        @default_blend = default_blend

        @keyframes = keyframes.sort_by { |s| s[:time] }
        raise "A keyframe is missing its :time" unless @keyframes.all? { |k| k.include?(:time) }
        raise "A keyframe is missing its :data" unless @keyframes.all? { |k| k.include?(:time) }

        unless @keyframes.all? { |k| INTERPOLATORS.include?(k[:blend] || @default_blend) }
          raise "A keyframe has an invalid :blend"
        end

        num_values = @keyframes.map { |k| k[:data].length }.uniq
        raise "All keyframes must have the same number of data values" unless num_values.length == 1
        raise "There must be at least one data value to interpolate" unless num_values[0] >= 1
      end

      # Returns an interpolated keyframe at the given +time+ (in arbitrary
      # units as determined at construction, e.g. seconds, samples, frames),
      # which may be an Array or Numo::NArray to evaluate multiple times.
      def value(time)
        if time.is_a?(Array) || time.is_a?(Numo::NArray)
          return time.map { |t| value(t) }
        end

        case
        when time <= @keyframes[0][:time]
          idx = 0

        when time >= @keyframes[-1][:time]
          idx = @keyframes.length - 1

        else
          idx = @keyframes.bsearch_index { |k| k[:time] > time } || @keyframes.length - 1
        end

        idx0 = idx - 2
        idx1 = idx - 1
        idx2 = idx
        idx3 = idx + 1
        k0 = @keyframes[MB::M.clamp(idx0, 0, @keyframes.length - 1)]
        k1 = @keyframes[MB::M.clamp(idx1, 0, @keyframes.length - 1)]
        k2 = @keyframes[MB::M.clamp(idx2, 0, @keyframes.length - 1)]
        k3 = @keyframes[MB::M.clamp(idx3, 0, @keyframes.length - 1)]

        time_span = k2[:time] - k1[:time]
        time_offset = time - k1[:time]
        index_offset = time_span == 0 ? 0 : time_offset.to_f / time_span

        # XXX TODO
        { index: idx + index_offset, time: time, time_offset: time_offset, k: [k0, k1, k2, k3] }
      end
    end
  end
end
