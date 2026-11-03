require 'date'
require 'fileutils'
require 'json'

module MB
  module Sound
    module UI
      # UI notes for the next refinement round (ui-scaffold-1, the
      # maintainer's u-notes: the library and live UIs get refinement
      # rounds from his notes after real use).  `ui.note 'the cutoff turns
      # too slowly'` (or NAV # for a prompt line while the set plays) keeps
      # the text with what was on screen and what was playing: the time,
      # the layout, the focused pane and mode, the terminal size, a plain
      # text capture of the screen, the players and tracks, the form's
      # section, the scene, the position, and the last console lines.
      # Notes go to one Markdown file per day in $MB_SOUND_UI_NOTES, else
      # the main checkout's tmp/ui-notes/ when mb-sound runs from a git
      # checkout, else the user data directory (ui-notes/ beside help/ and
      # takes/), appended, never rewritten (see .dir).  `ui.notes` lists today's.
      module NoteLog
        # The console lines kept with a note.
        COMMANDS = 8

        # A saved note: +time+, +text+, +path+ (the day's file), +where+
        # (the screen in words), +markdown+ (what was appended), +data+ (the
        # note's JSON record, see .record), +record+ (the record's Hash).
        Note = Data.define(:time, :text, :path, :where, :markdown, :data, :record) do
          def to_s = "ui.note saved #{time.strftime('%H:%M:%S')} (#{where}#{about}) to #{path}, data #{data}"
          def inspect = "#<#{self}>"

          private def about
            pt = record[:pointed]
            return '' unless pt
            ", at #{[pt[:seconds] && Panes::Render.time_text(pt[:seconds]), pt[:hz] && Panes::Render.freq_text(pt[:hz])].compact.join(' ')}"
          end
        end

        # The JSON records' format version (see .record).
        RECORD_VERSION = 1

        # The render data kept with a record: the envelope view's columns
        # and the spectrum's bands (what the RENDER pane drew), rounded.
        RECORD_DIGITS = 5

        # A day's notes: +path+, +day+, +entries+ ([[time text, first line
        # of the note], ...]).
        Listing = Data.define(:path, :day, :entries) do
          include Enumerable

          def each(&block) = entries.each(&block)
          def size = entries.size

          def to_s
            return "No UI notes on #{day} (ui.note 'text' saves one; NAV # while the screen is up)" if entries.empty?
            ["#{entries.length} UI note#{'s' unless entries.length == 1} on #{day} (#{path}):", *entries.map { |t, x| "  #{t}  #{x}" }].join("\n")
          end

          def inspect = to_s
        end

        module_function

        # Where notes go: $MB_SOUND_UI_NOTES, else tmp/ui-notes/ in the main
        # checkout when mb-sound runs from a git checkout (a worktree's main
        # checkout too: Internal.checkout_tmp_dir; the maintainer,
        # 2026-10-31: "The ui.note feature should save somewhere the
        # container can see", since the Mac's user data directory is outside
        # the /app volume), else the user data directory (an installed gem).
        def dir
          env = ENV['MB_SOUND_UI_NOTES']
          return File.expand_path(env) unless env.to_s.empty?
          tmp = Internal.checkout_tmp_dir
          return File.join(tmp, 'ui-notes') if tmp
          File.join(File.dirname(Internal.help_data_dir), 'ui-notes')
        end

        # The day's file for +day+ (a Date).
        def path_for(day) = File.join(dir, "#{day.strftime('%Y-%m-%d')}.md")

        # What the screen +screen+ (Tiles, Band, or nil) shows: { layout:,
        # focus:, mode:, size:, text: }, read now.  The tiles' NAV # prompt
        # takes this when the prompt opens (what was looked at), not when
        # Enter saves.
        def capture(screen = UI.screen || (UI.tiles if UI.tiles&.hidden?), session: nil)
          return { layout: nil, focus: nil, mode: :off, size: nil, text: nil, sound: sound_capture(nil, session) } unless screen
          if screen.is_a?(Tiles)
            {
              layout: screen.layout_name, focus: screen.tiler.focus, mode: screen.hidden? ? :hidden : screen.mode,
              size: [screen.cols, screen.rows], text: screen.hidden? ? nil : screen.to_text(:none), sound: sound_capture(screen, session),
            }
          else
            { layout: (screen.layout.name rescue nil), focus: nil, mode: :band, size: nil, text: screen.to_text(:none) }
          end
        rescue StandardError => e
          { layout: nil, focus: nil, mode: :unknown, size: nil, text: "(no capture: #{e.class}: #{e.message})" }
        end

        # Saves a note of +text+ (see the module description), with
        # +capture+ (#capture's Hash; now if nil) and +session+'s state:
        # the Markdown entry in the day's file and a JSON record (.record)
        # in this session's data directory (.session_dir).  +at+ (seconds
        # into the rendered note, or a Length) and +freq+ (Hz, or a Pitch)
        # name the spot the note is about; without them, the RENDER pane's
        # markers (, . < >) if placed.  Returns a Note.
        def save(text, capture: nil, session: Session.existing, time: Time.now, at: nil, freq: nil)
          text = text.to_s.strip
          raise ArgumentError, "ui.note takes the note's text (ui.note 'the cutoff turns too slowly')" if text.empty?
          capture ||= self.capture(session: session)
          rec = record(text, capture, session, time, at: at, freq: freq)
          data = data_path(time)
          FileUtils.mkdir_p(File.dirname(data))
          File.write(data, JSON.pretty_generate(rec) + "\n")
          md = markdown(text, capture, session, time, rec: rec, data: data)
          path = path_for(time.to_date)
          FileUtils.mkdir_p(File.dirname(path))
          File.open(path, 'a') do |f|
            f.write("# UI notes #{time.strftime('%Y-%m-%d')}\n\nSaved by `ui.note` (mb-sound) for the next UI refinement round.\n") if f.size == 0
            f.write("\n#{md}")
          end
          Note.new(time: time, text: text.freeze, path: path, where: where(capture).freeze, markdown: md.freeze, data: data, record: rec)
        end

        # This process's directory for the notes' JSON records: data/ in
        # .dir, one directory per session (its start time and process id).
        def session_dir
          @session_dir ||= File.join(dir, 'data', "#{Time.now.strftime('%Y%m%d_%H%M%S')}_#{Process.pid}")
          File.join(dir, 'data', File.basename(@session_dir))
        end

        # A new record's path for a note at +time+ (never one that exists).
        def data_path(time)
          base = File.join(session_dir, time.strftime('%H%M%S'))
          n = 0
          n += 1 while File.exist?(path = "#{base}#{n.zero? ? '' : "_#{n}"}.json")
          path
        end

        # The JSON records of this session (or of +session+, a directory
        # name under data/), oldest first: paths.
        def records(session = nil)
          d = session ? File.join(dir, 'data', session.to_s) : session_dir
          Dir[File.join(d, '*.json')].sort
        end

        # A note's record read back (plain data, symbol keys; JSON, never
        # evaluated).
        def read(path) = JSON.parse(File.read(path), symbolize_names: true)

        # The note's record: plain data an agent reads later to connect what
        # he heard with what he saw (format RECORD_VERSION): +text+,
        # +time+, +screen+ (layout, size, focus, mode, the screen as text),
        # +playing+ (the Markdown's lines), +commands+ (the last console
        # lines), +take+ (its lines so far, the timeline position and frame:
        # where in the take the note was written), +sound+ (the inspected
        # track, its instrument and graph document, its knobs and the
        # document's params at them, its A/B reference), +view+ (the RENDER
        # pane: view, length, rate, time and frequency ranges, markers),
        # +render+ (what it drew: the envelope's columns, the spectrum, the
        # figures), +pointed+ (the spot: at:/freq:, else the markers).
        def record(text, c, session, time, at: nil, freq: nil)
          snd = c[:sound] || {}
          view = snd[:view]
          pointed = {
            seconds: at.nil? ? view&.dig(:cursor, :seconds) : seconds_of(at),
            hz: freq.nil? ? view&.dig(:cursor, :hz) : hz_of(freq),
          }.compact
          {
            version: RECORD_VERSION, text: text, time: time.strftime('%Y-%m-%dT%H:%M:%S%z'),
            screen: { where: where(c), layout: c[:layout], size: c[:size], focus: c[:focus], mode: c[:mode], text: c[:text] },
            playing: playing_lines(session),
            commands: (Take.active&.recent_lines(COMMANDS) || []).map { |stamp, code| { at: stamp.to_s, code: code } },
            take: take_info(session),
            sound: snd.except(:view, :render),
            view: view,
            render: snd[:render],
            pointed: pointed.empty? ? nil : pointed,
          }
        end

        # Where the console's take is: its lines so far, the session's
        # timeline position (bar:beat) and frame.
        def take_info(session)
          t = Take.active
          out = { lines: t ? t.lines.length : nil }
          if session
            out[:position] = (session.clock.to_s[/\A#<Stamp (\S+)/, 1] rescue nil)
            out[:frame] = (session.frame rescue nil)
          end
          out
        end

        # Seconds from +v+ (a number of seconds or a Length).
        def seconds_of(v) = v.is_a?(Numeric) ? v.to_f : Length.seconds(v).to_f

        # Hz from +v+ (a number of Hz or a Pitch / Tone).
        def hz_of(v) = v.is_a?(Numeric) ? v.to_f : (v.respond_to?(:frequency) ? v.frequency.to_f : v.to_f)

        # The sound a note is about, read when it is captured: the inspected
        # track (Inspect.target, else the last designed), its instrument
        # entry and graph document, its knobs and the document's params at
        # them, its A/B pair, and the RENDER pane's view, markers, and data
        # (+screen+'s, when the tiles show one).  {} when there's no track.
        def sound_capture(screen, session = nil)
          session ||= (screen.respond_to?(:session) && screen.session) || Session.existing
          return {} unless session
          target = Inspect.target
          track = target.is_a?(Hash) ? target[:track] : nil
          track ||= Design.instance_variable_get(:@last)
          return {} unless track && session.arrangement.tracks.key?(track)
          out = { track: track }
          tr = session.arrangement.tracks[track]
          e = tr.patch && Arrangement::InstrumentPatch.entry_of(tr.patch)
          out[:instrument] = { name: e.name, family: e.family, path: e.location.is_a?(String) ? e.location : nil } if e
          prefix = "#{track}/"
          out[:knobs] = session.knobs.select { |n, _| n.to_s.start_with?(prefix) }.to_h { |n, k| [n, plain(k.value)] }
          vals = Reference.knob_values(session, track)
          out[:params] = vals.transform_values { |v| plain(v) } unless vals.empty?
          n, vel, hold = Reference.note_of(session, track)
          out[:note] = { number: n, velocity: plain(vel), hold: plain(hold) }
          if (pair = Reference.pair(session, track)) && pair.track == track
            out[:reference] = { source: pair.source, track: pair.ref, hearing: pair.hearing, level_db: plain(pair.level_db),
                                patch_lufs: plain(pair.patch_lufs), ref_lufs: plain(pair.ref_lufs), note: pair.note }
          end
          st = screen.respond_to?(:pane_state) ? screen.pane_state(:render) : nil
          if st
            r = st[:driver]&.shown
            r = nil if r && (r.track != track || r.error)
            secs = PatchRender.seconds.to_f
            rate = r&.rate&.to_f
            out[:view] = {
              pane: 'render', mode: (st[:view] || :all).to_s, seconds: secs, rate: rate,
              time_range: [0.0, secs], freq_range: [20.0, (rate || 48000.0) / 2],
              cursor: { seconds: st[:cursor_time], hz: st[:cursor_freq] }.compact,
            }
            out[:render] = render_data(r) if r
          end
          out
        rescue StandardError => e
          { error: "#{e.class}: #{e.message}" }
        end

        # A PatchRender::Result as plain data (see .record).
        def render_data(r)
          d = RECORD_DIGITS
          sec = ->(a) { a.to_a.map { |x| plain(x.to_f.round(d)) } }
          out = { input: r.input, lufs: plain(r.lufs), peak_db: plain(r.peak), rms_db: plain(r.rms), frequency: plain(r.frequency), settled: plain(r.settled), rate: r.rate }
          out[:envelope] = { columns: r.hi.length, seconds: r.frames.to_f / r.rate, hi: sec.(r.hi), lo: sec.(r.lo) } if r.hi
          out[:spectrum] = { hz: sec.(r.spectrum[0]), db: sec.(r.spectrum[1]) } if r.spectrum
          out
        end

        # +v+ for JSON: Floats rounded, non-finite as nil, Rationals as
        # Floats.
        def plain(v)
          case v
          when Float then v.finite? ? v : nil
          when Rational then v.to_f
          when Numeric then v
          when nil, true, false, String then v
          else v.to_s
          end
        end

        # The notes of +day+ (:today, a Date, or "2026-10-30").
        def list(day = :today)
          day = case day
                when :today, nil then Date.today
                when Date then day
                else Date.parse(day.to_s)
                end
          path = path_for(day)
          entries = File.exist?(path) ? File.readlines(path, chomp: true).grep(/\A## /).map { |l| l.delete_prefix('## ').split('  ', 2) } : []
          Listing.new(path: path, day: day.strftime('%Y-%m-%d'), entries: entries.map { |t, x| [t, x.to_s] }.freeze)
        end

        # The screen in words, from a #capture.
        def where(c)
          return 'no screen' if c[:mode] == :off
          parts = []
          parts << "ui #{c[:layout].inspect}" if c[:layout]
          parts << "#{c[:size][0]}x#{c[:size][1]}" if c[:size]
          parts << "focus #{c[:focus]}" if c[:focus]
          parts << "#{c[:mode]} mode" if c[:mode] && c[:mode] != :band
          parts.join(', ')
        end

        # The Markdown of one note (+rec+ its record, +data+ the record's
        # path).
        def markdown(text, c, session, time, rec: nil, data: nil)
          first, *rest = text.lines.map(&:rstrip)
          out = ["## #{time.strftime('%H:%M:%S')}  #{first}", '']
          out.concat(rest.map { |l| "> #{l}" }) << '' unless rest.empty?
          out << "- **screen**: #{where(c)}"
          if rec && (snd = rec[:sound]) && snd[:track]
            about = ["track #{snd[:track].inspect}"]
            about << "#{snd[:instrument][:name]}" if snd[:instrument]
            about << "reference #{snd[:reference][:source]} (hearing the #{snd[:reference][:hearing]})" if snd[:reference]
            if (pt = rec[:pointed])
              about << "at #{[pt[:seconds] && Panes::Render.time_text(pt[:seconds]), pt[:hz] && Panes::Render.freq_text(pt[:hz])].compact.join(' ')}"
            end
            out << "- **about**: #{about.join(', ')}"
          end
          out.concat(playing_lines(session))
          lines = Take.active&.recent_lines(COMMANDS) || []
          unless lines.empty?
            out << "- **last commands**:" << '' << '```ruby'
            lines.each { |stamp, code| out << "#{code.rstrip}  # #{stamp}" }
            out << '```'
          end
          out << "- **data**: #{data}" if data
          if c[:text]
            fence = '````'
            out << '' << "<details><summary>screen#{c[:size] ? " (#{c[:size][0]}x#{c[:size][1]})" : ''}</summary>" << '' << "#{fence}text"
            out.concat(c[:text].lines.map(&:rstrip))
            out << fence << '' << '</details>'
          end
          out.join("\n") + "\n"
        end

        # What +session+ plays, as Markdown list items: from the UI's latest
        # snapshot while a screen is up (published by the render thread;
        # nothing waits), else from the Session's own readers, which take the
        # render lock (audio-safety-2: a note while a set plays shouldn't
        # queue behind the render thread or hold it up).
        def playing_lines(session)
          return ['- **playing**: no session'] unless session
          snap = session.respond_to?(:ui_feed) && session.ui_feed&.latest
          snap ? snapshot_lines(snap) : session_lines(session)
        rescue StandardError => e
          ["- **playing**: (not read: #{e.class}: #{e.message})"]
        end

        # #playing_lines from a UI::Snapshot.
        def snapshot_lines(snap)
          slow = snap.slow
          at = ["bar #{snap.stamp}", "#{format('%g', snap.bpm.to_f.round(2))} bpm"]
          if (f = slow.form)
            at << "form #{f.ended ? 'ended' : "#{f.section} (pass #{f.pass}, next #{f.next} at #{f.next_at})"}"
          end
          slow.scene && at << "scene #{slow.scene.inspect}"
          tracks = slow.tracks.to_h { |t| [t.name, t] }
          players = snap.players
          names = players.map(&:name)
          list = players.map { |pl|
            tr = tracks[pl.name]
            state = pl.state == :playing ? '' : " #{pl.state}"
            tr ? "#{pl.name.inspect} (track: #{tr.clip}, q #{tr.q}#{state})" : "#{pl.name.inspect}#{state.empty? ? '' : " (#{state.strip})"}"
          }
          out = ["- **at**: #{at.join(', ')}", "- **players**: #{list.empty? ? 'none' : list.join('; ')}"]
          idle = tracks.keys - names
          out << "- **tracks not playing**: #{idle.map(&:inspect).join(', ')}" unless idle.empty?
          out
        end

        # #playing_lines from the Session (no screen up).
        def session_lines(session)
          out = []
          arr = session.arrangement
          clock = session.clock.to_s
          stamp = clock[/\A#<Stamp (\S+)/, 1] || clock
          at = ["bar #{stamp}", "#{format('%g', session.transport.bpm.to_f.round(2))} bpm"]
          (form = arr.playback) && at << "form #{form}"
          (scene = arr.current_scene) && at << "scene #{scene.inspect}"
          out << "- **at**: #{at.join(', ')}"
          tracks = arr.track_info
          players = session.players
          out << "- **players**: #{players.empty? ? 'none' : players.map { |n, d| tracks[n] ? "#{n.inspect} (track #{tracks[n]})" : "#{n.inspect} (#{d.to_s[0, 60]})" }.join('; ')}"
          idle = tracks.keys - players.keys
          out << "- **tracks not playing**: #{idle.map(&:inspect).join(', ')}" unless idle.empty?
          out
        end
      end
    end
  end
end
