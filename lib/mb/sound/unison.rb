module MB
  module Sound
    # Detuned unison oscillators (Pitch#unison): +count+ copies of an
    # oscillator at slightly different pitches, mixed to mono or spread
    # across a stereo field (GraphNode::ChannelMixer::Unison).  This module
    # holds the layout math (detune offsets, pan slots, starting phases) and
    # builds the copies; see Pitch#unison for the user-facing description.
    #
    # Ported from the ideas of Tone#unison on the upstream unison-detune
    # branch (detunes jittered around an even spread "for less
    # flangeriness", and random starting phases), on the current Pitch and
    # Tone design: the copies are Pitches made with Pitch#transpose, so a
    # Notes pitch (v.hz) keeps its key sync, bend, glide, and vibrato.
    module Unison
      # The number of copies when Pitch#unison isn't given a count.
      DEFAULT_COUNT = 3

      # How far the :random layout moves each copy from its even position,
      # as a fraction of the distance between neighbors (before the offsets
      # are centered and scaled back to the detune; the upstream branch used
      # a third too).  Below a half, so the copies stay in order.
      JITTER = 1.0 / 3

      # Detune layouts (see .offsets).
      LAYOUTS = [:random, :even].freeze

      # Returns the detune offsets in semitones (an Array of Floats, lowest
      # first) for +count+ copies spread over +detune+ (an Interval such as
      # `12.cents`, or semitones) either side of the pitch: the outermost
      # copies are +detune+ away from the center.
      #
      # +layout+ :even spaces the copies evenly.  :random (the default in
      # Pitch#unison) moves each copy up to a third of the way toward its
      # neighbors with +rng+ (a Random), then centers the offsets (mean 0,
      # so the pitch stays in tune) and scales them so the outermost is
      # +detune+ away again: uneven spacing, so the copies' beats don't
      # line up into a regular flanging pattern.
      #
      # +detune+ may also be an Array of intervals (or semitones), which is
      # returned as given (in semitones, any order); +count+ must match.
      #
      #     Unison.offsets(3, 10.cents, layout: :even)   # => [-0.1, 0.0, 0.1]
      def self.offsets(count, detune, layout: :random, rng: nil)
        count = Integer(count)
        raise ArgumentError, "Unison needs at least one copy (got #{count})" if count < 1

        if detune.is_a?(Array)
          raise ArgumentError, "#{count} copies need #{count} detune offsets (got #{detune.length})" if detune.length != count
          return detune.map { |d| Interval.semitones(d).to_f }
        end

        d = Interval.semitones(detune).to_f
        raise ArgumentError, "Detune must not be negative (got #{detune})" if d < 0
        raise ArgumentError, "Unknown unison layout #{layout.inspect} (use #{LAYOUTS.map(&:inspect).join(' or ')})" unless LAYOUTS.include?(layout)
        return [0.0] if count == 1

        step = 2 * d / (count - 1)
        even = Array.new(count) { |i| -d + step * i }
        return even if layout == :even || d == 0

        rng ||= Random.new(MB::Sound.next_seed)
        moved = even.map { |o| o + JITTER * step * rng.rand(-1.0..1.0) }
        mean = moved.sum / count
        moved.map! { |o| o - mean }
        scale = d / moved.map(&:abs).max
        moved.map { |o| o * scale }
      end

      # Returns a pan slot from -1 (left) to 1 (right) for each of the given
      # detune +offsets+ (semitones), to be scaled by the stereo spread.
      #
      # The slots are spaced evenly.  The copy nearest the pitch takes the
      # center (for an odd count); the others go out in pairs by distance
      # from the pitch, and the sides alternate from pair to pair (the lower
      # copy of the first pair goes right, of the second pair left, ...), so
      # each side gets copies above and below the pitch and the stereo image
      # doesn't lean from low to high.
      #
      #     Unison.pan_slots([-0.2, -0.1, 0, 0.1, 0.2])   # => [-1.0, 0.5, 0.0, -0.5, 1.0]
      def self.pan_slots(offsets)
        n = offsets.length
        slots = Array.new(n, 0.0)
        return slots if n == 1

        order = (0...n).sort_by { |i| [offsets[i].abs, offsets[i]] }
        order.shift if n.odd?

        order.each_slice(2).with_index do |(a, b), j|
          magnitude = n.odd? ? (j + 1).to_f / (n / 2) : (2 * j + 1).to_f / (n - 1)
          low, high = offsets[a] <= offsets[b] ? [a, b] : [b, a]
          side = j.even? ? 1 : -1
          slots[low] = side * magnitude
          slots[high] = -side * magnitude
        end

        slots
      end

      # Returns the indices of the center copies for +offsets+ (semitones),
      # which a unison's +mix:+ leaves at full level (see Pitch#unison and
      # GraphNode::ChannelMixer::Unison): the copy nearest the pitch for an
      # odd count, the two nearest for an even count (with two copies both
      # are center copies, so +mix+ changes nothing).  Ties go to the lower
      # copy, as in .pan_slots.
      #
      #     Unison.center_copies([-0.2, -0.1, 0, 0.1, 0.2])   # => [2]
      #     Unison.center_copies([-0.3, -0.1, 0.1, 0.3])      # => [1, 2]
      def self.center_copies(offsets)
        n = offsets.length
        order = (0...n).sort_by { |i| [offsets[i].abs, offsets[i]] }
        order.first(n.odd? ? 1 : 2).sort
      end

      # Returns the layout positions of +count+ copies for a detune that
      # changes (a graph node): fractions from -1 to 1 of the detune, from
      # the same layouts as .offsets (Unison.offsets(count, 1)).  Used by
      # Unison::Detune.
      def self.fractions(count, layout: :random, rng: nil)
        offsets(count, 1, layout: layout, rng: rng).map { |o| o.clamp(-1.0, 1.0) }
      end

      # Gives +tone+ the unison starting +phase+ (see Pitch#unison):
      # :random calls Tone#rnd, a number (radians) Tone#with_phase, and
      # :reset leaves the tone as it is.  Returns the tone.
      def self.apply_phase(tone, phase)
        case phase
        when :random then tone.random_phase? ? tone : tone.rnd
        when Numeric then tone.with_phase(phase)
        else tone
        end
      end

      # Checks a unison +phase+ setting.
      def self.check_phase(phase)
        return if phase == :random || phase == :reset || phase.is_a?(Numeric)

        raise ArgumentError, "Unison phase must be :random, :reset, or radians (got #{phase.inspect})"
      end

      # Builds a unison of +pitch+ (see Pitch#unison for the arguments):
      # calls the block once per copy with a detuned Pitch (oscillators
      # made from it get the +phase+ setting) and the copy's index, and
      # returns the copies mixed by a GraphNode::ChannelMixer::Unison (one
      # node for mono, a Channels bundle for stereo).
      def self.build(pitch, count = nil, detune:, layout:, phase:, spread:, normalize:, seed:, detune_mode: :exact, mix: 1)
        count ||= detune.is_a?(Array) ? detune.length : DEFAULT_COUNT
        check_phase(phase)
        unless spread.respond_to?(:sample) || (spread.is_a?(Numeric) && (0..1).cover?(spread))
          raise ArgumentError, "Unison spread must be 0..1 or a graph node (got #{spread.inspect})"
        end
        unless mix.respond_to?(:sample) || (mix.is_a?(Numeric) && (0..GraphNode::ChannelMixer::Unison::MAX_MIX).cover?(mix))
          raise ArgumentError, "Unison mix must be 0..2 or a graph node (got #{mix.inspect})"
        end
        unless Detune::MODES.include?(detune_mode)
          raise ArgumentError, "Unknown detune mode #{detune_mode.inspect} (use #{Detune::MODES.map(&:inspect).join(' or ')})"
        end
        if detune.is_a?(Array) && detune.any? { |d| d.respond_to?(:sample) }
          raise ArgumentError, 'A unison detune Array takes fixed offsets only; for a changing detune give one node (with a layout:) instead'
        end

        rng = Random.new(seed.nil? ? MB::Sound.next_seed : Integer(seed))
        changing = detune.respond_to?(:sample) && !detune.is_a?(Array)

        if changing
          # A changing detune: fixed layout positions scaled by the node
          offsets = fractions(count, layout: layout, rng: rng)
          set = CopySet.new(pitch, detune, fractions: offsets, mode: detune_mode)
          pitches = Array.new(count) { |i| CopyPitch.new(pitch, set: set, index: i) }
        else
          offsets = self.offsets(count, detune, layout: layout, rng: rng)
          pitches = offsets.map { |o| pitch.transpose(o) }
        end

        # Per-copy random settings (see Unison::Copy), drawn after the
        # layout so the layout is the same with or without them
        copy_seed = rng.rand(1 << 30)

        copies = pitches.each_with_index.map { |p, i|
          p.unison_phase = phase
          p.unison_copy = Copy.new(i, count, copy_seed)
          node = block_given? ? yield(p, i) : p.saw
          node = node.signal if node.is_a?(Pitch)
          raise ArgumentError, "A unison block must return a graph node (got #{node.inspect})" unless node.respond_to?(:sample)
          raise ArgumentError, "A unison block must return one channel (got #{node.channel_count})" if node.channel_count != 1
          node
        }

        stereo = spread.respond_to?(:sample) || spread > 0
        mixer = GraphNode::ChannelMixer::Unison.new(
          copies,
          slots: pan_slots(offsets),
          spread: stereo ? spread : 0,
          mix: mix,
          centers: center_copies(offsets),
          stereo: stereo,
          normalize: normalize,
          offsets: changing ? nil : offsets,
          sample_rate: pitch.sample_rate
        )
        stereo ? GraphNode::Channels.new(mixer.outputs) : mixer.outputs[0]
      end
    end
  end
end

require_relative 'unison/detune'
require_relative 'unison/copy'
require_relative 'unison/copy_pitch'
require_relative 'unison/swarm'
