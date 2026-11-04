module MB
  module Sound
    # One piece of audio placed on a timeline lane (regions-1; see
    # MB::Sound::SamplerMethods#regions and GraphNode::RegionPlayer): a
    # +sample+ starting +at+ a timeline position for +length+, from +offset+
    # into the source, at +gain+, +transpose+ semitones faster (varispeed:
    # pitch and speed together), with fades in and out along Curves.  The
    # placement fields of a DAW event (ACID's audio events, the .acd study):
    # see design/notes/regions.md.
    #
    # Positions and lengths (+at+, +length+, +fade_in+, +fade_out+) are
    # whole notes (Integers and Rationals, exact, as in `events(...)` rows;
    # 1 is a 4/4 bar), Durations (`2.bars`, `1.n8`), or fixed Lengths
    # (`1.5.seconds`, `10.ms`, `480.samples`), which a player converts at
    # the tempo where it starts.  +length+ nil plays to the end of the
    # source.  +offset+ is source time: seconds (a number) or a Length
    # (`samples` count at the source's rate).  +gain+ is a linear gain or
    # Decibels (`-3.db`).  +curve_in+ and +curve_out+ are Curve names
    # (ACID's six: :linear, :fast, :slow, :smooth, :sharp, :hold) or
    # anything Curve.from takes; a fade-in's gain at its point x (0..1) is
    # curve(x), a fade-out's 1 - curve(x).
    Region = Data.define(:sample, :at, :length, :offset, :gain, :transpose, :fade_in, :fade_out, :curve_in, :curve_out) do
      def initialize(sample:, at:, length: nil, offset: 0, gain: 1, transpose: 0, fade_in: nil, fade_out: nil, curve_in: :linear, curve_out: :linear)
        raise ArgumentError, "A region plays a Sample (got #{sample.inspect})" unless sample.is_a?(MB::Sound::Sample)
        Region.check_time(at, 'at')
        Region.check_time(length, 'length', positive: true) unless length.nil?
        [[fade_in, 'fade_in'], [fade_out, 'fade_out']].each { |v, n| Region.check_time(v, n) unless v.nil? }
        unless offset.is_a?(MB::Sound::Length) || (offset.is_a?(Numeric) && offset.real?)
          raise ArgumentError, "A region's offset is source seconds or a Length (got #{offset.inspect})"
        end
        MB::Sound::Decibels.gain_of(gain, "A region's gain", zero: true, above_one: true)
        raise ArgumentError, "A region's transpose is semitones (got #{transpose.inspect})" unless transpose.is_a?(Numeric) && transpose.real?
        MB::Sound::Curve.from(curve_in)
        MB::Sound::Curve.from(curve_out)
        super
      end

      # A Region from a `regions(...)` row: [sample, at, length, { options }]
      # (length may be nil; the Hash is optional), or a Region.
      def self.row(row)
        return row if row.is_a?(Region)
        unless row.is_a?(Array) && row.length.between?(2, 4)
          raise ArgumentError, "Region rows are Arrays [sample, at, length, { #{Region::OPTIONS.join(':, ')}: }] (got #{row.inspect})"
        end

        sample, at, length, opts = row
        opts, length = length, nil if length.is_a?(Hash) && opts.nil?
        opts ||= {}
        raise ArgumentError, "A region row's options are a Hash (got #{opts.inspect})" unless opts.is_a?(Hash)
        unknown = opts.keys - Region::OPTIONS
        raise ArgumentError, "Unknown region options #{unknown.map(&:inspect).join(', ')} (#{Region::OPTIONS.join(', ')})#{MB::Sound::Form.suggest(unknown.first, Region::OPTIONS)}" unless unknown.empty?

        new(sample: sample, at: at, length: length, **opts)
      end

      # Raises unless +v+ is a timeline time: whole notes (not a Float, so
      # positions stay exact), a Duration, or a fixed Length.
      def self.check_time(v, name, positive: false)
        ok = case v
             when MB::Sound::Sequence::Duration, MB::Sound::Length::Quantity then !v.respond_to?(:fixed?) || v.fixed?
             when Float then false
             when Numeric then v.real?
             else false
             end
        raise ArgumentError, "A region's #{name} is whole notes (an Integer or Rational: 1 is a 4/4 bar), a Duration, or a Length (got #{v.inspect})" unless ok
        raise ArgumentError, "A region's #{name} can't be negative (got #{v.inspect})" if MB::Sound::Length.negative?(v)
        raise ArgumentError, "A region's #{name} must be above 0 (got #{v.inspect})" if positive && Region.whole_notes(v, MB::Sound::Sequence.current_transport, 48000) <= 0
      end

      # +v+ (see .check_time) in whole notes (a Rational) at +transport+'s
      # tempo and +rate+.
      def self.whole_notes(v, transport, rate)
        case v
        when nil then nil
        when MB::Sound::Sequence::Duration then v.whole_notes
        when MB::Sound::Length::Quantity then MB::Sound::Sequence::Duration.rational(transport.whole_notes_of(MB::Sound::Length.seconds(v, sample_rate: rate)))
        else v.to_r
        end
      end

      # The source offset in seconds.
      def offset_seconds
        MB::Sound::Length.seconds(offset, sample_rate: sample.sample_rate)
      end

      # The linear gain.
      def gain_value
        MB::Sound::Decibels.gain_of(gain, "A region's gain", zero: true, above_one: true)
      end

      # The row `regions(...)` prints for this region: options left out
      # where they are the defaults.
      def to_row
        opts = {}
        opts[:offset] = offset unless offset == 0
        opts[:gain] = gain unless gain == 1
        opts[:transpose] = transpose unless transpose == 0
        opts[:fade_in] = fade_in if fade_in
        opts[:fade_out] = fade_out if fade_out
        opts[:curve_in] = curve_in unless curve_in == :linear
        opts[:curve_out] = curve_out unless curve_out == :linear
        opts.empty? ? [sample, at, length] : [sample, at, length, opts]
      end

      def to_s
        "#{sample.name || 'sample'} at #{at.is_a?(Rational) ? MB::Sound::RubyValue.number(at) : at}#{" for #{length}" if length}"
      end
    end

    # The options a region row's Hash may give (see Region.row).
    Region::OPTIONS = %i[offset gain transpose fade_in fade_out curve_in curve_out].freeze
  end
end
