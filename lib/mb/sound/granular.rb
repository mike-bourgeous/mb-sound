require_relative 'granular/kernel_ruby'

module MB
  module Sound
    # Granular synthesis (see design/notes/granular.md): GraphNode::Grains
    # plays clouds of short windowed reads of a Sample (Sample#grains,
    # Notes#grains), with the C kernel FastSampler.grains and its exact Ruby
    # mirror Granular::KernelRuby.
    module Granular
      # Grain window shapes: functions of x in 0..1 (tabulated by .window).
      WINDOWS = {
        hann: ->(x) { 0.5 - 0.5 * Math.cos(2 * Math::PI * x) },
        triangle: ->(x) { 1 - (2 * x - 1).abs },
        tukey: ->(x) {
          # Half flat: raised-cosine edges over a quarter each side
          if x < 0.25 then 0.5 - 0.5 * Math.cos(4 * Math::PI * x)
          elsif x > 0.75 then 0.5 - 0.5 * Math.cos(4 * Math::PI * (1 - x))
          else 1.0
          end
        },
        gauss: ->(x) { Math.exp(-0.5 * ((x - 0.5) / 0.15)**2) },
        blackman: ->(x) { 0.42 - 0.5 * Math.cos(2 * Math::PI * x) + 0.08 * Math.cos(4 * Math::PI * x) },
        rect: ->(x) { [x * 16, (1 - x) * 16, 1].min },
        # Roads' percussive grains: a quick attack (2%) and an exponential
        # decay to -60 dB, and the reverse
        expodec: ->(x) { x < 0.02 ? x / 0.02 : 10**(-3 * (x - 0.02) / 0.98) },
        rexpodec: ->(x) { x > 0.98 ? (1 - x) / 0.02 : 10**(-3 * (0.98 - x) / 0.98) },
      }.freeze

      # Window table length (plus one point).
      WINDOW_POINTS = KernelRuby::WINDOW

      # The default most grains at once.
      MAX_GRAINS = 32

      # The default most grains at once in synth voices (Notes#grains):
      # half a cloud's, since a synth runs several (maintainer, 2026-10-14).
      VOICE_MAX_GRAINS = 16

      # The longest grain (seconds).
      MAX_SIZE = 10.0

      class << self
        # The window table (a frozen DFloat of WINDOW_POINTS + 1 values) for
        # +shape+: a WINDOWS name, a Proc of 0..1, or an Array/NArray of
        # values (resampled linearly).
        def window(shape)
          @windows ||= {}
          return @windows[shape] if shape.is_a?(Symbol) && @windows[shape]

          fn = case shape
               when Symbol, String
                 WINDOWS.fetch(shape.to_sym) { raise ArgumentError, "Unknown grain window #{shape.inspect} (#{WINDOWS.keys.join(', ')}, a Proc, or an Array)" }
               when Proc, Method then shape
               when Array, Numo::NArray
                 v = shape.to_a.map(&:to_f)
                 raise ArgumentError, 'A grain window Array needs at least 2 values' if v.length < 2
                 ->(x) {
                   t = x * (v.length - 1)
                   i = [t.floor, v.length - 2].min
                   v[i] + (v[i + 1] - v[i]) * (t - i)
                 }
               else
                 raise ArgumentError, "A grain window is a name (#{WINDOWS.keys.join(', ')}), a Proc, or an Array (got #{shape.inspect})"
               end
          t = Numo::DFloat.cast(Array.new(WINDOW_POINTS + 1) { |i| fn.call(i.to_f / WINDOW_POINTS).to_f }).freeze
          raise ArgumentError, 'Grain windows must be finite' unless t.isfinite.all?
          @windows[shape] = t if shape.is_a?(Symbol)
          t
        end

        # The mean square of a window table (for normalize:).
        def mean_square(table)
          (table[0...-1]**2).mean.to_f
        end
      end

      # Notes#grains (v.grains in synth voices).
      module NotesMethods
        # A grain cloud of +sample+ (see Sample#grains) following this
        # voice: each grain's pitch tracks the note's frequency (bends and
        # glides included) against the sample's root, and every note-on
        # restarts the scan playhead with a grain on its exact sample.  At
        # most VOICE_MAX_GRAINS (16) grains per voice unless +max_grains:+
        # says otherwise.
        #
        #     synth(midi) { |v| v.grains(pad, density: 40, size: 70.ms) * v.env(0.2, 0.3, 0.8, 1.2) }
        def grains(sample, **options)
          Sample[sample].grains(freq: freq, trigger: trigger, **{ max_grains: VOICE_MAX_GRAINS }.merge(options))
        end
      end
    end
  end
end

require_relative 'graph_node/grains'
MB::Sound::Notes.include(MB::Sound::Granular::NotesMethods)
