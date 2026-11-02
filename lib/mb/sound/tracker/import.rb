module MB
  module Sound
    module Tracker
      # Turns a Song into a Tracker::Set (see Tracker): plays it through
      # once with a Player, then maps the recording onto mb-sound's
      # structure.
      #
      # - Samples become MB::Sound::Samples at their own rates (loops
      #   :forward or :ping_pong), all in one Sampler::Instrument whose
      #   keys pick them (key 1 is the first sample, keytrack 0, like a
      #   slice keymap), so a track plays any sample as a tracker channel
      #   does; the note goes on each note as a pitch mark (semitones from
      #   note 60, so `clip.transpose(12)` moves a channel's notes up).
      # - Every channel (and IT background voice) is a track, playing
      #   `clip.sampler(instrument, lanes: ...)` (Sampler::Instrument#play's
      #   lanes): one voice, following the clip's bend, volume, pan, and
      #   start lanes.
      # - Every played order entry (a Player::Visit) gives each track a clip
      #   of what it played there: notes (key = sample, velocity = volume,
      #   pitch mark = note, length to the next note) and lanes with a point
      #   wherever the tick-by-tick pitch, volume, or pan changes, in exact
      #   whole notes (a tick is 1/96 whole note; Tracker::TICKS_PER_WHOLE).
      #   Clips loop, counted from their launch, so a scene launched by
      #   hand plays its pattern over and over.
      # - Visits with the same clips are one scene (named after the
      #   pattern: :p05, then :p05_b for a visit that plays it differently),
      #   and the flow plays a section per visit, its length the visit's
      #   ticks; a song that loops gets a label where it loops back to
      #   (a `goto` with +loop: true+).
      class Import
        # The bend lanes' range (semitones each way; sent as RPN 0).
        BEND_RANGE = 96

        # The default stereo separation per mode and format: hard Amiga
        # pans (MOD, 669) are narrowed in :musical mode.
        SEPARATION = { mod: 0.6, "669": 0.6 }.freeze

        # Pan laws per format: the trackers' linear law (-6 dB in the
        # middle), FastTracker 2's square-root (equal power) one for XM.
        PAN_LAWS = { xm: :equal_power }.freeze

        # Gain per format (dB), matching the loudness of openmpt123's
        # renders of the maintainer's modules within about a dB (tracker-1
        # measurements; the reference player's mixing level).
        GAINS = { mod: 3.0, "669": 1.5, s3m: 1.5, xm: 1.0, it: 1.5 }.freeze

        attr_reader :song, :mode, :separation, :name, :limits

        # +song+ a Song (see Tracker.read); +mode+ :musical (band-limited
        # sample reads, exact equal-tempered periods, lanes smoothed over
        # LANE_SMOOTH) or :hardware (drop-sample reads without band
        # limiting, the format's integer periods, steps on the tick);
        # +separation+ scales the pans (0 mono, 1 as written); +limits+
        # :format or :none (see Player#initialize).
        def initialize(song, mode: :musical, separation: nil, name: nil, limits: :format)
          raise ArgumentError, "mode: is :musical or :hardware (got #{mode.inspect})" unless %i[musical hardware].include?(mode)
          @song = song
          @mode = mode
          @limits = limits
          @separation = (separation || (mode == :musical ? SEPARATION.fetch(song.format, 1.0) : 1.0)).to_f
          @name = name || song.title
          @result = nil
          @samples = nil
          @instrument = nil
          @offsets = nil
        end

        # How long a :musical lane step takes (seconds): a declick, not a
        # glide.
        LANE_SMOOTH = 0.0015

        # The Player's recording (see Player::Result).
        def result
          @result ||= Player.for(@song, mode: @mode, limits: @limits).run
        end

        # MB::Sound::Samples for Song#samples (nil for empty slots).
        def samples
          @samples ||= @song.samples.each_with_index.map { |s, i| Import.sample_of(s, i) }
        end

        # A Sample from SampleData +s+ (the +i+th), or nil if empty.
        def self.sample_of(s, i)
          return nil if s.nil? || s.empty?
          data = s.data.length == 1 ? s.data[0] : s.data
          # (an IT sustain loop with no loop of its own plays as the loop:
          # a Sample has one, and the release is the volume envelope's)
          points, mode = s.loop ? [s.loop, s.loop_mode] : [s.sustain_loop, s.sustain_mode]
          loop = points && points[1] > points[0] ? points[0]...points[1] : nil
          label = format('%02d %s', i + 1, s.name.to_s.strip).strip
          Sample.new(data, sample_rate: s.rate.to_f, root: 60, loop: loop, loop_mode: loop ? (mode || :forward) : nil, name: label)
        end

        # The key that plays sample index +i+ (0-based).
        def self.key_of(i)
          i + 1
        end

        # The Sampler::Instrument of every sample the song plays.
        def instrument
          @instrument ||= begin
            used = result.logs.flat_map { |l| l.triggers.map(&:sample) }.uniq.sort
            used.select! { |i| samples[i] }
            used = [samples.index { |s| s }].compact if used.empty?
            raise FormatError, "#{@name}: no samples to play" if used.empty?
            raise FormatError, "#{@name}: plays #{used.length} samples (an instrument holds 127)" if used.length > 127
            list = samples
            Sampler::Instrument.new(name: @name) { |inst|
              gain = 10**(GAINS.fetch(@song.format, 0.0) / 20)
              used.each { |i| inst.region(list[i], keys: Import.key_of(i), keytrack: 0, gain: gain) }
            }
          end
        end

        # The sampler options the tracks play with (see
        # Sampler::Instrument#play).
        def voice_options
          law = PAN_LAWS.fetch(@song.format, :linear)
          if @mode == :hardware
            { lanes: { law: law }, interpolation: :none, mips: false }
          else
            { lanes: { smooth: LANE_SMOOTH, law: law } }
          end
        end

        # The Tracker::Set.
        def set
          r = result
          inst = instrument
          logs = r.logs.select(&:used?) # (channels that never play get no track)
          tracks = logs.map(&:name)
          cache = {}
          scenes = {}
          names = {}
          plays = []
          marks = Array.new(logs.length) # (each log's [mark, sample] before the visit)
          r.visits.each_with_index do |v, vi|
            row = logs.each_with_index.map { |log, c|
              clip, marks[c] = clip_for(v, log, marks[c])
              cache[[c, clip_key(clip)]] ||= clip
            }
            key = row.map(&:object_id)
            name = names[key]
            unless name
              base = :"p#{format('%02d', v.pattern || 0)}"
              taken = scenes.keys.count { |n| n == base || n.to_s.start_with?("#{base}_") }
              name = taken == 0 ? base : :"#{base}_#{(97 + taken).chr}"
              names[key] = name
              scenes[name] = { visit: vi, clips: tracks.zip(row).to_h, tempo: tempo_at(v.start), changes: tempo_changes(v) }
            end
            plays << [name, Rational(v.ticks, TICKS_PER_WHOLE)]
          end
          restart = r.restart && r.restart[0]
          Set.new(import: self, tracks: tracks, scenes: scenes, plays: plays, restart: restart, bpm: r.tempos[0][1], voice: voice_options,
                  instrument: inst, unsupported: r.unsupported)
        end

        private

        # True if any note starts past its sample's start (every clip then
        # has a start lane, so no clip keeps another's offset).
        def offsets?
          @offsets = result.logs.any? { |l| l.triggers.any? { |t| t.offset > 0 } } if @offsets.nil?
          @offsets
        end

        def clip_key(clip)
          [clip.events.map(&:to_a), clip.controls.map { |l| [l.type, l.number, l.points] }, clip.length]
        end

        # The BPM in effect at +tick+.
        def tempo_at(tick)
          result.tempos.reverse_each.find { |t, _| t <= tick }&.last || result.tempos[0][1]
        end

        # Tempo changes inside visit +v+: [[whole notes from its start, bpm]].
        def tempo_changes(v)
          result.tempos.select { |t, _| t > v.start && t < v.stop }.map { |t, bpm| [Rational(t - v.start, TICKS_PER_WHOLE), bpm] }
        end

        # [the clip channel +log+ plays in visit +v+, [mark, sample] after
        # it]; +state+ is [mark, sample] before the visit (nil at first).
        def clip_for(v, log, state)
          start = v.start
          stop = v.stop
          mark, sample = state || [0, nil]
          trigs = log.triggers.select { |t| t.tick >= start && t.tick < stop }
          events = trigs.each_with_index.map { |t, k|
            stop_tick = k + 1 < trigs.length ? trigs[k + 1].tick : stop
            m = t.note ? t.note - 60 : mark
            vel = log.volume[t.tick].to_f.clamp(1 / 127.0, 1.0)
            Sequence::Event.new(start: Rational(t.tick - start, TICKS_PER_WHOLE), length: Rational(stop_tick - t.tick, TICKS_PER_WHOLE),
                                value: Import.key_of(t.sample), velocity: vel, pitch: m)
          }

          bend = []
          vol = []
          pan = []
          offsets = []
          by_tick = trigs.group_by(&:tick)
          last = [nil, nil, nil]
          (start...stop).each do |t|
            pos = Rational(t - start, TICKS_PER_WHOLE)
            if (here = by_tick[t])
              tr = here.last
              mark = tr.note ? tr.note - 60 : mark
              sample = tr.sample
              s = samples[sample]
              offsets << [pos, s && s.length > 0 ? (tr.offset.to_f / s.length).clamp(0.0, 1.0) : 0.0]
            end
            f = log.freq[t]
            if f && sample && (s = @song.samples[sample])
              b = ((12 * Math.log2(f / s.rate.to_f) - mark) / BEND_RANGE).clamp(-1.0, 1.0)
              if b != last[0]
                bend << [pos, b]
                last[0] = b
              end
            elsif t == start
              bend << [pos, 0.0]
              last[0] = 0.0
            end
            vv = log.volume[t].to_f.clamp(0.0, 1.0)
            if vv != last[1]
              vol << [pos, vv]
              last[1] = vv
            end
            pp = ((log.pan[t].to_f * @separation).clamp(-1.0, 1.0) + 1) / 2
            if pp != last[2]
              pan << [pos, pp]
              last[2] = pp
            end
          end
          lanes = [
            Sequence::ControlLane.new(:bend, nil, bend, range: BEND_RANGE),
            Sequence::ControlLane.new(:cc, Sampler::Instrument::LANES[:volume], vol),
            Sequence::ControlLane.new(:cc, Sampler::Instrument::LANES[:pan], pan),
          ]
          if offsets?
            offsets.unshift([0r, 0.0]) if offsets.empty? || offsets[0][0] > 0
            lanes << Sequence::ControlLane.new(:cc, Sampler::Instrument::LANES[:start], offsets)
          end
          clip = Sequence::Clip.new(events, length: Rational(stop - start, TICKS_PER_WHOLE), loop: true, align: :launch, controls: lanes)
          [clip, [mark, sample]]
        end
      end
    end
  end
end
