module MB
  module Sound
    class Player
      # One file of a Player's playlist: what it is (#kind: :audio, :module,
      # :midi, :other), how it plays from a position, and what its screen
      # shows (#info, and the data its panes draw: an audio file's
      # overview, a module's patterns, a MIDI file's notes).  Item.for
      # picks the class by the file's type.  #load reads the file (the
      # slow part: ffmpeg, a module import) before it plays; #unload frees
      # it when the next one starts.
      class Item
        # Picks the Item class for +path+.
        def self.for(path)
          if Tracker.module_file?(path)
            ModuleItem.new(path)
          elsif path.to_s.downcase.end_with?('.mid', '.midi')
            MidiItem.new(path)
          elsif path.to_s.downcase.end_with?('.sfz', '.sf2')
            OtherItem.new(path)
          else
            AudioItem.new(path)
          end
        end

        attr_reader :path

        # Why it couldn't be loaded (an Exception), or nil.
        attr_reader :error

        def initialize(path)
          @path = path
          @error = nil
          @loaded = false
          @session = nil
          @end = nil
        end

        def kind = :other

        # The file's name.
        def title = File.basename(@path.to_s)

        # The screen layout for this kind (UI.show_layouts).
        def layout = :player

        # True once #load succeeded.
        def loaded? = @loaded

        # Reads the file for playing at +sample_rate+.  Returns true, or
        # false (with #error) if it can't be played.
        def load(sample_rate)
          return true if @loaded
          raise Errno::ENOENT, @path unless File.exist?(@path.to_s)
          load_file(sample_rate)
          @loaded = true
        rescue StandardError => e
          @error = e
          false
        end

        # Frees what #load read.
        def unload
          @loaded = false
          @session = nil
          @end = nil
        end

        # The master gain it plays at: the Session's usual -10 dB of
        # headroom for things that sum full-scale parts (MIDI on the default
        # patch, instruments, a module's channels: Tracker::Import::GAINS
        # were matched to openmpt123 through it, as `play` plays modules);
        # unity for recordings, which carry their own levels (as effect
        # scripts play them).
        def master_gain = Session::DEFAULT_MASTER_GAIN

        # Seconds the file plays (nil if unknown).
        def length = nil

        # [label, value] rows for the info pane.
        def info = [['file', title]]

        # Starts playing on +session+ (a realtime Session at timeline 0)
        # from the start.  Returns the PlaybackEnd that says when it ended.
        def start(session)
          raise NotImplementedError
        end

        # Seconds played (the render thread calls it after each buffer;
        # see Player#position).
        def position(_session) = 0.0

        # Moves by +seconds+ (negative: back); returns what to say.
        def seek_by(_seconds) = "#{kind} files don't seek"

        # Moves to the next (+dir+ 1) or previous (-1) section, or by a
        # big step; returns what to say.
        def jump(dir) = seek_by(dir * JUMP_SECONDS)

        # Back to the start; returns what to say.
        def restart = seek_by(-position(@session).to_f - 1)

        # [seconds, length] as text: "1:23 / 4:56".
        def self.clock(seconds)
          return '-:--' if seconds.nil?
          s = seconds.to_f.floor
          s >= 3600 ? format('%d:%02d:%02d', s / 3600, s / 60 % 60, s % 60) : format('%d:%02d', s / 60, s % 60)
        end

        private

        def load_file(_sample_rate); end
      end

      # A sound file, read into memory (one ffmpeg run before it plays, so
      # seeks never start a process on a live path): seeks start a new
      # input on the same arrays at the new position, crossfading 5 ms
      # (Session's replacement declick) on the exact frame.
      class AudioItem < Item
        # Columns of the overview kept (the pane picks from them).
        OVERVIEW_BINS = 1024

        # The audio (SFloat channels at the Session's rate), its rate, the
        # overview (OVERVIEW_BINS peak levels 0..1), and integrated loudness.
        attr_reader :data, :sample_rate, :overview, :lufs

        def initialize(path)
          super
          @data = @sample_rate = @overview = @lufs = @input = @meta = @description = nil
          @file_rate = @channels = @codec = @format = @bits = nil
        end

        def kind = :audio
        def layout = :player_audio
        def master_gain = 1.0

        def length
          @data && @data[0].length.to_f / @sample_rate
        end

        def unload
          super
          @data = @overview = @input = nil
        end

        def info
          rows = [['file', title]]
          rows << ['format', [@format, @codec].compact.uniq.join(', ')] if @format || @codec
          rows << ['rate', "#{Format.khz(@file_rate)}#{" (plays at #{Format.khz(@sample_rate)})" if @file_rate && @file_rate != @sample_rate}"] if @file_rate
          rows << ['channels', @channels.to_s] if @channels
          rows << ['bits', @bits.to_s] if @bits
          rows << ['length', Item.clock(length)] if @data
          rows << ['loudness', @lufs&.finite? ? format('%.1f LUFS', @lufs) : '-'] if @data
          (@meta || {}).each { |k, v| rows << [k.to_s, v.to_s] if %i[title artist album date].include?(k) }
          rows
        end

        def start(session)
          @session = session
          play_from(0, fade: 0)
          ending
        end

        def position(_session)
          i = @input or return 0.0
          i.offset.to_f / @sample_rate
        end

        def seek_by(seconds)
          return 'nothing loaded' unless @data
          to = (position(@session) + seconds).clamp(0.0, [length - 0.01, 0.0].max)
          play_from((to * @sample_rate).round)
          "#{seconds < 0 ? 'back' : 'forward'} to #{Item.clock(to)}"
        end

        def restart
          play_from(0)
          'from the start'
        end

        private

        def ending
          s = @session
          @end = PlaybackEnd.new(s, busy: -> { s.playing_after_queue?(:play) })
        end

        # Starts the file at frame +offset+ (replacing what plays: 5 ms
        # crossfade on the change's frame; +fade+ 0 for the first start).
        def play_from(offset, fade: nil)
          input = ArrayInput.new(data: @data, sample_rate: @sample_rate, shared: true)
          input.seek_set(offset.clamp(0, [input.frames - 1, 0].max))
          graph = Playable::Graph.new(nodes: input.outputs, description: @description, ends: true, note: nil)
          Session.with_context(session: @session) {
            fade ? MB::Sound.bg(:play, graph, on: :now, fade: fade) : MB::Sound.bg(:play, graph, on: :now)
          }
          @input = input
        end

        def load_file(sample_rate)
          input = MB::Sound.file_input(@path.to_s, resample: sample_rate.round)
          begin
            @meta = input.metadata
            stream = input.raw_info[:streams]&.first || {}
            @file_rate = stream[:sample_rate] || input.info[:sample_rate]
            @channels = stream[:channels] || input.channels
            @codec = stream[:codec_long_name] || stream[:codec_name]
            @format = input.raw_info.dig(:format, :format_long_name)
            @bits = stream[:bits_per_raw_sample] || (stream[:bits_per_sample].to_i > 0 ? stream[:bits_per_sample] : nil)
            data = input.read(input.frames)
          ensure
            input.close
          end
          data = data.map { |c| Numo::SFloat.cast(c) }
          raise ArgumentError, "#{title}: no audio" if data.empty? || data[0].length == 0
          tags = input.raw_info.dig(:format, :tags)
          @description = tags && !tags.empty? ? "#{@path}: #{MB::U.highlight(tags)}" : @path.to_s # (as Playable.file_description, without another ffprobe: seeks are live)
          @data = data
          @sample_rate = sample_rate.to_f
          @overview = Player.peaks(data, OVERVIEW_BINS)
          @lufs = MB::Sound.loudness(data, sample_rate: @sample_rate, true_peak: false).integrated
        end
      end

      # A MIDI file on the default patch (Playable::PATCH, as `play` plays
      # it): seeks rebuild the synth with the file read from the new
      # position (notes held across the position aren't struck again).
      class MidiItem < Item
        # The file's notes (MIDI::NoteList hashes: number, channel, on_time,
        # off_time, sustain_time) and its length in seconds.
        attr_reader :notes

        def initialize(path)
          super
          @notes = @source = @duration = @tracks = nil
        end

        def kind = :midi
        def layout = :player_midi

        def length = @duration&.to_f

        def unload
          super
          @notes = @source = nil
        end

        def info
          rows = [['file', title]]
          return rows unless @notes
          ch = @notes.map { |n| n[:channel] }.uniq.sort
          rows << ['length', Item.clock(length)]
          rows << ['notes', @notes.length.to_s]
          rows << ['channels', ch.map { |c| c + 1 }.join(' ')] unless ch.empty?
          rows << ['tracks', @tracks.to_s] if @tracks
          rows << ['patch', 'a soft saw (the default)']
          rows
        end

        def start(session)
          @session = session
          play_from(0, fade: 0)
          s = session
          @end = PlaybackEnd.new(s, busy: -> { s.playing_after_queue?(:play) })
        end

        def position(_session)
          src = @source or return 0.0
          src.content_position.to_f
        rescue StandardError
          0.0
        end

        def seek_by(seconds)
          to = (position(@session) + seconds).clamp(0.0, [length.to_f - 0.01, 0.0].max)
          play_from(to)
          "#{seconds < 0 ? 'back' : 'forward'} to #{Item.clock(to)}"
        end

        def restart
          play_from(0)
          'from the start'
        end

        private

        def play_from(seconds, fade: nil)
          graph, source = Playable.midi_file(@path.to_s, from: seconds)
          Session.with_context(session: @session) {
            fade ? MB::Sound.bg(:play, graph, on: :now, fade: fade) : MB::Sound.bg(:play, graph, on: :now)
          }
          @source = source
        end

        def load_file(_sample_rate)
          src = MIDI::FileSource.new(@path.to_s)
          @notes = src.notes
          @duration = src.duration
          @tracks = (MIDI::MIDIFile.new(@path.to_s).tracks.length rescue nil)
        end
      end

      # A tracker module as a set (Tracker::Set): seeks move the timeline
      # (Session#seek: journaled, exact, the form playing on from the pass
      # an uninterrupted run plays there), a bar at a time or a pattern
      # (a section of its flow) at a time.
      class ModuleItem < Item
        # The Tracker::Set, and [[start position, end position, visit]]
        # per section (whole notes from the song's start).
        attr_reader :set, :sections

        def initialize(path)
          super
          @set = @sections = @starts = @playback = @scrub = nil
        end

        def kind = :module
        def layout = :player_module

        def length = @set&.seconds

        def unload
          super
          @set = @sections = @playback = nil
        end

        def info
          return [['file', title]] unless @set
          song = @set.song
          used = song.samples.compact.count { |s| s.data && !s.data.empty? && s.data[0].length > 0 } rescue song.samples.compact.length
          rows = [['file', title]]
          rows << ['title', song.title.to_s.strip] unless song.title.to_s.strip.empty?
          rows << ['format', "#{song.format.to_s.upcase}, #{@set.mode}"]
          rows << ['channels', "#{@set.tracks.length} played of #{song.channels}"]
          rows << ['patterns', "#{song.patterns.length} (#{@sections.length} played)"]
          rows << ['samples', used.to_s]
          rows << ['tempo', "#{Format.num(@set.bpm)} bpm, speed #{song.speed}"]
          rows << ['length', Item.clock(length)]
          rows
        end

        def start(session)
          @session = session
          @playback = Session.with_context(session: session) { @set.play(on: :now) }
          @scrub = ScriptRunner::Scrub.new(session.transport, seek: ->(bar) { Session.with_context(session: session) { MB::Sound.seek(bar) } })
          @end = PlaybackEnd.for_form(session, @playback)
        end

        def position(session) = seconds_at(session.transport.position)

        # Seconds from the song's start to timeline position +pos+ (whole
        # notes), through each section's tempo.
        def seconds_at(pos)
          return 0.0 unless @sections
          pos = pos.to_r
          i = (@sections.rindex { |from, _, _| from <= pos } || 0).clamp(0, @sections.length - 2)
          from, to, name = @sections[i]
          (@starts[i] + section_seconds(name, [[pos, to].min - from, 0r].max)).to_f
        end

        # Left/Right: a bar (ScriptRunner::Scrub: first press to the bar's
        # start, then a bar a press; held, faster).
        def seek_by(seconds)
          bar = @scrub.press(seconds < 0 ? :left : :right)
          "bar #{bar}"
        end

        # Up/Down: the previous (from a section's first second: the one
        # before) or next section.
        def jump(dir)
          pos = @session.transport.position
          last = @sections.length - 2 # (the one-tick :fin isn't a place to go)
          i = (@sections.rindex { |from, _, _| from <= pos } || 0).clamp(0, last)
          if dir < 0
            i -= 1 if seconds_at(pos) - seconds_at(@sections[i][0]) < 1.0
            i = 0 if i < 0
          else
            return 'the last section already' if i >= last
            i += 1
          end
          from, _, name = @sections[i]
          Session.with_context(session: @session) { MB::Sound.seek(from.n1) }
          "#{name} (section #{i + 1} of #{last + 1})"
        end

        def restart
          Session.with_context(session: @session) { MB::Sound.seek(0r.n1) }
          'from the start'
        end

        # The visit (Tracker::Player::Visit) and row playing at timeline
        # position +pos+ ([visit, row index into visit.rows], or nil).
        def row_at(pos)
          tick = (pos.to_r * Tracker::TICKS_PER_WHOLE).floor
          visits = @set.import.result.visits
          v = visits.bsearch { |x| x.stop > tick } or return nil
          return nil if tick < v.start
          r = v.rows.rindex { |_, first, _| first <= tick } || 0
          [v, r]
        end

        private

        def section_seconds(name, len)
          s = @set.instance_variable_get(:@scenes)[name]
          changes = [[0r, s[:tempo]], *s[:changes].select { |p, _| p < len }, [len, nil]]
          changes.each_cons(2).sum { |(a, bpm), (b, _)| Sequence::TempoMap.seconds_at(b - a, bpm) }
        end

        def load_file(_sample_rate)
          @set = MB::Sound.mod_import(@path.to_s)
          pos = 0r
          secs = 0r
          @sections = []
          @starts = []
          @set.plays.each do |name, len|
            @sections << [pos, pos + len, name]
            @starts << secs
            secs += section_seconds(name, len)
            pos += len
          end
          @sections << [pos, pos + 1/96r, Tracker::Set::END_SCENE]
          @starts << secs
        end
      end

      # Anything else `play` takes as a file (an SFZ or SF2 instrument's
      # demo phrase): plays once, no seeking.
      class OtherItem < Item
        def kind = :other
        def layout = :player

        def start(session)
          @session = session
          graph = Playable.graph(@path.to_s, sample_rate: session.sample_rate)
          Session.with_context(session: session) { MB::Sound.bg(:play, graph, on: :now, fade: 0) }
          s = session
          @end = PlaybackEnd.new(s, busy: -> { s.playing_after_queue?(:play) })
        end

        def info = [['file', title], ['plays', Playable.graph(@path.to_s).description.to_s]]
      end

      # Number formats for info rows.
      module Format
        module_function

        def khz(rate)
          return '-' unless rate
          r = rate.to_f / 1000
          "#{r == r.round ? r.round : r.round(1)} kHz"
        end

        def num(v) = UI::Panes.fmt(v)
      end
    end
  end
end
