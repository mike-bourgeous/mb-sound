module MB
  module Sound
    module MIDI
      # Turns MIDI files into clips and drum kits (midi-import-1,
      # 2026-10-28; console MidiMethods#midi_clip, #midi_kit, #midi_tracks;
      # design/notes/midi.md, Clips from MIDI files).
      #
      # Score time: positions come straight from ticks (tick / (4 * ppqn)
      # whole notes, exact Rationals), so a file's tempo events don't
      # matter (exported phrases often have none) and the clip plays at the
      # session tempo; +timing: :performed+ places events at the seconds
      # the file's tempo map gives them instead, converted to whole notes
      # at the session tempo (rubato kept, bars no longer lined up).
      #
      # Bars come from the file's time signatures (4/4 without one), each
      # meter change starting a new bar.  +from:+ is a bar offset (0 is the
      # file's first bar), +bars:+ the clip's length in bars; without
      # +bars:+, the clip ends on the first bar line at or after the last
      # note's end (a 32nd note of grace, so a legato tail past the bar
      # line doesn't add a bar).  Notes start in the window; notes still
      # sounding at its end are cut there.
      #
      # Notes: each note-on to its note-off (or the same key struck again);
      # with +sustain: true+ (the default, like MIDI::Capture) a held
      # sustain pedal (CC 64) holds notes until it lifts, and the pedal
      # isn't kept as a lane.  Velocities as played (Clip#performed?).
      #
      # Slides (the legato rule, +slides: :auto+), decided per pair of
      # notes in start order: a note and the next are a legato pair when
      # the next starts at least LEGATO_GAP later (not a chord), before
      # the first ends, overlapping it by less than LEGATO_MAX_OVERLAP and
      # less than half of the first note (not a sustained arpeggio, whose
      # notes ring a step or more into the next), with no third note
      # sounding during the overlap (not voice leading in chords).  The
      # first note of a legato pair is marked slid (`~`, Seq::Step#slide),
      # its length as played, so mono voices glide and legato envelopes
      # hold; chords and other overlaps stay unmarked notes.  +slides:
      # true+ marks every overlap, +false+ none.
      #
      # Controllers (+cc:+): CCs (except bank select 0/32, the RPN/NRPN
      # messages 6/38/96-101, and channel mode messages 120-127), pitch
      # bend (with the bend range the file set with RPN 0, kept on the
      # lane: ControlLane#range), channel and poly pressure in the
      # selection become Sequence::ControlLanes at exact positions (:steps,
      # the default), fitted curves (:fit, Clip#fit_controls), only some
      # (an Array of CC numbers and :bend/:pressure/:poly_pressure), or
      # none (false).  A lane's value at the window's start is chased: it
      # gets a point at 0 if the file set the controller earlier.
      class Import
        # One track of a file (see #tracks): its index, name (NUL bytes and
        # surrounding spaces removed; midilib reads "Unnamed" for none),
        # channels (0-based), note count, lowest and highest note, the
        # controller lanes it has with their event counts ({ cc1: 3296,
        # bend: 65 }), whether it looks like drums, and how many notes it
        # sounds at once at most.
        Track = Data.define(:index, :name, :channels, :notes, :low, :high, :controls, :drums, :polyphony, :slides) do
          def drums? = drums

          def to_s
            range = notes > 0 ? " #{MB::Sound::Note.new(low)}..#{MB::Sound::Note.new(high)}" : ''
            ch = channels.empty? ? 'no channel' : "ch #{channels.map { |c| c + 1 }.join(',')}"
            ctl = controls.empty? ? '' : " #{controls.map { |k, n| "#{k} x#{n}" }.join(' ')}"
            kind = drums ? ' drums' : (notes > 0 ? (polyphony > 1 ? " poly #{polyphony}" : ' mono') : '')
            kind += " #{slides} slide#{'s' unless slides == 1}" if slides > 0
            "#{index} #{name.inspect} #{ch}, #{notes} notes#{range}#{kind}#{ctl}"
          end

          def inspect = "#<MIDI track #{self}>"
        end

        # The tracks of a file, listed one per line by #inspect (what the
        # console prints for `midi_tracks(path)`).
        class TrackList
          include Enumerable

          attr_reader :path

          def initialize(path, tracks, meters, tempo)
            @path = path
            @tracks = tracks.freeze
            @meters = meters
            @tempo = tempo
            freeze
          end

          def each(&block) = @tracks.each(&block)
          def [](i) = @tracks[i]
          def length = @tracks.length
          alias size length
          def to_a = @tracks.dup

          def to_s
            meters = @meters.map { |_t, n, d| "#{n}/#{d}" }.uniq.join(', ')
            head = "#{File.basename(@path.to_s)}: #{@tempo}, #{meters}"
            ([head] + @tracks.map { |t| "  #{t}" }).join("\n")
          end
          alias inspect to_s
        end

        # How far apart (whole notes) two overlapping notes must start for
        # the overlap to count as legato rather than a chord: a 32nd note.
        LEGATO_GAP = 1/32r

        # The longest overlap (whole notes) of a legato pair: an eighth
        # note (a mono synth's legato overlaps a few ms to an eighth;
        # sustained arpeggios ring longer than half their note, the other
        # limit).
        LEGATO_MAX_OVERLAP = 1/8r

        # How long (whole notes) a drum hit of #kit lasts at most: drum
        # tracks' note lengths mean nothing to drum machines (they often
        # overlap the next hit), so hits are this long, or up to the next
        # hit of the same drum.
        DRUM_HIT = 1/32r

        # How far (whole notes) a note may end past a bar line without
        # adding a bar to the clip (see the class description).
        END_GRACE = 1/32r

        # Controllers never kept as lanes: bank select, data entry and
        # (N)RPN selection (RPN 0, the bend range, goes on the bend lane),
        # and channel mode messages.
        SKIPPED_CC = [0, 32, 6, 38, *96..101, *120..127].freeze

        # Track names that mark drum tracks besides channel 10.
        DRUM_NAMES = /kick|snare|hat|drum|perc|tom|cymbal|crash|ride|clap|rim|shaker|conga|bongo|cowbell/i

        # The MIDIFile read.
        attr_reader :midi_file

        # Pulses (ticks) per quarter note.
        attr_reader :ppqn

        # [[tick, numerator, denominator], ...] from tick 0.
        attr_reader :meters

        # Reads +file+ (a path or a MIDIFile).
        def initialize(file)
          @midi_file = file.is_a?(MIDIFile) ? file : MIDIFile.new(file)
          seq = @midi_file.seq
          @ppqn = seq.ppqn
          @path = @midi_file.filename
          ts = seq.tracks.flat_map { |t| t.events.select { |e| e.is_a?(::MIDI::TimeSig) } }
            .sort_by(&:time_from_start).map { |e| [e.time_from_start, e.data[0], 2**e.data[1]] }
          by_tick = {}
          ts.each { |t, n, d| by_tick[t] = [t, n, d] }
          by_tick[0] ||= [0, 4, 4]
          @meters = by_tick.values.sort.map(&:freeze).freeze
          @channel_events = seq.tracks.map { |t|
            t.events.each_with_index.select { |e, _| e.is_a?(::MIDI::ChannelEvent) }
              .sort_by { |e, i| [e.time_from_start, i] }
              .flat_map { |e, _| Event.parse_all(e.data_as_bytes).map { |ev| [e.time_from_start, ev].freeze } }
              .freeze
          }.freeze
          @last_tick = seq.tracks.filter_map { |t| t.events.last&.time_from_start }.max || 0
        end

        # The file's MIDI::TempoMap.
        def tempo_map
          @midi_file.tempo_map
        end

        # Whole notes per tick.
        def whole_notes_per_tick
          Rational(1, 4 * @ppqn)
        end

        # A TrackList describing every track (see Track).
        def tracks
          @tracks ||= begin
            seq = @midi_file.seq
            list = seq.tracks.each_with_index.map { |t, i|
              evs = @channel_events[i]
              notes = pair_notes(evs, sustain: false)
              lanes = evs.filter_map { |_, e| lane_key(e, sustain: false) }.tally.transform_keys { |type, n| n ? :"#{type == :poly_pressure ? 'poly' : type}#{n}" : type }
              name = Import.clean_name(t.name)
              chans = evs.map { |_, e| e.channel }.uniq.sort
              nums = notes.map { |n| n[2] }
              Track.new(
                index: i, name: name, channels: chans, notes: notes.length, low: nums.min, high: nums.max,
                controls: lanes, drums: !notes.empty? && (chans == [9] || name.match?(DRUM_NAMES)), polyphony: Import.polyphony(notes),
                slides: notes.length > 1 ? legato_pairs(notes).count(true) : 0
              )
            }
            first = MB::M.sigfigs(tempo_map.bpm_at(0), 5)
            first = first.to_i if first == first.round
            bpm = tempo_map.changes? ? "#{tempo_map.tempos.length} tempos from #{first} BPM" : "#{first} BPM"
            TrackList.new(@path, list, @meters, bpm)
          end
        end

        # A track name without NUL bytes or surrounding spaces.
        def self.clean_name(name)
          name.to_s.delete("\x00").strip
        end

        # The index of the track +sel+ names: an index, or a name (case and
        # surrounding spaces ignored; a unique part of a name works too).
        # nil picks the only track with notes.  Raises ArgumentError with
        # the tracks (and a did-you-mean) otherwise.
        def track_index(sel)
          list = tracks
          case sel
          when nil
            with_notes = list.select { |t| t.notes > 0 }
            return with_notes[0].index if with_notes.length == 1
            # (a controller-only file: its only track with channel events)
            with_events = list.reject { |t| t.channels.empty? }
            return with_events[0].index if with_notes.empty? && with_events.length == 1
            raise ArgumentError, "#{File.basename(@path.to_s)} has #{with_notes.length} tracks with notes: pick one with track: (#{track_choices(with_notes)})"
          when Integer
            return sel if sel >= 0 && sel < list.length
            raise ArgumentError, "No track #{sel} in #{File.basename(@path.to_s)} (tracks 0..#{list.length - 1}: #{track_choices(list)})"
          when String, Symbol
            want = sel.to_s.strip.downcase
            exact = list.select { |t| t.name.downcase == want }
            exact = list.select { |t| t.name.downcase.include?(want) } if exact.empty? && !want.empty?
            return exact[0].index if exact.length == 1
            if exact.length > 1
              raise ArgumentError, "#{exact.length} tracks of #{File.basename(@path.to_s)} match #{sel.to_s.inspect}: pick one by index (#{track_choices(exact)})"
            end
            hint = DidYouMean::SpellChecker.new(dictionary: list.map(&:name).uniq).correct(sel.to_s).first
            raise ArgumentError, "No track named #{sel.to_s.inspect} in #{File.basename(@path.to_s)}#{" (did you mean #{hint.inspect}?)" if hint} (tracks: #{track_choices(list)})"
          else
            raise ArgumentError, "track: is a track name or index (got #{sel.inspect})"
          end
        end

        # The tick of each bar line from 0 up to the first one at or after
        # +tick+ (see the class description).
        def bar_lines(tick)
          lines = [0]
          m = 0
          loop do
            t = lines[-1]
            m += 1 while m + 1 < @meters.length && @meters[m + 1][0] <= t
            _, n, d = @meters[m]
            len = 4 * @ppqn * n / d
            nxt = t + len
            # A meter change inside a bar starts a new bar there
            nxt = @meters[m + 1][0] if m + 1 < @meters.length && @meters[m + 1][0] < nxt
            break if t >= tick
            lines << nxt
          end
          lines
        end

        # A Sequence::Clip of a track (see the class description and
        # MidiMethods#midi_clip).
        def clip(track: nil, channel: nil, bars: nil, from: 0, loop: true, slides: :auto, cc: :steps, timing: :score, sustain: true, transport: nil)
          check_options(channel, bars, from, slides, cc, timing)
          idx = track_index(track)
          evs = select_channel(@channel_events[idx], channel, idx)
          notes = pair_notes(evs, sustain: sustain)
          start, stop = window(notes, evs, from, bars)
          notes = cut(notes, start, stop)
          slid = slide_marks(notes, slides)

          pos = position_map(start, timing, transport)
          events = notes.each_with_index.map { |(on, off, note, vel), i|
            a = pos.call(on)
            Sequence::Event.new(start: a, length: pos.call(off) - a, value: note, velocity: vel, slid: slid[i] || nil)
          }
          length = timing == :performed ? performed_length(pos.call(stop), transport) : (stop - start) * whole_notes_per_tick
          lanes = cc ? lanes(evs, start, stop, pos, cc, sustain: sustain) : []
          clip = Sequence::Clip.new(events, length: length, loop: loop, performed: true, controls: lanes)
          cc == :fit ? clip.fit_controls : clip
        end

        # A Sequence::Kit of the drum tracks (channel 10, or names like
        # kick/snare/hat; +track:+ a name, index, or an Array of them),
        # one row per drum named by its GM name (Sequence::Grid::GM_DRUMS,
        # else the TR-808 voice it plays), each row a clip of that drum's
        # hits over the same window (see #clip for +bars:+, +from:+,
        # +loop:+, +timing:+).  Notes no drum name covers are left out
        # with a warning.
        def kit(track: nil, bars: nil, from: 0, loop: true, timing: :score, transport: nil)
          check_options(nil, bars, from, :auto, false, timing)
          indexes = drum_tracks(track)
          evs = indexes.flat_map { |i| @channel_events[i] }.sort_by.with_index { |(t, _), j| [t, j] }
          notes = pair_notes(evs, sustain: false)
          start, stop = window(notes, evs, from, bars)
          notes = cut(notes, start, stop)
          pos = position_map(start, timing, transport)
          length = timing == :performed ? performed_length(pos.call(stop), transport) : (stop - start) * whole_notes_per_tick

          rows = {}
          unknown = []
          hit = (DRUM_HIT / whole_notes_per_tick).floor
          next_on = {}
          notes.reverse_each.map { |on, _off, note, vel|
            fin = [on + hit, next_on[note]].compact.min
            next_on[note] = on
            [on, fin, note, vel]
          }.reverse_each do |on, off, note, vel|
            name = Import.drum_name(note)
            next unknown << note unless name
            a = pos.call(on)
            (rows[name] ||= []) << Sequence::Event.new(start: a, length: pos.call(MB::M.min(off, stop)) - a, value: note, velocity: vel)
          end
          warn "midi_kit: left out notes #{unknown.uniq.sort.join(', ')} of #{File.basename(@path.to_s)} (no drum name)" unless unknown.empty?
          raise ArgumentError, "No drum notes in #{File.basename(@path.to_s)} (tracks: #{track_choices(indexes.map { |i| tracks[i] })})" if rows.empty?

          Sequence::Kit.new(rows.to_h { |name, list| [name, Sequence::Clip.new(list, length: length, loop: loop, performed: true)] })
        end

        # The row name for drum note +note+: the first GM_DRUMS name, else
        # the TR-808 voice of the note, else nil.
        def self.drum_name(note)
          @gm_names ||= Sequence::Grid::GM_DRUMS.each_with_object({}) { |(k, n), h| h[n] ||= k }.freeze
          @gm_names[note] || MB::Sound::Drums::TR808::GM_NOTES[note]
        end

        # The most notes sounding at once among +notes+ ([on, off, ...]).
        def self.polyphony(notes)
          edges = notes.flat_map { |on, off| [[on, 1], [off, -1]] }.sort_by { |t, d| [t, d] }
          n = 0
          edges.map { |_, d| n += d }.max || 0
        end

        private

        def check_options(channel, bars, from, slides, cc, timing)
          raise ArgumentError, "channel: is a 0-based MIDI channel 0..15 (got #{channel.inspect})" unless channel.nil? || (channel.is_a?(Integer) && channel.between?(0, 15))
          raise ArgumentError, "bars: is a positive whole number of bars (got #{bars.inspect})" unless bars.nil? || (bars.is_a?(Integer) && bars > 0)
          raise ArgumentError, "from: is a bar offset from 0 (got #{from.inspect})" unless from.is_a?(Integer) && from >= 0
          raise ArgumentError, "slides: is :auto, true, or false (got #{slides.inspect})" unless [:auto, true, false].include?(slides)
          unless [:steps, :fit, false, nil].include?(cc) || (cc.is_a?(Array) && cc.all? { |c| (c.is_a?(Integer) && c.between?(0, 127)) || %i[bend pressure poly_pressure].include?(c) })
            raise ArgumentError, "cc: is :steps, :fit, false, or an Array of CC numbers and :bend/:pressure/:poly_pressure (got #{cc.inspect})"
          end
          unless %i[score performed].include?(timing)
            hint = DidYouMean::SpellChecker.new(dictionary: %w[score performed]).correct(timing.to_s).first
            raise ArgumentError, "timing: is :score or :performed (got #{timing.inspect}#{"; did you mean :#{hint}?" if hint})"
          end
        end

        def track_choices(list)
          list.map { |t| "#{t.index} #{t.name.inspect}" }.join(', ')
        end

        def drum_tracks(sel)
          if sel.nil?
            found = tracks.select(&:drums?).map(&:index)
            raise ArgumentError, "No drum tracks in #{File.basename(@path.to_s)} (channel 10 or names like kick/snare/hat); pick tracks with track: (#{track_choices(tracks.select { |t| t.notes > 0 })})" if found.empty?
            found
          else
            Array(sel).map { |s| track_index(s) }.uniq
          end
        end

        # +evs+ of channel +channel+, or all of them (notes from every
        # channel, controllers from the channel with the most events).
        def select_channel(evs, channel, idx)
          return evs.select { |_, e| e.channel == channel } if channel
          with_notes = evs.filter_map { |_, e| e.channel if e.note_on? }.uniq.sort
          if with_notes.length > 1
            raise ArgumentError, "Track #{idx} #{tracks[idx].name.inspect} of #{File.basename(@path.to_s)} has notes on channels #{with_notes.join(', ')} (0-based): pick one with channel:"
          end
          chans = evs.map { |_, e| e.channel }.tally
          return evs if chans.length <= 1
          main = chans.max_by { |c, n| [n, -c] }[0]
          evs.select { |_, e| e.note? || e.channel == main }
        end

        # [[on tick, off tick, note, velocity], ...] by start (see the
        # class description).
        def pair_notes(evs, sustain:)
          held = {}
          orphans = Hash.new(0) # (note-offs of notes a re-strike ended)
          pedaled = Hash.new { |h, k| h[k] = [] }
          pedal = Hash.new(false)
          out = []
          finish = ->(key, tick) {
            on = held.delete(key) or next
            pedaled[key[0]].delete(key)
            out << [on[0], tick, key[1], on[1]]
          }
          evs.each do |tick, e|
            key = [e.channel, e.note]
            case e.type
            when :note_on
              if held.key?(key)
                # The same key again before its note-off: the earlier note
                # ends here, and its note-off (the next one) is ignored
                orphans[key] += 1 unless pedaled[key[0]].include?(key) # (a pedaled note's note-off came already)
                finish.call(key, tick)
              end
              held[key] = [tick, e.velocity]
            when :note_off
              if orphans[key] > 0
                orphans[key] -= 1
                next
              end
              next unless held.key?(key)
              if sustain && pedal[e.channel]
                pedaled[e.channel] << key unless pedaled[e.channel].include?(key)
              else
                finish.call(key, tick)
              end
            when :cc
              next unless sustain && e.note == 64
              down = e.value >= 0.5
              pedaled[e.channel].dup.each { |k| finish.call(k, tick) } if pedal[e.channel] && !down
              pedal[e.channel] = down
            end
          end
          last = [@last_tick, *evs.map(&:first)].max
          held.keys.each { |k| finish.call(k, last) }
          out.sort_by { |on, _off, n, _v| [on, n] }
        end

        # [start tick, stop tick] of the clip window.
        def window(notes, evs, from, bars)
          base = bar_lines(@last_tick + 4 * @ppqn * 4 * (from + (bars || 0) + 1))
          start = base[from]
          if bars.nil? && start >= @last_tick
            raise ArgumentError, "from: #{from} is past the end of #{File.basename(@path.to_s)} (#{bar_lines(@last_tick).length - 1} bars)"
          end
          return [start, base[from + bars]] if bars

          inside = notes.select { |on, *| on >= start }
          last = inside.map { |_, off| off }.max
          ctl = evs.select { |t, e| t >= start && lane_key(e, sustain: true) }.map(&:first).max
          last = [last, ctl && ctl + 1].compact.max
          raise ArgumentError, "Nothing plays in #{File.basename(@path.to_s)} from bar #{from} (no notes or controller lanes there)" if last.nil?
          grace = (END_GRACE / whole_notes_per_tick).floor
          stop = base.find { |b| b > start && b >= last - grace } || base[-1]
          [start, stop]
        end

        # Notes starting in [start, stop), cut at +stop+.
        def cut(notes, start, stop)
          notes.filter_map { |on, off, n, v| [on, MB::M.min(off, stop), n, v] if on >= start && on < stop }
        end

        # Per note, true when it is slid (see the class description).
        def slide_marks(notes, mode)
          return [] if mode == false || notes.length < 2
          if mode == true
            return notes.each_with_index.map { |(on, off), i|
              nxt = notes[i + 1]
              nxt && nxt[0] < off && nxt[0] > on
            }
          end
          legato_pairs(notes)
        end

        # Per note of +notes+ (sorted by start), true if it and the next
        # note are a legato pair (see the class description): the next
        # starts LEGATO_GAP or more later, before this one ends, overlapping
        # it by less than LEGATO_MAX_OVERLAP and less than half of this
        # note, with no other note sounding during the overlap.
        def legato_pairs(notes)
          gap = (LEGATO_GAP / whole_notes_per_tick).ceil
          most = LEGATO_MAX_OVERLAP / whole_notes_per_tick
          # The number of notes sounding, as [[tick, count from there], ...]
          counts = []
          n = 0
          notes.flat_map { |on, off| [[on, 1], [off, -1]] }.sort_by { |t, d| [t, d] }.each do |t, d|
            n += d
            counts.pop if counts[-1]&.first == t
            counts << [t, n]
          end
          ticks = counts.map(&:first)
          notes.each_with_index.map { |(on, off), i|
            nxt = notes[i + 1] or next false
            on2 = nxt[0]
            overlap = off - on2
            next false unless overlap > 0 && on2 - on >= gap && overlap < most && overlap * 2 < off - on
            # At most these two notes during the overlap [on2, off)
            k = (ticks.bsearch_index { |t| t > on2 } || ticks.length) - 1
            ok = true
            while k < counts.length && counts[k][0] < off
              (ok = false; break) if counts[k][1] > 2
              k += 1
            end
            ok
          }
        end

        # A lambda from ticks to clip positions (whole notes).
        def position_map(start, timing, transport)
          wnpt = whole_notes_per_tick
          return ->(t) { (t - start) * wnpt } if timing == :score

          wnps = (transport || Sequence.current_transport).whole_notes_per_second
          map = tempo_map
          t0 = map.seconds(start)
          ->(t) { (map.seconds(t) - t0) * wnps }
        end

        # A performed clip's length: whole bars of the session meter.
        def performed_length(end_pos, transport)
          bar = (transport || Sequence.current_transport).bar_length
          n = (end_pos / bar).ceil
          (n < 1 ? 1 : n) * bar
        end

        # The lane key [type, number] of controller event +e+, or nil.
        def lane_key(e, sustain:)
          case e.type
          when :cc
            return nil if SKIPPED_CC.include?(e.note) || (sustain && e.note == 64)
            [:cc, e.note]
          when :bend then [:bend, nil]
          when :channel_pressure then [:pressure, nil]
          when :poly_pressure then [:poly_pressure, e.note]
          end
        end

        # The pitch bend range (semitones) the file sets with RPN 0
        # (CC 101/100 = 0, then CC 6 semitones and CC 38 cents) before tick
        # +stop+ (the last one), or nil if it never does (2 semitones).
        def bend_ranges(evs, stop)
          rpn = [127, 127]
          range = nil
          evs.each do |tick, e|
            break if tick >= stop
            next unless e.type == :cc
            case e.note
            when 101 then rpn = [e.raw, rpn[1]]
            when 100 then rpn = [rpn[0], e.raw]
            when 98, 99, 121 then rpn = [127, 127]
            when 6 then range = e.raw + (range ? range % 1 : 0) if rpn == [0, 0]
            when 38 then range = (range || 2).floor + e.raw / 100.0 if rpn == [0, 0]
            end
          end
          range
        end

        # The ControlLanes of +evs+ in [start, stop) (see the class
        # description).
        def lanes(evs, start, stop, pos, cc, sustain:)
          before = {}
          inside = Hash.new { |h, k| h[k] = [] }
          evs.each do |tick, e|
            key = lane_key(e, sustain: sustain) or next
            next if cc.is_a?(Array) && !cc.include?(key[0] == :cc ? key[1] : key[0])
            break if tick >= stop
            if tick < start
              before[key] = e.value
            else
              inside[key] << [pos.call(tick), e.value]
            end
          end
          keys = (before.keys + inside.keys).uniq.sort_by { |t, n| [Sequence::ControlLane::TYPES.index(t), n || 0] }
          ranges = bend_ranges(evs, stop)
          keys.map { |key|
            pts = inside.fetch(key, [])
            pts = [[0r, before[key]]] + pts if before.key?(key) && pts.none? { |p, _| p == 0 }
            Sequence::ControlLane.new(key[0], key[1], pts, range: key[0] == :bend ? ranges : nil)
          }
        end
      end
    end
  end
end
