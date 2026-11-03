module MB
  module Sound
    module Analysis
      # The shape and direction of the whole sound's envelopes: its level
      # (5 ms RMS) and its brightness (RMS frequency every 20 ms), each
      # told as times and a direction, so a reading says which way things
      # move ("rises to its peak at 0.62 s, then cuts off"; "brightness
      # falls from 2.1 kHz to 800 Hz").
      #
      # The maintainer's notes on round 3's Bench say envelopes still
      # aren't heard right ("the envelope moves backward", pitch envelopes
      # on the 909 kicks); envelope and pitch-envelope matching is the
      # toolkit's known weak spot (none of Comparison's terms reads them
      # as shapes), so these readings are for looking and hand-tuning.
      #
      # Level:
      # - +peak_time+: the loudest 5 ms block (Length::Seconds from the
      #   start); +attack+: from the onset (Signal#onset) to it.
      # - +decay+: { 6 => t, 20 => t, 40 => t } seconds from the peak until
      #   the level stays under peak - 6/20/40 dB (nil if it never does).
      # - +ending+: :cut when the last 10 ms are within CUT_DB of the peak
      #   (the sound stops while still loud), else :fade.
      # - +shape+: :percussive (peaks in its first 15% or 50 ms and falls
      #   20 dB), :sustained (the middle half within 6 dB of the peak),
      #   :swell (peaks after its middle), else :hump.
      # Brightness: RMS frequencies of 20 ms blocks within 40 dB of the
      # peak (+brightness_times+, +brightness+), and +brightness_motion+
      # (:falling, :rising, or :steady: a third of an octave or more
      # between the first and last fifths, with |r| >= 0.6 against time).
      #
      #     e = Analysis::Envelope.new(sound)
      #     e.shape          # => :percussive
      #     e.decay[20]      # => #<MB::Sound::Length::Seconds 0.21 s>
      #     e.brightness_motion   # => :falling
      class Envelope
        HOP = 240
        BRIGHT_HOP = 960
        RANGE_DB = 40.0
        CUT_DB = 20.0

        attr_reader :signal, :levels, :peak_time, :attack, :decay, :ending, :shape
        attr_reader :brightness_times, :brightness, :brightness_motion, :brightness_from, :brightness_to

        # Measures +sound+ (anything Signal.from takes).
        def initialize(sound)
          @signal = Signal.from(sound)
          rate = Signal::RATE.to_f
          @levels = @signal.envelope_db(HOP)
          frame = HOP / rate
          pk = @levels.max_index
          top = @levels[pk]
          @peak_time = (pk * frame).seconds
          @attack = [(pk * frame) - @signal.onset / rate, 0.0].max.seconds
          @decay = [6, 20, 40].to_h { |d|
            above = @levels[pk..].ge(top - d).where
            last = above.size > 0 ? above[-1] : 0
            [d, last + pk + 1 < @levels.length ? ((last + 1) * frame).seconds : nil]
          }.freeze
          tail = @levels[[@levels.length - 2, 0].max..]
          @ending = tail.max >= top - CUT_DB ? :cut : :fade
          n = @levels.length
          mid = @levels[(n / 4)...[(3 * n / 4), n / 4 + 1].max]
          @shape =
            if (pk < 0.15 * n || pk * frame < 0.05) && @decay[20]
              :percussive
            elsif mid.min >= top - 6
              :sustained
            elsif pk > n / 2
              :swell
            else
              :hump
            end
          brightness_track(top)
        end

        def lines
          d = @decay.filter_map { |db, t| t && "-#{db} dB at +#{Analysis.seconds_label(t.to_f)}" }
          lvl = "level: #{shape_text}, peak at #{Analysis.seconds_label(@peak_time.to_f)} (#{Analysis.seconds_label(@attack.to_f)} after the onset)" \
                "#{d.empty? ? '' : ", then #{d.join(', ')}"}, #{@ending == :cut ? 'cut off while loud' : 'fades out'}"
          br = case @brightness_motion
               when nil then 'brightness: too short to follow'
               when :steady then "brightness steady around #{Analysis.hz_label(@brightness_from)}"
               else "brightness #{@brightness_motion == :falling ? 'falls' : 'rises'} from #{Analysis.hz_label(@brightness_from)} to #{Analysis.hz_label(@brightness_to)}"
               end
          [lvl, br]
        end

        def to_s = lines.join('; ')

        def inspect = "#<#{self.class.name.sub('MB::Sound::', '')} #{self}>"

        def to_h
          { shape: @shape, peak_time: @peak_time.to_f, attack: @attack.to_f, decay: @decay.transform_values { |t| t&.to_f }, ending: @ending,
            brightness_motion: @brightness_motion, brightness_from_hz: @brightness_from, brightness_to_hz: @brightness_to }
        end

        private

        def shape_text
          { percussive: 'percussive (peaks early and decays)', swell: 'swells (peaks late)', sustained: 'sustained', hump: 'rises and falls' }[@shape]
        end

        def brightness_track(top)
          x = @signal.data
          lv = @signal.envelope_db(BRIGHT_HOP)
          times = []
          vals = []
          lv.length.times do |i|
            next if lv[i] < top - RANGE_DB
            seg = x[(i * BRIGHT_HOP)...[(i + 1) * BRIGHT_HOP, x.length].min]
            next if seg.length < 64
            e = (seg**2).sum
            next if e <= 0
            d = seg[1..-1] - seg[0...-1]
            times << (i + 0.5) * BRIGHT_HOP / Signal::RATE.to_f
            vals << Signal::RATE / (2 * Math::PI) * Math.sqrt((d**2).sum / e)
          end
          @brightness_times = Numo::DFloat.cast(times).freeze
          @brightness = Numo::DFloat.cast(vals).freeze
          @brightness_motion = @brightness_from = @brightness_to = nil
          return if vals.length < 5

          fifth = [vals.length / 5, 1].max
          @brightness_from = DSP.median(vals.first(fifth))
          @brightness_to = DSP.median(vals.last(fifth))
          oct = Numo::NMath.log2(@brightness)
          t = @brightness_times
          dt = t - t.mean
          doc = oct - oct.mean
          den = Math.sqrt((dt**2).sum * (doc**2).sum)
          r = den > 0 ? (dt * doc).sum / den : 0.0
          span = Math.log2(@brightness_to / @brightness_from)
          @brightness_motion = span.abs >= 1 / 3.0 && r.abs >= 0.6 ? (span < 0 ? :falling : :rising) : :steady
          @brightness_from = @brightness_to = DSP.median(vals) if @brightness_motion == :steady
        end
      end
    end
  end
end
