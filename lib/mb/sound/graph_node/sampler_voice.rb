module MB
  module Sound
    module GraphNode
      # One channel of a sampler voice (see Sampler::Instrument#play and
      # design/notes/sampler.md): at every note-on (a sample of +trigger+
      # above 0, valued at the velocity) it picks the instrument's region for
      # the note +number+ and velocity and plays it from that exact sample,
      # pitched by key (root, keytrack, tune, +transpose+) and by +freq+ (a
      # node of Hz relative to the note's own frequency: bends and glides),
      # looping as the sample's loop mode says (+gate+ ends release loops),
      # with the sample's fades, reverse, and start offset (+start+: a 0..1
      # fraction read at each note-on), and +shift+ semitones higher (the
      # note's pitch mark, read at each note-on: chop hits).  The
      # instrument's split key, if any, plays the last region chromatically
      # above it.  A re-struck note fades out over
      # +declick+ samples under the new one.
      #
      # +choke+ (Notes#choke, for instruments with choke groups: SF2
      # exclusive classes, SFZ group/off_by; see Instrument#region) stops the
      # sounding note Envelope::CHOKE_TIME after a nonzero sample without a
      # note-on, fading it out linearly over that time when +choke_fade+ is
      # true (like Drums::ChokeGate; for instruments without an envelope,
      # whose envelope would fade it otherwise), so a choked voice falls
      # idle on the exact sample.  +choke_time+ (seconds) changes that time
      # (Instrument#play's +steal_fade+ length).
      #
      # Playback reads the samples' band-limited levels (sample-mode
      # Wavetable levels, +mips+ apart, +interpolation+ :optimal), so
      # pitching up doesn't alias; `interpolation: :none, mips: false` is
      # the old drop-sample sound.  Left nil, each sample reads as it says
      # (Sample#read_as: the lofi presets read drop-sample with no levels),
      # else :optimal at the instrument's #mips.  The kernel is MB::Sound::FastSampler.play
      # (exact Ruby mirror Sampler::KernelRuby.play); output is the same at
      # any buffer size.  Never ends (like other voices), except with +once+
      # (Sample#node): one note at the first sample, ending when it does.
      #
      # A plan boundary for now.
      class SamplerVoice
        include GraphNode
        include SampleRateHelper

        # The instrument played.
        attr_reader :instrument

        # The channel of the instrument's samples played.
        attr_reader :channel

        # The random seed for round robins.
        attr_reader :seed

        def initialize(instrument, channel: 0, trigger: nil, number: nil, freq: nil, gate: nil, shift: nil, start: nil, transpose: 0, declick: Sampler::DECLICK,
                       interpolation: nil, mips: nil, seed: nil, once: false, choke: nil, choke_fade: true, choke_time: nil, sample_rate: 48000)
          raise ArgumentError, "A sampler voice plays a Sampler::Instrument (got #{instrument.inspect})" unless instrument.is_a?(Sampler::Instrument)
          @instrument = instrument
          @channel = Integer(channel)
          @once = !!once
          if @once
            first = instrument.regions.first
            trigger = 1.0
            number = first.keytrack == 0 ? first.keys[0] : (first.root || first.sample.root)
          end
          raise ArgumentError, 'A sampler voice needs a trigger and a note number' if trigger.nil? || number.nil?

          @trigger = input(trigger)
          @number = input(number)
          @freq = freq.nil? ? nil : input(freq)
          @gate = gate.nil? ? nil : input(gate)
          @start = start.nil? ? 0.0 : input(start)
          @shift = shift.nil? ? 0.0 : input(shift)
          @choke = choke.nil? ? nil : input(choke)
          @choke_fade = !!choke_fade
          @choke_time = choke_time.nil? ? MB::Sound::Envelope::CHOKE_TIME : Float(choke_time)
          raise ArgumentError, "The choke time is seconds above 0 (got #{choke_time.inspect})" unless @choke_time > 0
          @transpose = Interval.semitones(transpose).to_f
          @declick = Integer(declick)
          raise ArgumentError, "Declick is a number of samples, 0 or more (got #{declick})" if @declick < 0
          @interpolation = interpolation&.to_sym
          @mips = mips
          @seed = seed.nil? ? MB::Sound.next_seed : Integer(seed)
          @sample_rate = sample_rate.to_f
          @node_type_name = 'SamplerVoice'
          @buf = nil
          build_tables
          reset
        end

        # Silences the voice and restarts its round robins.
        def reset
          @state = Numo::DFloat.zeros(Sampler::KernelRuby::STATE_LENGTH)
          @state[Sampler::KernelRuby::LAST_REGION] = -1
          @counters = Numo::DFloat.zeros(128)
          @rng = Numo::UInt64[@seed & Tone::MASK64]
          @started = false
          self
        end

        def sample_rate=(rate)
          return if rate.to_f == @sample_rate
          @sample_rate = rate.to_f
          build_tables
        end

        # True when no note is sounding (Notes#register uses this, so a
        # synth keeps one-shot voices until their samples end).
        def idle?
          @state[0] == 0 && @state[Sampler::KernelRuby::VOICE] == 0
        end

        # The kernel's inputs for +count+ samples, or nil when an input ended.
        def sample(count)
          if @once
            return nil if @started && idle?
            trig = @started ? 0.0 : first_trigger(count)
            @started = true
            num = @number
          else
            trig = read(@trigger, count) or return nil
            count = trig.length if trig.is_a?(Numo::NArray)
            num = read(@number, count) or return nil
          end
          freq = @freq && (read(@freq, count) or return nil)
          gate = @gate && (read(@gate, count) or return nil)
          start = read(@start, count) or return nil
          shift = read(@shift, count) or return nil
          choke = @choke && (read(@choke, count) or return nil)

          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          MB::Sound::FastSampler.play(@buf, @specs, @regions, @state, @counters, @rng, [trig, num, freq, gate, start, shift, choke], config)
        end

        # The same samples through the Ruby mirror (for specs).
        def sample_ruby(count)
          trig = read(@trigger, count) or return nil
          num = read(@number, count) or return nil
          freq = @freq && (read(@freq, count) or return nil)
          gate = @gate && (read(@gate, count) or return nil)
          start = read(@start, count) or return nil
          shift = read(@shift, count) or return nil
          choke = @choke && (read(@choke, count) or return nil)
          out = Numo::SFloat.zeros(count)
          Sampler::KernelRuby.play(out, @specs, @regions, @state, @counters, @rng, [trig, num, freq, gate, start, shift, choke], config)
        end

        def sources
          s = { trigger: @trigger, number: @number }
          s[:freq] = @freq if @freq
          s[:gate] = @gate if @gate
          s[:start] = @start unless @start.is_a?(Numeric)
          s[:shift] = @shift unless @shift.is_a?(Numeric)
          s[:choke] = @choke if @choke
          s.reject { |_, v| v.is_a?(Numeric) }
        end

        def plan_unsupported_reason
          'sampler voices are a plan boundary for now'
        end

        def to_s
          "SamplerVoice #{@instrument}#{" ch#{@channel}" if @instrument.channel_count > 1}"
        end

        private

        # The kernel's config, made again only when the tuning's A4 changes.
        def config
          a4 = MB::Sound.tuning.frequency_of(69).to_f
          return @config if @config && @config[0] == a4

          # (every region carries its own interpolation code; the sinc kernel
          # goes along whenever a region reads with it)
          interp = @interpolation || :optimal
          code = MB::Sound::Wavetable::INTERPOLATIONS.fetch(interp) { raise ArgumentError, "Unknown interpolation #{interp.inspect}" }
          sinc = interp == :sinc || @sinc ? MB::Sound::Wavetable::SINC_KERNEL : nil
          choke = MB::M.max(1, (@choke_time * @sample_rate).round)
          @config = [a4, @declick, @instrument.split || -1, code, sinc, @transpose, choke, @choke_fade ? 1 : 0].freeze
        end

        def build_tables
          @specs, @regions = @instrument.kernel_tables(@channel, @sample_rate, mips: @mips, interpolation: @interpolation)
          sinc = MB::Sound::Wavetable::INTERPOLATIONS[:sinc]
          @sinc = @regions[true, Sampler::KernelRuby::INTERP].to_a.include?(sinc.to_f)
          @config = nil
        end

        def input(x)
          case x
          when Numeric then x.to_f
          when MB::Sound::Pitch then x.oscillator_frequency.then { |f| f.is_a?(Numeric) ? f.to_f : f.get_sampler }
          else
            raise ArgumentError, "Sampler inputs are numbers or nodes (got #{x.inspect})" unless x.respond_to?(:sample)
            x.get_sampler
          end
        end

        def read(x, count)
          return x if x.is_a?(Numeric)
          b = x.sample(count)
          return nil if b.nil? || b.empty?
          raise ArgumentError, 'Sampler inputs must give the buffer size asked for' if b.length != count
          b
        end

        def first_trigger(count)
          t = Numo::SFloat.zeros(count)
          t[0] = 1.0
          t
        end
      end
    end
  end
end
