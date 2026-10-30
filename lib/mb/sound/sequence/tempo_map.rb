module MB
  module Sound
    module Sequence
      # The tempo as a function of timeline position (tempo-maps-1,
      # 2026-10-28; design/notes/tempo_sync.md, "Tempo maps"): a frozen list
      # of segments, each in effect from its +pos+ (whole notes) until the
      # next one:
      #
      # - Step: a constant +bpm+.
      # - Ramp: from +from+ to +to+ BPM over +length+ whole notes, shaped by
      #   +curve+ (a Curve over the ramp's share of its length; linear by
      #   default: a straight line in BPM on the bar ruler); +to+ holds
      #   afterwards.
      # - Follow: +source+ read as BPM (a Session knob name, a Knob or
      #   reader, or a MIDI::Param such as `4.bars.lfo.at(150..180)`).
      #
      # The Transport holds one (Transport#tempo_map); a Session renders a
      # ramp or a follow in tempo cells of CELL run frames, each at the
      # map's tempo at the cell's first position (#bpm_at, quantized to
      # QUANTUM), so positions stay exact Rationals and every buffer size
      # renders the same frames at the same tempos.
      #
      #     map = TempoMap.constant(120).ramp(140, at: 4, length: 4)  # 4 bars 120 -> 140 from bar 2 in 4/4
      #     map.bpm_at(6)      # => 130
      #     TempoMap.steps([[0, 120], [8, 90]])  # (e.g. from a MIDI file's tempo events)
      class TempoMap
        include Enumerable

        # Run frames per tempo cell (the clocks' cells, Clock::CELL).
        CELL = 800

        # Ramp and followed tempos are rounded to this many BPM, so the
        # Rational positions they integrate keep bounded denominators.
        QUANTUM = Rational(1, 1024)

        # The slowest and fastest tempos a followed source or a ramp gives
        # (values outside are limited to them).
        MIN_BPM = 1
        MAX_BPM = 999

        Step = Data.define(:pos, :bpm) do
          def varying? = false
          def end_pos = pos
          def bpm_at(_pos, _reader = nil) = bpm
          def to_ruby = "step(#{TempoMap.pos_ruby(pos)}, #{TempoMap.number_ruby(bpm)})"
        end

        Ramp = Data.define(:pos, :from, :to, :length, :curve) do
          def varying? = true
          def end_pos = pos + length

          # The ramp's tempo at +p+ (exact at its ends, quantized inside).
          def bpm_at(p, _reader = nil)
            return from if p <= pos
            return to if p >= end_pos
            x = ((p - pos) / length).to_f
            y = curve ? curve.call(x) : x
            TempoMap.quantize(from + (to - from) * y)
          end

          def to_ruby
            c = curve && (curve.to_ruby || curve.name.inspect)
            "ramp(#{TempoMap.pos_ruby(pos)}, #{TempoMap.number_ruby(from)} => #{TempoMap.number_ruby(to)}, " \
              "length: #{TempoMap.number_ruby(length)}#{", curve: #{c}" if c})"
          end
        end

        Follow = Data.define(:pos, :source, :last) do
          def varying? = true
          def end_pos = pos

          # The source's value at +p+ through +reader+ (a callable taking
          # the source and the position; see Session::TempoChanges), or the
          # last tempo read without one.
          def bpm_at(p, reader = nil)
            return last unless reader
            TempoMap.limit(reader.call(source, p))
          end

          def to_ruby
            "follow(#{TempoMap.pos_ruby(pos)}, #{TempoMap.source_ruby(source)})"
          end
        end

        # The segments, earliest first (frozen).
        attr_reader :segments

        # True for maps assigned whole (Transport#tempo_map=, e.g. from a
        # MIDI file): seeks read them as a function of position instead of
        # collapsing them to the tempo in effect (see Transport#seek).
        def fixed?
          @fixed
        end

        # A map of one constant tempo.
        def self.constant(bpm)
          new([Step.new(pos: -Float::INFINITY, bpm: check_bpm(bpm))])
        end

        # A map of tempo steps from [position (whole notes), BPM] pairs (the
        # first tempo also holds before the first position): the shape a
        # MIDI file's tempo events convert to (positions from ticks: ticks /
        # (4 * ticks per quarter note)).  Fixed (see #fixed?).
        def self.steps(pairs)
          raise ArgumentError, 'A tempo map needs at least one [position, bpm] pair' if pairs.empty?
          sorted = pairs.map { |p, b| [p.to_r, check_bpm(b)] }.sort_by(&:first)
          first = Step.new(pos: -Float::INFINITY, bpm: sorted.first[1])
          rest = sorted.drop(1).map { |p, b| Step.new(pos: p, bpm: b) }
          new([first, *rest], fixed: true)
        end

        def initialize(segments, fixed: false)
          raise ArgumentError, 'A tempo map needs a segment' if segments.empty?
          @segments = segments.freeze
          @fixed = fixed
          @static = segments.length == 1 && !segments[0].varying?
          freeze
        end

        def each(&block)
          @segments.each(&block)
        end

        # True for a single constant tempo (the old Transport: nothing to
        # integrate, no spans to split).
        def static?
          @static
        end

        # The segment in effect at position +pos+.
        def segment_at(pos)
          s = @segments
          return s[0] if s.length == 1
          i = s.length - 1
          i -= 1 while i > 0 && s[i].pos > pos
          s[i]
        end

        # The tempo at +pos+ (a Rational or Integer BPM), reading followed
        # sources through +reader+ (see Follow#bpm_at).
        def bpm_at(pos, reader = nil)
          segment_at(pos).bpm_at(pos, reader)
        end

        # True if the tempo moves at +pos+ (a ramp in progress or a follow).
        def varying_at?(pos)
          seg = segment_at(pos)
          seg.varying? && (seg.is_a?(Follow) || pos < seg.end_pos)
        end

        # The next position after +pos+ where the map changes shape (a
        # ramp's start or end, a later segment), or nil.
        def next_break(pos)
          best = nil
          @segments.each do |s|
            [s.pos, s.end_pos].each do |p|
              next unless p.is_a?(Rational) || p.is_a?(Integer)
              best = p if p > pos && (best.nil? || p < best)
            end
          end
          best
        end

        # A new map with +segment+ from its position, forgetting segments
        # at or after it (like the meter and key maps).  Not fixed.
        def with(segment)
          kept = @segments.reject { |s| s.pos >= segment.pos }
          # (a ramp cut short by the new segment simply stops there: #segment_at
          # reads the later segment from its position on)
          kept = [Step.new(pos: -Float::INFINITY, bpm: segment_at(segment.pos).bpm_at(segment.pos))] if kept.empty?
          TempoMap.new([*kept, segment])
        end

        # A new map with a ramp from the tempo in effect at +at+ to +to+
        # BPM over +length+ whole notes.
        def ramp(to, at:, length:, curve: nil)
          at = at.to_r
          length = length.to_r
          raise ArgumentError, "A tempo ramp needs a positive length (got #{length})" unless length > 0
          with(Ramp.new(pos: at, from: bpm_at(at), to: TempoMap.check_bpm(to), length: length, curve: curve))
        end

        # A new map with a constant +bpm+ from +at+.
        def step(bpm, at:)
          with(Step.new(pos: at.to_r, bpm: TempoMap.check_bpm(bpm)))
        end

        # A new map following +source+ from +at+ (+last+: the tempo it
        # starts from until first read).
        def follow(source, at:, last: nil)
          at = at.to_r
          with(Follow.new(pos: at, source: source, last: last || bpm_at(at)))
        end

        # This map, or a constant map when nothing moves at or after +pos+
        # any more (a live map whose last segment is a step in effect, or a
        # finished ramp), so the Session's constant-tempo path comes back.
        # Fixed maps stay as they are.
        def settled(pos)
          return self if @fixed || @static || next_break(pos)
          seg = segment_at(pos)
          return self if seg.is_a?(Follow)
          TempoMap.constant(seg.bpm_at(pos))
        end

        # The map collapsed to what is in effect at +pos+ (for seeks): one
        # segment from -Infinity (a step at the tempo there, or the follow).
        def collapse(pos, bpm)
          seg = segment_at(pos)
          first = seg.is_a?(Follow) ? seg.with(pos: -Float::INFINITY, last: bpm) : Step.new(pos: -Float::INFINITY, bpm: bpm)
          TempoMap.new([first])
        end

        # The length in whole notes of a ramp from +from+ to +to+ BPM shaped
        # by +curve+ that lasts +seconds+: the time over L whole notes is
        # L * 240 * mean(1 / bpm(x)) for x over 0..1 (Simpson's rule).
        def self.ramp_length_for_seconds(from, to, seconds, curve = nil)
          n = 256
          f = ->(x) { 1.0 / (from + (to - from) * (curve ? curve.call(x) : x)).to_f }
          sum = f.(0.0) + f.(1.0)
          (1...n).each { |i| sum += (i.odd? ? 4 : 2) * f.(i.to_f / n) }
          mean = sum / (3.0 * n)
          (seconds.to_f / (240.0 * mean)).rationalize(Rational(1, 1_000_000))
        end

        # +bpm+ (a number or a Tempo) as an exact Rational, raising for
        # anything that isn't a positive tempo.
        def self.check_bpm(bpm)
          bpm = bpm.to_r if bpm.is_a?(MB::Sound::Tempo)
          raise ArgumentError, "BPM must be a positive number (got #{bpm.inspect})" unless bpm.is_a?(Numeric) && bpm.real? && bpm.finite? && bpm > 0
          bpm.is_a?(Float) ? MB::Sound::Tempo.exact(bpm) : bpm.to_r
        end

        # A value read from a followed source as BPM: Tempo values, else
        # numbers, limited to MIN_BPM..MAX_BPM and quantized.
        def self.limit(value)
          value = value.to_r if value.is_a?(MB::Sound::Tempo)
          v = value.to_f
          v = MIN_BPM.to_f unless v.finite? && v >= MIN_BPM
          v = MAX_BPM.to_f if v > MAX_BPM
          quantize(v)
        end

        # +x+ rounded to QUANTUM BPM (a Rational).
        def self.quantize(x)
          Rational((x * QUANTUM.denominator).round, QUANTUM.denominator)
        end

        def self.pos_ruby(pos)
          pos.is_a?(Float) ? (pos < 0 ? '-Float::INFINITY' : pos.to_s) : number_ruby(pos)
        end

        def self.number_ruby(x)
          RubyValue.number(x)
        end

        def self.source_ruby(source)
          case source
          when Symbol then source.inspect
          when GraphNode::Knob then "knob(#{source.name.inspect})"
          when GraphNode::Knob::Reader then "knob(#{source.knob.name.inspect})"
          else source.respond_to?(:to_ruby) ? source.to_ruby : source.to_s
          end
        end

        def ==(other)
          other.is_a?(TempoMap) && other.segments == @segments && other.fixed? == @fixed
        end
        alias eql? ==

        def hash
          [TempoMap, @segments, @fixed].hash
        end

        # Ruby-like text of the segments (for inspection and take headers).
        def to_s
          "#<TempoMap #{@segments.map(&:to_ruby).join(', ')}#{' (fixed)' if @fixed}>"
        end
        alias inspect to_s
      end
    end
  end
end
