module MB
  module Sound
    module UI
      # The built-in panes (see UI.panes; `pane :name do ... end` adds
      # more).
      module Panes
        # Meters show -60..0 dBFS.
        METER_FLOOR = -60.0

        # Meter zones: green to -18 dBFS, yellow to -6, then red.
        DB_ZONES = [[42.0 / 60, :low], [54.0 / 60, :mid], [1.0, :high]].freeze

        module_function

        # A number for a pane: whole numbers without a decimal point, others
        # to 3 significant figures.
        def fmt(v)
          return '-' if v.nil?
          # (frozen strings kept per value: the painter formats the same
          # values frame after frame; ui-perf-1, 28 objects a frame on the
          # sound screen)
          FMT_MEMO[v] ||= begin
            FMT_MEMO.clear if FMT_MEMO.length >= MEMO_MAX
            f = v.to_f
            (f == -Float::INFINITY ? '-inf' : f.abs >= 100 || f == f.round ? f.round.to_s : format('%.3g', f)).freeze
          end
        end

        # Formatted values kept (.fmt, .db), at most MEMO_MAX each.
        FMT_MEMO = {}
        DB_MEMO = {}
        MEMO_MAX = 4096

        # The unit of a knob with Knob::Spec +spec+ driving a param named
        # +name+: the spec's, else what the Param names table implies for
        # the knob's or the param's name (a preset's cutoff param, a plain
        # number, shows in Hz), else nil.
        def unit_of(spec, name = nil)
          Param.implied_unit(spec, name)
        end

        # A dB value to one decimal ("-8.1", "-inf").
        def db(v)
          return '-' if v.nil?
          DB_MEMO[v] ||= begin
            DB_MEMO.clear if DB_MEMO.length >= MEMO_MAX
            (v.finite? ? format('%.1f', v) : '-inf').freeze
          end
        end

        # .db right-justified to 5 columns, kept per value.
        def db5(v)
          return -'    -' if v.nil?
          DB5_MEMO[v] ||= begin
            DB5_MEMO.clear if DB5_MEMO.length >= MEMO_MAX
            db(v).rjust(5).freeze
          end
        end
        DB5_MEMO = {}

        # 0..1 for a dBFS level on the meter scale.
        def db_frac(v)
          return 0.0 if v.nil? || !v.finite?
          ((v - METER_FLOOR) / -METER_FLOOR).clamp(0.0, 1.0)
        end

        # A load fraction as a percentage and its role.
        def load_text(load)
          return ['-', :dim] if load.nil?
          pct = (load * 100).round
          [format('%d%%', pct), load_role(load)]
        end

        # The role of a load fraction (see .load_text).
        def load_role(load)
          return :dim if load.nil?
          load < 0.5 ? :ok : load < 0.8 ? :warn : :bad
        end

        # .load_text's text right-justified to 4 columns, kept per
        # percentage (the transport pane each frame).
        def load_text4(load)
          return LOAD_DASH if load.nil?
          pct = (load * 100).round
          LOAD_MEMO[pct] ||= begin
            LOAD_MEMO.clear if LOAD_MEMO.length >= MEMO_MAX
            format('%d%%', pct).rjust(4).freeze
          end
        end
        LOAD_DASH = '   -'.freeze
        LOAD_MEMO = {}

        # Transport: play state, bar:beat, tempo, meter, render load, and
        # output underruns.
        class Transport < Pane
          def initialize = super(:transport, rate: 30, height: 1, width: 44, description: 'play state, bar:beat, tempo, meter, render load, underruns')

          def draw_body(c, s, state)
            unless s
              c.puts ['no session yet ', :dim], ['(bg something to start one)', :dim]
              return
            end

            hist = (state[:loads] ||= [])
            if s.load && state[:seq] != s.seq
              hist << s.load
              hist.shift while hist.length > 16
              state[:seq] = s.seq
            end

            # (one text call per segment and strings kept while their values
            # stay, instead of segment Arrays and new strings each frame: the
            # same cells, no garbage in the steady state; ui-perf-1)
            role = Panes.load_role(s.load)
            beat = s.beat.floor
            unless state[:stamp_bar] == s.bar && state[:stamp_beat] == beat
              state[:stamp_bar] = s.bar
              state[:stamp_beat] = beat
              state[:stamp] = s.stamp.ljust(6).freeze
            end
            unless state[:meter_of].equal?(s.bar_length) || state[:meter_of] == s.bar_length
              state[:meter_of] = s.bar_length
              state[:meter] = s.meter.freeze
            end
            # (paused: the bar stands while effects ring out, a pause sign
            # instead of the stop square; its String kept per glyph set)
            x = if s.paused
              sep = c.glyph(:sep)
              unless state[:pause_of].equal?(sep)
                state[:pause_of] = sep
                state[:pause_mark] = (sep * 2).freeze
              end
              c.text(0, 0, state[:pause_mark], :warn)
            else
              c.text(0, 0, s.playing ? c.glyph(:play) : c.glyph(:stop), s.playing ? :ok : :dim)
            end
            x = c.text(x, 0, -' ')
            x = c.text(x, 0, state[:stamp], :key)
            x = c.text(x, 0, -' ')
            x = c.text(x, 0, Panes.fmt(s.bpm), :name)
            x = c.text(x, 0, -' bpm ', :dim)
            x = c.text(x, 0, state[:meter], :name)
            x = c.text(x, 0, -'  load ', :dim)
            x = c.text(x, 0, Panes.load_text4(s.load), role)
            x = c.text(x, 0, -' ')
            x = c.sparkline(hist, lo: 0.0, hi: 1.0, width: 8, x: x, y: 0, role: role)
            if s.underruns
              unless state[:xruns_of] == s.underruns
                state[:xruns_of] = s.underruns
                state[:xruns] = s.underruns.to_s.freeze
              end
              x = c.text(x, 0, -'  xruns ', :dim)
              c.text(x, 0, state[:xruns], s.underruns > (state[:xruns_at_start] ||= s.underruns) ? :bad : :ok)
            end
          end
        end

        # Form: the section playing, how far through it, and what comes
        # next; the current scene without a form.
        #
        # In its own mode (NAV Enter; ui-phase1-1, the 2026-11-21 plan's
        # Phase 1 item 3: "the form pane is the only place the song's
        # sections show, and it does nothing") the keys steer the form with
        # the lines a player types: Up/Down pick one of its sections
        # (Form::Playback#section_rows, in the order they first play),
        # Enter goes there next (`goto :drop`, at the section's end), r
        # loops the section (`loop!` for the one playing, `practice :drop`
        # for another; again on a looping one: `onward`), n moves on
        # (`onward`), > leaves at the next bar line (`skip`), f plays the
        # ending next (`finish`), Space plays or pauses the transport as
        # NAV Space does (the plan's vocabulary: a pane with nothing of its
        # own to play).  With one row the picked section shows on it; with
        # more, the status line and then the sections, the picked one
        # reversed.  Outside the mode it draws as it always has.
        class Form < Pane
          mode_keys do
            group 'Form'
            on [:up, 'k'], :pick, -1, help: 'the section above, below', label: 'Up Down'
            on [:down, 'j'], :pick, 1, help: 'the section above, below', label: 'Up Down'
            on :enter, :goto, help: 'go there next (goto :drop, at this section\'s end)', label: 'Enter'
            on 'r', :loop, help: 'loop it (loop!, or practice :drop for another; again: onward)'
            on 'n', :onward, help: 'move on after a loop (onward)'
            on '>', :skip, help: 'leave this section at the next bar line (skip)'
            on 'f', :finish, help: 'the ending next (finish)'
            on ' ', :transport, help: 'play / pause the transport (as NAV Space)', label: 'Space'
            on 'e', :edit_line, help: PaneKeys::EDIT_HELP
            on 'y', :copy_text, help: "copy the pane's text (OSC 52)"
          end

          def initialize = super(:form, rate: 8, height: 1, width: 44, description: 'the form\'s section, how far through, and what comes next (or the scene); steer it from its keys')

          def draw_body(c, s, state)
            return unless s

            state[:snap] = s
            f = s.form
            return draw_mode(c, s, f, state) if state[:mode]
            draw_status(c, s, f)
          end

          # Up/Down: the section above or below (from the one playing when
          # none is picked yet).
          def key_pick(state, d)
            rows = rows_of(state) or return no_form_note(state)
            i = rows.index { |r| r[0] == picked_name(state) } || 0
            i = (i + d).clamp(0, rows.length - 1)
            state[:pick] = rows[i][0]
            "#{rows[i][0]} #{rows[i][1]} (Enter goes there next, r loops it)"
          end

          # The arrows' scrolling (Pane's) picks here.
          def key_scroll(state, *) = key_pick(state, 1)

          # Enter: the picked section next (`goto :drop`).
          def key_goto(state)
            name = picked_name(state) or return no_form_note(state)
            PaneKeys::Run["goto #{name.inspect}", "#{name} next (at this section's end)"]
          end

          # r: loops the picked section: `loop!` for the one playing
          # (`onward` if it already loops), `practice :drop` for another.
          def key_loop(state)
            name = picked_name(state) or return no_form_note(state)
            f = state[:snap].form
            return PaneKeys::Run["practice #{name.inspect}", "#{name} next, looping (n moves on)"] unless name == f.section
            return PaneKeys::Run['onward', "#{name} stops looping (onward)"] if f.looping
            PaneKeys::Run['loop!', "#{name} loops (n or r moves on)"]
          end

          # n: the form moves on after a loop (`onward`).
          def key_onward(state)
            rows_of(state) or return no_form_note(state)
            PaneKeys::Run['onward', 'the form moves on at the next boundary']
          end

          # >: leaves the section playing at the next bar line (`skip`).
          def key_skip(state)
            rows_of(state) or return no_form_note(state)
            PaneKeys::Run['skip', 'leaving this section at the next bar line']
          end

          # f: the form's ending next (`finish`).
          def key_finish(state)
            rows_of(state) or return no_form_note(state)
            PaneKeys::Run['finish', 'the ending next']
          end

          # Space: the transport's play / pause, as NAV Space.
          def key_transport(_state) = MB::Term::Input::Action.of(:pause)

          # e: Enter's line (PaneKeys#key_edit_line).
          def edit_line(state) = key_goto(state)

          private

          # The status line (the pane outside its mode).
          def draw_status(c, s, f)
            if f.nil? || f.ended
              text = f&.ended ? 'form ended' : 'no form'
              x = c.line(0, [text, :dim])
              c.line(0, ['  scene ', :dim], [s.scene.to_s, :key], x: x) if s.scene
              return
            end

            len = s.bar_length.to_r
            bars = ((f.to - f.from) / len).to_f
            bar = ((s.pos - f.from) / len).floor + 1
            bar = bar.clamp(1, [bars.ceil, 1].max)
            x = c.line(0, [f.section.to_s, :key], [" #{f.pass}#{f.looping ? ' ∞' : ''} ", :dim])
            x = c.meter(bars > 0 ? (bar - 1 + (s.beat.to_f - 1) / (len * 4).to_f) / bars : 0.0, width: 8, x: x, y: 0, role: :key)
            x = c.line(0, [" #{bar}/#{Panes.fmt(bars)}", :dim], x: x)
            c.line(0, ["  #{c.glyph(:arrow)} ", :dim], [f.next ? f.next.to_s : '?', f.committed ? :name : :dim], [" #{f.next_at}", :dim], x: x)
          end

          # The mode: one row shows the picked section; more rows show the
          # status line, then the sections (the picked one reversed, the one
          # playing marked, the next one's start beside it).
          def draw_mode(c, s, f, state)
            rows = f && !f.ended ? f.sections : nil
            if rows.nil? || rows.empty?
              draw_status(c, s, f)
              c.text_fit(0, 1, 'no form to steer (flow do ... end, or a demo)', c.w, :dim) if c.h > 1
              return
            end
            pick = rows.index { |r| r[0] == picked_name(state) } || 0
            if c.h == 1
              section_row(c, 0, rows[pick], f, true, "#{pick + 1}/#{rows.length} ")
              return
            end
            draw_status(c, s, f)
            fit = c.h - 1
            top = state[:top].to_i
            top = pick if pick < top
            top = pick - fit + 1 if pick >= top + fit
            state[:top] = top = top.clamp(0, [rows.length - fit, 0].max)
            rows[top, fit].each_with_index { |r, i| section_row(c, i + 1, r, f, top + i == pick) }
          end

          # One section's row: playing (▶) or next (→) marks, its name
          # (reversed when picked), its lengths.
          def section_row(c, y, row, f, sel, prefix = nil)
            name, text = row
            mark = name == f.section ? [c.glyph(:play), :ok] : name == f.next ? [c.glyph(:arrow), :name] : [' ', nil]
            x = prefix ? c.text(0, y, prefix, :dim) : 0
            x = c.text(x, y, mark[0], mark[1])
            x = c.text(x, y, ' ')
            x = c.run(x, y, name.to_s, sel ? :key : :name, reverse: sel)
            what = name == f.section ? " #{text}#{f.looping ? ' ∞ looping' : ''}" : name == f.next ? " #{text}  at #{f.next_at}" : " #{text}"
            c.text_fit(x, y, what, [c.w - x, 0].max, :dim)
          end

          # The picked section's name: the one picked, else the one playing.
          def picked_name(state)
            rows = rows_of(state) or return nil
            p = state[:pick]
            return p if p && rows.any? { |r| r[0] == p }
            state[:snap].form.section || rows[0][0]
          end

          # The playing form's section rows, or nil without one.
          def rows_of(state)
            f = state[:snap]&.form
            return nil if f.nil? || f.ended || f.sections.empty?
            f.sections
          end

          def no_form_note(state)
            state[:snap]&.form&.ended ? 'the form ended (start plays it again)' : 'no form playing (flow do ... end, or a demo)'
          end
        end

        # Tracks and other players: state, clip, armed and recording.
        #
        # In the pane (NAV Enter; tuner-fixes-1, the maintainer: "The tracks
        # interface should let me use arrows to highlight tracks and then
        # delete them, or change their volume"; "+5 more" with nothing to
        # scroll): Up/Down pick a track (the list scrolls to it),
        # Left/Right its level a dB down or up (`level :kick, -3.db`), 0
        # back to 0 dB, x stops it, d (or Delete) twice removes it from the
        # set (`untrack`, undoable), v hides or shows stopped tracks.
        #
        # knobs-pane-keys-1 (the maintainer: "Pressing and holding the arrow
        # key in the tracks pane to change levels should change level
        # faster, but most of the keys just repeat the same level, and
        # there's a pretty long delay"; "If I can stop a track in the tracks
        # pane, I should also be able to resume it"; "S would be for solo";
        # "M for mute"): the level a key set is carried for the next key and
        # shown at once (UI::CarriedValues, as the knob panes do), so every
        # repeat of a held arrow steps on.  A level is a knob
        # (:"drums/level", Session::Faders), so its keys are a knob gesture
        # (UI::KnobTurns, UI::TurnGesture; round 2, the maintainer's
        # 2026-11-21 "yes" to "a live preview while held and one `level`
        # line on release, as knobs do"): each Left/Right moves the level
        # live (PaneKeys::Preview), and when the keys stop the gesture is
        # ONE line, its final value (`level :drums, -10.0.db`;
        # Session#gesture_line): one journal entry, one undo step, a take
        # line replaying the sweep heard.  0 is one `level :drums, 0.0.db`
        # line.  Level lines print as knob turns do: nothing in the REPL
        # pane, the latest on the pane's last row in its mode
        # (KnobTurns#turn_line_canvas).  Space plays or stops the picked
        # track (`resume :kick` when stopped, `stop :kick` when playing; NAV
        # Space stays the transport's), s solos or unsolos it, m mutes or
        # unmutes it, from the snapshot's flags (marked solo and muted in
        # its row).
        class Tracks < Pane
          include KnobTurns

          # The loudest level the keys set (Session::Faders::MAX_LEVEL, +12 dB).
          MAX_DB = (20 * Math.log10(Session::Faders::MAX_LEVEL)).floor.to_f

          # Part states a track's Space resumes from (else it stops it).
          RESUMES = %i[stopped stopping fading ringing].freeze

          def initialize = super(:tracks, rate: 8, height: 6, width: 30, title: 'tracks', min_height: 2, description: 'tracks and players: state, clip, armed, recording')

          mode_keys do
            group 'Tracks'
            on [:up, 'k'], :pick, -1, help: 'the track above', label: 'Up Down'
            on [:down, 'j'], :pick, 1, help: 'the track below', label: 'Up Down'
            on [:page_up], :pick, -5, help: 'five tracks up', label: 'PgUp PgDn'
            on [:page_down], :pick, 5, help: 'five tracks down', label: 'PgUp PgDn'
            on [:left, 'h'], :level, -1, help: 'its level 1 dB down, up (held: live, one level line)', label: 'Left Right'
            on [:right, 'l'], :level, 1, help: 'its level 1 dB down, up (held: live, one level line)', label: 'Left Right'
            on '0', :level, 0, help: 'its level back to 0 dB'
            on 'x', :stop_track, help: 'stop it (stop)'
            on ' ', :play_stop, help: 'this track: resume or stop (NAV Space: the transport)', label: 'Space'
            on 's', :solo, help: 'solo, unsolo it'
            on 'm', :mute, help: 'mute, unmute it'
            on ['d', :delete], :untrack, help: 'remove it from the set (untrack; d twice; undo brings it back)', label: 'd Del'
            on 'v', :stopped_view, help: 'hide or show stopped tracks'
            on 'e', :edit_line, help: PaneKeys::EDIT_HELP
            on 'y', :copy_text, help: "copy the pane's text (OSC 52)"
          end

          STATE_ROLES = {
            playing: :ok, starting: :queued, stopping: :warn, fading: :warn, ringing: :warn,
            muted: :dim, asleep: :dim, stopped: :dim,
          }.freeze

          # [[name, clip, state, armed, trigger, level, muted, soloed], ...]
          # from snapshot +s+ (stopped ones left out when +hide+); +muted+
          # and +soloed+ are the player's own flags.
          def self.rows(s, hide: false)
            parts = s.players.to_h { |p| [p.name, p] }
            rows = s.tracks.map { |t|
              p = parts[t.name]
              [t.name, t.clip, p&.state || :stopped, t.armed, t.trigger, t.level, p&.muted || false, p&.soloed || false]
            }
            names = s.tracks.map(&:name)
            parts.each_value do |p|
              next if names.include?(p.name) || Session::Name.monitored(p.name)
              rows << [p.name, 'bg', p.state, false, nil, nil, p.muted, p.soloed]
            end
            hide ? rows.reject { |r| r[2] == :stopped } : rows
          end

          def draw_body(c, s, state)
            return unless s

            state[:snap] = s
            c = turn_line_canvas(c, state) if state[:mode] # (the latest level line)
            rec = s.recording.to_h { |r| [r.name, r] }
            all = Tracks.rows(s)
            rows = state[:hide_stopped] ? all.reject { |r| r[2] == :stopped } : all
            hidden = all.length - rows.length
            state[:names] = rows.map(&:first)
            if rows.empty?
              c.puts [hidden > 0 ? "#{hidden} stopped (v shows them)" : 'nothing playing', :dim]
              return
            end

            name_w = [[rows.map { |r| r[0].to_s.length }.max, 6].max, 12].min
            cur = state[:cursor] && rows.index { |r| r[0] == state[:cursor] }
            # (rows for tracks, less one for the "more" line when they don't fit)
            fit = rows.length > c.h ? [c.h - 1, 1].max : rows.length
            top = state[:top].to_i
            top = cur if cur && cur < top
            top = cur - fit + 1 if cur && cur >= top + fit
            state[:top] = top = top.clamp(0, [rows.length - fit, 0].max)
            show = rows[top, fit]
            show.each_with_index do |(name, clip, st, armed, trigger, level, muted, soloed), y|
              r = rec[name]
              st = :muted if muted && st == :playing # (its own mute; :muted is also a solo elsewhere's silence)
              level = carried(state, name) || level if state[:pending] # (a level a key just set, until the poll has it)
              glyph, role =
                if r then [c.glyph(:rec), :rec]
                elsif armed then [c.glyph(:armed), :armed]
                elsif st == :stopped then [c.glyph(:off), :dim]
                else [c.glyph(:on), STATE_ROLES.fetch(st, :text)]
                end
              picked = name == state[:cursor]
              x = c.line(y, [glyph, role], picked ? ['▸', :key] : ' ', [c.pad(name, name_w), picked ? :key : :name], ' ')
              what = r ? "rec #{c.glyph(:arrow)}#{r.ends}#{r.queued ? ' (queued)' : ''}" : st == :playing ? clip.to_s : "#{st} #{clip}"
              what = "trigger #{what}" if trigger # (a trigger track: heard only by sidechains)
              what = "solo #{what}" if soloed
              what = "#{level.finite? ? Panes.fmt(level) : '-inf'} dB #{what}" if level # (its level, when set away from unity)
              c.text_fit(x, y, what, c.w - x, r ? :rec : st == :playing ? :text : :dim)
            end
            if show.length < rows.length
              below = rows.length - top - show.length
              more = [top > 0 ? "#{top} above" : nil, below > 0 ? "+#{below} more" : nil].compact.join(', ')
              c.text_fit(0, c.h - 1, more, c.w, :dim)
            elsif hidden > 0 && c.h > rows.length
              c.text_fit(0, c.h - 1, "#{hidden} stopped hidden (v)", c.w, :dim)
            end
          end

          # Up/Down: the next or previous track (by +d+), scrolled into view.
          def key_pick(state, d)
            names = state[:names] || []
            return 'no tracks' if names.empty?
            i = names.index(state[:cursor])
            i = i ? (i + d).clamp(0, names.length - 1) : (d > 0 ? 0 : names.length - 1)
            state[:cursor] = names[i]
            hidden = state[:hide_stopped] ? '; v shows stopped tracks' : ''
            "#{names[i]} (Left Right level, Space play/stop, s solo, m mute#{hidden})"
          end

          # The arrows' scrolling (Pane's) picks here.
          def key_scroll(state, *) = key_pick(state, 1)

          # Left/Right: the picked track's level by +d+ dB, on from the
          # level the last key set while the poll catches up (CarriedValues:
          # a held arrow steps every repeat), at most MAX_DB: a step of a
          # knob gesture on its level knob (a live Preview; the Commit, one
          # `level` line, when the keys stop: KnobTurns#key_tick).  0: back
          # to 0 dB, one `level` line (after any gesture's).
          def key_level(state, d)
            name = state[:cursor] or return 'pick a track first (Up Down)'
            t = state[:snap]&.tracks&.find { |x| x.name == name }
            return "#{name}: not a track (a player of its own; its graph sets its level)" unless t
            if d.zero?
              carry(state, name, 0.0)
              return [*flush(state), PaneKeys::Turn["level #{name.inspect}, 0.0.db", "#{name} at 0 dB"]]
            end
            now = carried(state, name) || t.level
            now = 0.0 unless now&.finite?
            db = [(now + d).round(1), MAX_DB].min
            return "#{name} at #{Panes.fmt(db)} dB (the most a level goes)" if db == now && d > 0
            carry(state, name, db)
            kn = Session::Name.level(name)
            g = (state[:gesture] ||= TurnGesture.new)
            out = g.turning? && g.knob != kn ? flush(state) : nil
            from = g.turning? ? g.value : Decibels.new(now).to_f
            pv = g.step(kn, from, Decibels.new(db).to_f, self.class.clock.call)
            [*out, pv.with(note: "#{name} at #{Panes.fmt(db)} dB")]
          end

          # A level gesture's Commit (KnobTurns#key_tick) says its line on
          # the status line, not the knob's gain.
          def key_tick(state)
            r = super
            r.is_a?(PaneKeys::Commit) ? r.with(note: nil) : r
          end

          # Space: plays the picked track again if it is stopped (or
          # stopping: `resume :kick`), else stops it (`stop :kick`).
          def key_play_stop(state)
            row = picked_row(state) or return 'pick a track first (Up Down)'
            name, _, st = row
            return key_stop_track(state) unless RESUMES.include?(st)
            # (the poll's list of what can come back lags the parts by up to
            # its period: a track these keys just stopped counts too)
            if st == :stopped && !state[:snap].stopped.include?(name) && !state[:stopped_here]&.include?(name)
              return "#{name} has nothing to resume (it never played: launch it from the clip matrix or a scene)"
            end
            state[:stopped_here]&.delete(name)
            PaneKeys::Run["resume #{name.inspect}", "#{name} resuming (on the next bar)"]
          end

          # s: solos the picked track, or unsolos it if it is soloed.
          def key_solo(state)
            row = picked_row(state) or return 'pick a track first (Up Down)'
            name = row[0]
            row[7] ? PaneKeys::Run["unsolo #{name.inspect}", "#{name} unsoloed"] : PaneKeys::Run["solo #{name.inspect}", "#{name} soloed"]
          end

          # m: mutes the picked track, or unmutes it if it is muted.
          def key_mute(state)
            row = picked_row(state) or return 'pick a track first (Up Down)'
            name = row[0]
            row[6] ? PaneKeys::Run["unmute #{name.inspect}", "#{name} unmuted"] : PaneKeys::Run["mute #{name.inspect}", "#{name} muted"]
          end

          # x: stops the picked track (`stop :kick`).
          def key_stop_track(state)
            name = state[:cursor] or return 'pick a track first (Up Down)'
            hide = state[:hide_stopped] ? ' (stopped tracks are hidden: v shows them)' : ''
            (state[:stopped_here] ||= []) << name unless state[:stopped_here]&.include?(name)
            PaneKeys::Run["stop #{name.inspect}", "#{name} stopping#{hide}"]
          end

          # d (Delete): the picked track out of the set (`untrack :clap`) on
          # the second press; the first says what it will do.
          def key_untrack(state)
            name = state[:cursor] or return 'pick a track first (Up Down)'
            unless state[:snap]&.tracks&.any? { |x| x.name == name }
              return "#{name}: not a track (stop #{name.inspect} ends a player)"
            end
            if state[:untracking] == name
              state[:untracking] = nil
              names = state[:names] || []
              i = names.index(name)
              state[:cursor] = i && (names[i + 1] || (i > 0 ? names[i - 1] : nil))
              return PaneKeys::Run["untrack #{name.inspect}", "#{name} removed (undo brings it back)"]
            end
            state[:untracking] = name
            "d again removes #{name} from the set (undo brings it back)"
          end

          # e: Space's line for the picked track (`resume :kick` or `stop
          # :kick`; PaneKeys#key_edit_line), without its bookkeeping.
          def edit_line(state)
            row = picked_row(state) or return 'pick a track first (Up Down)'
            name, _, st = row
            RESUMES.include?(st) ? PaneKeys::Run["resume #{name.inspect}"] : PaneKeys::Run["stop #{name.inspect}"]
          end

          # v: hides or shows stopped tracks (this pane only).
          def key_stopped_view(state)
            state[:hide_stopped] = !state[:hide_stopped]
            state[:top] = 0
            state[:hide_stopped] ? 'stopped tracks hidden (v shows them)' : 'stopped tracks shown'
          end

          private

          # Another key's flush of a level gesture (KnobTurns#flush), its
          # note left to the line as #key_tick does.
          def flush(state) = super.map { |r| r.is_a?(PaneKeys::Commit) ? r.with(note: nil) : r }

          # (KnobTurns' value carried for the level knob: the rows read the
          # track's own carried dB)
          def remember(_state, _g) = nil

          # The picked track's row (see .rows) in the snapshot it drew, or nil.
          def picked_row(state)
            name = state[:cursor] or return nil
            s = state[:snap] or return nil
            Tracks.rows(s).find { |r| r[0] == name }
          end
        end

        # The keys of the panes that show queued changes (the queue and the
        # launch lane; ui-phase1-1, the plan's Phase 1 item 5: "pick a
        # queued change; x cancels it"): Up/Down pick one, soonest first
        # (the soonest until one is picked), x cancels it with the console
        # line `cancel queued: :bass, kind: :stop` (ScheduleMethods#cancel:
        # one undo step, so u in the clip matrix or `undo` queues it
        # again).  The set's own changes (source :set: a song form's next
        # section) are refused with a flash: the form pane steers those.
        # A pane including it keeps its snapshot in `state[:snap]`.
        module QueuedKeys
          def self.included(base)
            base.mode_keys do
              group 'Queued'
              on [:up, 'k'], :pick_queued, -1, help: 'the change before, after', label: 'Up Down'
              on [:down, 'j'], :pick_queued, 1, help: 'the change before, after', label: 'Up Down'
              on 'x', :cancel_queued, help: 'cancel it before it lands (cancel queued: :bass, kind: :stop; undo queues it again)'
              on 'e', :edit_line, help: PaneKeys::EDIT_HELP
              on 'y', :copy_text, help: "copy the pane's text (OSC 52)"
            end
          end

          # Up/Down: the queued change before or after the picked one.
          def key_pick_queued(state, d)
            q = sorted_queued(state)
            return 'nothing queued' if q.empty?
            i = (picked_index(state, q) + d).clamp(0, q.length - 1)
            e = q[i]
            state[:pick] = e.seq
            "#{e.kind} #{e.subject.inspect} lands #{e.lands} (x cancels it)"
          end

          # The arrows' scrolling (Pane's) picks here.
          def key_scroll(state, *) = key_pick_queued(state, 1)

          # x: cancels the picked queued change (all queued changes of its
          # kind for its subject: `cancel queued:` names them so).
          def key_cancel_queued(state)
            q = sorted_queued(state)
            return 'nothing queued to cancel' if q.empty?
            e = q[picked_index(state, q)]
            if e.source == :set
              return "#{e.kind} #{e.subject.inspect} is the song form's own (steer it in the form pane: goto, skip, loop!)"
            end
            state[:pick] = nil
            PaneKeys::Run["cancel queued: #{e.subject.inspect}, kind: #{e.kind.inspect}", "#{e.kind} #{e.subject.inspect} cancelled (undo queues it again)"]
          end

          # e: x's line for the picked change (PaneKeys#key_edit_line).
          def edit_line(state)
            q = sorted_queued(state)
            return 'nothing queued' if q.empty?
            e = q[picked_index(state, q)]
            PaneKeys::Run["cancel queued: #{e.subject.inspect}, kind: #{e.kind.inspect}"]
          end

          private

          # The snapshot's queued changes, soonest first.
          def sorted_queued(state)
            s = state[:snap] or return []
            s.queued.sort_by { |e| [e.pos || Float::INFINITY, e.seq] }
          end

          # The picked change's index in +q+ (the soonest when none is
          # picked or it landed).
          def picked_index(state, q)
            q.index { |e| e.seq == state[:pick] } || 0
          end
        end

        # Queued changes, soonest first, with where each lands.
        #
        # In its mode (NAV Enter; ui-phase1-1, the plan's Phase 1 item 5)
        # the keys of UI::Panes::QueuedKeys: Up/Down pick a queued change
        # (reversed), x cancels it (`cancel queued: :bass, kind: :stop`;
        # undo queues it again).
        class Queue < Pane
          include QueuedKeys

          def initialize = super(:queue, rate: 4, height: 6, width: 26, title: 'queued', description: 'queued changes, soonest first, with where each lands; cancel one from its keys')

          def draw_body(c, s, state)
            return unless s

            state[:snap] = s
            q = s.queued.sort_by { |e| [e.pos || Float::INFINITY, e.seq] }
            if q.empty?
              c.puts ['nothing queued', :dim]
              return
            end
            pick = state[:mode] ? picked_index(state, q) : nil
            top = pick && pick >= c.h ? pick - c.h + 1 : 0
            q[top, c.h].each_with_index do |e, y|
              x = c.line(y, [e.lands.ljust(6), :queued], ' ', [e.kind.to_s, :dim], ' ')
              sel = pick == top + y
              sel ? c.run(x, y, c.fit(e.subject.inspect, c.w - x), :name, reverse: true) : c.text_fit(x, y, e.subject.inspect, c.w - x, :name)
            end
          end
        end

        # Knobs: a meter at each knob's position in its range, and its value.
        #
        # In the pane's mode (NAV Enter, or its jump letter o: the
        # maintainer's 2026-11-21 "o works for knobs jump for now";
        # knobs-pane-keys-1, the maintainer:
        # "I expect the knobs pane to let me turn the knobs with the
        # keyboard") the keys of the racks pane's knob rows, through the
        # same UI::KnobTurns: Up/Down pick a knob (reversed; the list
        # scrolls to it), Left/Right turn it by 2% of its position (Shift or
        # H/L 0.2%; held: a live sweep and one `turn` line when the keys
        # stop), 0 its default, Enter a typed value.  Build knobs turn one
        # `turn` line a press (each rebuilds their track).  Turn lines show
        # on the pane's last row while in the mode, never in the REPL pane.
        # Outside the mode the pane draws as it always has.
        class Knobs < Pane
          include KnobTurns
          jump 'o'

          mode_keys do
            group 'Knobs'
            on [:up, 'k'], :pick, -1, help: 'previous knob', label: 'Up Down j k'
            on [:down, 'j'], :pick, 1, help: 'next knob', label: 'Up Down j k'
            on [:right, 'l'], :turn, KnobTurns::STEP, help: 'turn the knob up (held: a live sweep, one turn line)', label: 'Right l'
            on [:left, 'h'], :turn, -KnobTurns::STEP, help: 'turn the knob down (held: a live sweep, one turn line)', label: 'Left h'
            on [:right, :shift], :turn, KnobTurns::FINE, help: 'turn up, fine'
            on [:left, :shift], :turn, -KnobTurns::FINE, help: 'turn down, fine'
            on ['L'], :turn, KnobTurns::FINE, help: 'turn up, fine'
            on ['H'], :turn, -KnobTurns::FINE, help: 'turn down, fine'
            on '0', :reset, help: "the knob's default"
            on :enter, :ask, help: 'type a value (turn :cut, 3000.hz)', label: 'Enter'
            on 'e', :edit_line, help: PaneKeys::EDIT_HELP
            on 'y', :copy_text, help: "copy the pane's text (OSC 52)"
          end

          keys do
            group 'Knobs'
            doc 'Enter', 'pick and turn knobs (Esc back to NAV)'
          end

          def initialize = super(:knobs, rate: 15, height: 6, width: 28, title: 'knobs', description: 'session knobs: a meter of each one\'s position and its value; turn them from its keys')

          def draw_body(c, s, state)
            return unless s

            state[:snap] = s
            c = turn_line_canvas(c, state) if state[:mode]
            if s.knobs.empty?
              c.puts ['no knobs', :dim]
              return
            end
            name_w = [[s.knobs.map { |k| k.name.to_s.length }.max, 4].max, 8].min
            return draw_mode(c, s, state, name_w) if state[:mode]
            s.knobs.first(c.h).each_with_index do |k, y|
              spec = k.spec
              value = "#{Panes.fmt(k.value)}#{spec.unit ? " #{spec.unit}" : ''}"
              x = c.line(y, [c.pad(k.name, name_w), :name], ' ')
              mw = [c.w - x - value.length - 1, 3].max
              x = c.meter(spec.position(k.value).to_f, width: mw, x: x, y: y, role: :key)
              c.text(x + 1, y, value, :text)
            end
          end

          # Up/Down: the previous or next knob (a held gesture's line goes
          # out first).
          def key_pick(state, d)
            out = flush(state)
            n = state[:snap]&.knobs&.length.to_i
            state[:pick] = n == 0 ? 0 : (state[:pick].to_i + d).clamp(0, n - 1)
            k = n == 0 ? nil : state[:snap].knobs[state[:pick]]
            note = k ? "#{k.name} (Left Right turn, Enter a value, 0 default)" : 'no knobs'
            out.empty? ? note : [*out, note]
          end

          private

          # The rows in the mode: the picked knob reversed, scrolled into
          # view, the value a key set (or a held gesture's target, in the
          # queued color) over the snapshot's.
          def draw_mode(c, s, state, name_w)
            n = s.knobs.length
            pick = state[:pick] = state[:pick].to_i.clamp(0, n - 1)
            top = state[:top].to_i
            top = pick if pick < top
            top = pick - c.h + 1 if c.h > 0 && pick >= top + c.h
            state[:top] = top = top.clamp(0, [n - c.h, 0].max)
            s.knobs[top, c.h].each_with_index do |k, y|
              spec = k.spec
              v, turning = shown_value(state, k.name, k)
              value = "#{Panes.fmt(v)}#{spec.unit ? " #{spec.unit}" : ''}"
              sel = top + y == pick
              x = c.run(0, y, c.pad(k.name, name_w), sel ? :key : :name, reverse: sel)
              x = c.text(x, y, ' ')
              mw = [c.w - x - value.length - 1, 3].max
              x = c.meter(spec.position(v).to_f, width: mw, x: x, y: y, role: :key)
              c.text(x + 1, y, value, turning ? :queued : :text)
            end
          end

          def no_knob_note = 'no knobs to turn (knob :cut, 800, range: 100..8000)'

          def picked(state)
            knobs = state[:snap]&.knobs
            return nil if knobs.nil? || knobs.empty?
            k = knobs[state[:pick].to_i.clamp(0, knobs.length - 1)]
            [k.name, k]
          end
        end

        # Master meters: peak per channel (with a 1.5 s hold), RMS,
        # short-term loudness, and true peak.
        class Meters < Pane
          # Seconds a peak is held.
          HOLD = 1.5

          # Channel labels of a stereo master.
          LR = %w[L R].freeze

          def initialize = super(:meters, rate: 30, height: 6, width: 30, needs: [:meters], title: 'master', min_height: 4, description: 'master meters: peak with hold, RMS, short-term LUFS, true peak')

          def draw_body(c, s, state)
            m = s&.master
            if m.nil?
              c.puts ['no audio yet', :dim]
              return
            end

            # (text calls, held peaks updated in place, strings kept per
            # value: the same cells without garbage each frame; ui-perf-1)
            holds = (state[:holds] ||= [])
            n = m.peak.length
            rows = c.h - 2 < n ? c.h - 2 : n
            rows.times do |ch|
              peak = m.peak[ch]
              h = holds[ch]
              if h.nil?
                holds[ch] = h = [peak, s.time]
              elsif peak >= h[0] || s.time - h[1] > HOLD
                h[0] = peak
                h[1] = s.time
              end
              x = c.text(0, ch, n == 2 ? LR[ch] : (ch + 1).to_s, :dim)
              x = c.text(x, ch, -' ')
              mw = c.w - x - 6
              mw = 3 if mw < 3
              x = c.meter(Panes.db_frac(peak), width: mw, x: x, y: ch, zones: DB_ZONES, hold: Panes.db_frac(h[0]))
              c.text(x + 1, ch, Panes.db5(h[0]), h[0] > -1.0 ? :bad : :text)
            end
            y = rows
            x = c.text(0, y, -'S ', :dim)
            x = c.text(x, y, Panes.db(m.lufs_s), :key)
            x = c.text(x, y, -' LUFS  ', :dim)
            x = c.text(x, y, -'TP ', :dim)
            c.text(x, y, Panes.db(m.true_peak), m.true_peak > -1.0 ? :bad : :text)
            x = c.text(0, y + 1, -'RMS ', :dim)
            c.text(x, y + 1, rms_line(m.rms, state))
          end

          # The RMS values as one line ("-8.1 -9.2"), rebuilt only when a
          # value's text changed (Panes.db keeps one String per value).
          def rms_line(rms, state)
            parts = (state[:rms_parts] ||= [])
            same = parts.length == rms.length
            i = 0
            while i < rms.length
              t = Panes.db(rms[i])
              same = false unless parts[i].equal?(t)
              parts[i] = t
              i += 1
            end
            parts.pop while parts.length > rms.length
            return state[:rms_line] if same && state[:rms_line]
            state[:rms_line] = parts.join(' ').freeze
          end
        end

        # Warnings and live errors while the UI is up (UI.messages), newest
        # at the bottom, each wrapped to the pane's width with a hanging
        # indent beside its gutter (its number for `ui.message n`, and its
        # repeat count), errors in the bad color (ux-1 r3 item 38: long
        # warnings kept their important tail off screen).  Entries that
        # don't fit go off the top.
        #
        # In its mode the bottom message shown is the picked one (its
        # number reversed; Up/Down pick an older or newer one, scrolling),
        # and Enter opens it in full (`ui.message n`, the message pane; a
        # view, not a set change, so no console line runs: the pane returns
        # NAV's way of calling Tiles#message), e puts that line on the
        # console (ui-phase1-1, the plan's Phase 1 item 8).
        class Messages < Pane
          ROLES = { error: :bad, warn: :warn, note: :dim }.freeze

          mode_keys do
            group 'Messages'
            on [:up, 'k'], :scroll, 1, help: 'older, newer messages', label: 'Up Down'
            on [:down, 'j'], :scroll, -1, help: 'older, newer messages', label: ''
            on [:end, 'G'], :scroll, :newest, help: 'back to the newest', label: 'End'
            on :enter, :open_message, help: 'open the picked (bottom) message in full (ui.message n)', label: 'Enter'
            on 'e', :edit_line, help: PaneKeys::EDIT_HELP
            on 'y', :copy_text, help: 'copy the pane\'s text (OSC 52)'
          end

          # Enter: the picked message (the bottom one shown) in full.
          def key_open_message(state)
            n = picked_message(state) or return 'no messages to open'
            MB::Term::Input::Action.of(:message, n)
          end

          # e: `ui.message n` for the picked message (PaneKeys#key_edit_line).
          def edit_line(state)
            n = picked_message(state) or return 'no messages'
            PaneKeys::Run["ui.message #{n}"]
          end

          # The picked message's number (1: the newest), or nil without one.
          def picked_message(state)
            n = (state[:scroll].to_i + 1)
            UI.messages.recent(n).length >= n ? n : nil
          end

          # Scrolls back +by+ messages (positive: older), or to the newest.
          def key_scroll(state, by)
            n = UI.messages.recent(10_000).length
            state[:scroll] = by == :newest ? 0 : (state[:scroll].to_i + by).clamp(0, [n - 1, 0].max)
            state[:scroll] == 0 ? 'newest messages' : "#{state[:scroll]} newer message#{state[:scroll] == 1 ? '' : 's'} above... below (End: newest)"
          end

          def initialize = super(:messages, rate: 4, height: 6, width: 40, title: 'messages', min_height: 2, description: 'warnings and live errors while a screen is up, wrapped, numbered (ui.message n)')

          def draw_body(c, _s, state)
            skip = state ? state[:scroll].to_i : 0
            list = UI.messages.recent(c.h + skip).drop(skip)
            if list.empty?
              c.puts [skip > 0 ? 'no older warnings (Down: newer)' : 'no warnings', :dim]
              return
            end
            gutters = list.each_with_index.map { |e, i| "#{i + skip + 1}#{e.count > 1 ? " ×#{e.count}" : ''} " }
            gw = [gutters.map(&:length).max, c.w / 3].min
            # Newest first until the pane is full, then drawn oldest first
            blocks = []
            used = 0
            list.each_with_index do |e, i|
              lines = Canvas.wrap(e.text, c.w - gw)
              lines = lines.last(c.h - used) if used + lines.length > c.h && blocks.empty? # (the newest alone overflows: its tail)
              break if used + lines.length > c.h
              blocks << [gutters[i], lines, ROLES.fetch(e.severity, :warn)]
              used += lines.length
            end
            # From the top down, newest at the bottom (maintainer, 2026-10-18:
            # "would prefer starting from the top"); once full it scrolls
            y = 0
            last = blocks.length - 1
            i = 0
            blocks.reverse_each do |gutter, lines, role|
              # (in the mode, the picked one: the bottom block, reversed)
              state && state[:mode] && i == last ? c.run(0, y, gutter.rjust(gw)[0, gw], :key, reverse: true) : c.text(0, y, gutter.rjust(gw)[0, gw], :dim)
              lines.each_with_index { |l, k| c.text(gw, y + k, l, role) }
              y += lines.length
              i += 1
            end
          end
        end

        # One message in full (`ui.message n`: the newest is 1): wrapped to
        # the pane, with its count and age, the rest cut with an ellipsis
        # and a note of the lines left.
        class MessageDetail < Pane
          # Which message (1: the newest).
          attr_accessor :index

          def initialize
            super(:message, rate: 2, height: 10, width: 60, title: 'message detail', min_height: 3, description: 'one message in full (ui.message n opens it)')
            @index = 1
          end

          def draw_body(c, _s, _state)
            e = UI.messages.recent(@index)[@index - 1]
            unless e
              c.puts ["no message #{@index}", :dim]
              return
            end
            age = Process.clock_gettime(Process::CLOCK_MONOTONIC) - e.last
            c.puts ["##{@index} ", :key], [e.severity.to_s, MESSAGE_ROLES.fetch(e.severity, :warn)],
                   [e.count > 1 ? "  ×#{e.count}" : '', :dim], ["  #{age.round}s ago", :dim]
            c.wrap(e.text, y: 1, role: :text)
          end

          MESSAGE_ROLES = Messages::ROLES
        end

        # A page of text to read while the tiled screen is up (help pages:
        # Help.show opens them here through UI::Tiles#page; ux-fix-1):
        # scrolled with its own keys, q closes it.
        class Page < Pane
          mode_keys do
            group 'Page'
            on [:up, 'k'], :scroll, -1, help: 'scroll up, down a line', label: 'Up Down j k'
            on [:down, 'j'], :scroll, 1, help: 'scroll up, down a line', label: 'Up Down j k'
            on [:page_up, 'b'], :scroll, :page_up, help: 'scroll a page up, down', label: 'PgUp PgDn b Space'
            on [:page_down, ' '], :scroll, :page_down, help: 'scroll a page up, down', label: 'PgUp PgDn b Space'
            on [:home, 'g'], :scroll, :top, help: 'top, bottom', label: 'Home End g G'
            on [:end, 'G'], :scroll, :bottom, help: 'top, bottom', label: 'Home End g G'
            on '/', :find, help: 'search the page (n the next match, N the one before)', label: '/ n N'
            on 'n', :find_next, 1, help: 'search the page (n the next match, N the one before)', label: '/ n N'
            on 'N', :find_next, -1, help: 'search the page (n the next match, N the one before)', label: '/ n N'
            on 'y', :copy_text, help: 'copy the whole page (OSC 52)'
            on 'q', :close, help: 'close the page (back to what opened it)'
          end

          keys do
            group 'Page'
            doc 'Enter', 'read the page (Esc back to what opened it, q closes it)'
          end

          # The text's lines, and the first line shown.
          attr_reader :lines, :offset

          def initialize
            super(:page, rate: 4, height: 20, width: 80, title: 'page', min_height: 3,
                         description: 'a help page (or Pry\'s show-doc, show-source, cat) to read while the tiled screen is up: it takes the focus; Esc goes back, q closes it')
            @lines = [].freeze
            @offset = 0
            @rows = 1
            @find = nil
            @found = nil
          end

          # Shows +text+ from its top; +title+ is the pane's title (nil:
          # "page").
          def show(text, title: nil)
            @lines = text.to_s.lines.map(&:chomp).freeze
            @offset = 0
            @found = nil
            @title = title.to_s.empty? ? 'page' : title.to_s
            @title_text = nil
            self
          end

          # The whole page's text (what `y` copies).
          def full_text = @lines.join("\n")

          def draw_body(c, _s, state)
            @rows = [c.h - 1, 1].max
            @offset = @offset.clamp(0, [@lines.length - @rows, 0].max)
            @lines[@offset, @rows].to_a.each_with_index do |l, y|
              c.text_fit(0, y, l, c.w, :text)
            end
            last = [@offset + @rows, @lines.length].min
            status = "lines #{@offset + 1}-#{last} of #{@lines.length}#{@found ? "  /#{@find}" : ''}  " \
                     "#{state[:mode] ? 'j k PgUp PgDn g G, / search, y copy, Esc back, q closes' : 'Enter reads, q closes'}"
            c.text_fit(0, c.h - 1, status, c.w, :dim)
          end

          # / : the search prompt (its answer: #key_found).
          def key_find(_state) = PaneKeys::Ask['/', '', :found]

          # Scrolls to the first line from the top showing +text+ (a
          # case-insensitive substring).
          def key_found(_state, text)
            @find = text.to_s
            @found = nil
            return 'nothing to search for' if @find.empty?
            seek_match(0, 1)
          end

          # n / N: the next match after (before) the one shown.
          def key_find_next(_state, dir)
            return 'no search yet (/)' unless @find && !@find.empty?
            seek_match((@found || @offset) + dir, dir)
          end

          def key_scroll(_state, by)
            page = [@rows - 1, 1].max
            @offset = case by
                      when :page_up then @offset - page
                      when :page_down then @offset + page
                      when :top then 0
                      when :bottom then @lines.length
                      else @offset + by
                      end
            @offset = @offset.clamp(0, [@lines.length - @rows, 0].max)
            nil
          end

          def key_close(_state) = :close

          private

          # Shows the first line from +from+ (going +dir+, wrapping) that
          # holds the search text; a message if none does.
          def seek_match(from, dir)
            n = @lines.length
            return "not found: #{@find}" if n.zero?
            want = @find.downcase
            n.times do |k|
              i = (from + dir * k) % n
              next unless @lines[i].downcase.include?(want)
              @found = i
              @offset = (i - 1).clamp(0, [n - @rows, 0].max)
              return nil
            end
            "not found: #{@find}"
          end
        end

        # The console's last plot while the tiled screen is up (`plot`,
        # `spectrum`, `chart { }`, ...: Plot::Plotter.sink, Tiles#plot),
        # drawn at the pane's size (resizing redraws it), the REPL keeping
        # its rows and keys: a pane of its own rather than a mode of the
        # REPL pane, which hosts the console's terminal and is never
        # replaced (tuner-fixes-1).  q closes it.
        class PlotView < Pane
          mode_keys do
            group 'Plot'
            on 'q', :close, help: 'close the plot (ui.plot false)'
            on 'y', :copy_text, help: "copy the pane's text (OSC 52)"
          end

          def initialize
            super(:plot, rate: 4, height: 16, width: 80, title: 'plot', min_height: 4,
                         description: "the console's last plot (plot, spectrum, chart { }) while the tiled screen is up; the next plot replaces it, q or ui.plot false closes it")
            @figure = nil
            @seq = 0
          end

          # The figure shown (a Plot::Chart or Figure), or nil.
          attr_reader :figure

          # Shows +figure+ next.
          def show(figure)
            @figure = figure
            @seq += 1
            self
          end

          def plot?
            true
          end

          def draw(c, _s, state, look: nil)
            c.clear
            return if c.w <= 0 || c.h <= 0
            if @title && !state[:title_in_rule]
              c.text(0, 0, 'PLOT', :title)
              c = c.sub(0, 1, c.w, c.h - 1)
              return if c.h <= 0
            end
            unless @figure
              c.text_fit(0, 0, 'no plot yet (plot 440.hz.sine, chart { ... })', c.w, :dim)
              return
            end
            cells = c.grid.class
            lk = look == :auto || look.nil? ? :scope : look
            live = state[:live]
            if live.nil? || live.width != c.w || live.height != c.h || state[:cells] != cells || state[:look] != lk
              live = state[:live] = Plot::Live.new(width: c.w, height: c.h, look: lk, cells: cells)
              state[:cells] = cells
              state[:look] = lk
            end
            live.draw(@figure, c.grid, x: c.x, y: c.y)
          end

          def key_close(_state) = :close
        end

        # CPU per part: render load, then each player, bus, and master
        # chain by its share of the audio time.
        class CPU < Pane
          def initialize = super(:cpu, rate: 4, height: 6, width: 24, title: 'cpu', description: 'CPU per part: render load, each player, bus, and master chain')

          def draw_body(c, s, state)
            return unless s

            load, role = Panes.load_text(s.load)
            max, max_role = Panes.load_text(s.load_max)
            c.puts ['all ', :dim], [load.rjust(4), role], [' max ', :dim], [max, max_role]
            parts = s.parts.sort_by { |p| -p.load }
            name_w = [[parts.map { |p| p.name.to_s.length }.max.to_i, 4].max, 8].min
            parts.first(c.h - 1).each do |p|
              pct, prole = Panes.load_text(p.load)
              x = c.line(c.row, [c.pad(p.name, name_w), p.kind == :player ? :name : :title], ' ')
              mw = [c.w - x - 5, 2].max
              x = c.meter(p.load * 4, width: mw, x: x, y: c.row, role: prole) # full at 25%
              c.text(x + 1, c.row, pct.rjust(4), prole)
              c.row += 1
            end
          end
        end

        # A scope of the master mix through Plot::Live (look :auto by
        # default: Braille for short or wide panes, see .auto_look;
        # `ui look: :quad`, a layout's `pane :scope, look: :blocks`, or
        # `ui.look` on the focused pane to change it).  Draws its cells into
        # the screen's grid like every pane (never its own terminal bytes,
        # which would paint over overlays: ui-fix-3).
        class Scope < Pane
          # The looks `ui.look` cycles through, Braille first.
          LOOK_CYCLE = %i[scope quad blocks mosaic spark ascii].freeze

          # Rows up to which :auto picks Braille whatever the width.
          AUTO_BRAILLE_ROWS = 16

          # The look :auto means for a +w+ x +h+ pane: :scope (Braille, the
          # finest trace) for short or wide panes, :quad for tall narrow ones
          # (ux-1 r3 item 4; measured 2026-10-17: the same painter CPU as
          # :quad within noise, about 2x the bytes per scope frame, 1.9 kB
          # per written frame of :tiles at 120x40, ~56 kB/s at 30 frames/s,
          # far under a terminal's throughput).
          def self.auto_look(w, h)
            h <= AUTO_BRAILLE_ROWS || w >= 3 * h ? :scope : :quad
          end

          def initialize(name = :scope, look: nil)
            super(name, rate: 30, height: 6, width: 40, needs: [:scope], title: name.to_s, min_height: 3,
                        description: name == :spectrum ? 'the master mix\'s spectrum, log frequency with note names (look: Braille by default)' : 'a scope of the master mix (look: Braille by default; ui.look cycles)')
            @look = look
          end

          def plot?
            true
          end

          # Draws the plot into +c+'s rectangle of the screen grid, in the
          # pane's own look, else +look+ (the layout's or the screen's; :auto
          # by size).
          def draw(c, s, state, look: nil)
            w = c.w
            h = c.h
            return if w <= 0 || h <= 0
            cells = c.grid.class
            live = state[:live]
            lk = @look || look || :auto
            lk = Scope.auto_look(w, h) if lk == :auto
            if live.nil? || live.width != w || live.height != h || state[:cells] != cells || state[:look] != lk
              live = state[:live] = Plot::Live.new(width: w, height: h, look: lk, cells: cells)
              state[:cells] = cells
              state[:look] = lk
            end
            data = s&.scope
            data = state[:silence] ||= [Numo::SFloat.zeros(256)] if data.nil? || data.empty?
            rate = s&.sample_rate || 48000
            # (the same sample count, channels, and rate as the traced
            # chart: its lines again from the new samples, nothing allocated;
            # ui-perf-2.  Otherwise the chart, and a new trace of it.)
            return if traced? && state[:trace_rate] == rate && live.retrace(data, c.grid, x: c.x, y: c.y)
            ch = chart(data, rate)
            live.draw(ch, c.grid, x: c.x, y: c.y)
            if traced?
              live.trace(ch)
              state[:trace_rate] = rate
            end
          end

          # True for panes whose chart is plain lines of the samples (the
          # scope), which Plot::Live#retrace draws without a chart.
          def traced? = self.class == Scope

          private

          def chart(data, rate)
            Plot.chart(legend: false) { |c|
              c.x :time, sample_rate: rate
              c.y Plot::Scale::Linear.new(-1.0..1.0)
              data.each { |d| c.line d }
            }
          end
        end

        # The master mix's spectrum (log frequency with note names, -90..0
        # dBFS; a Hann-windowed FFT of the scope samples, channels mixed),
        # through Plot::Live like the scope.  `vis spectrum: true` shows it
        # while a UI is up.
        class Spectrum < Scope
          # dBFS at the bottom of the pane.
          FLOOR = -90.0

          def initialize(name = :spectrum, look: nil)
            super
            @rate = 15
          end

          private

          def chart(data, rate)
            mix = data.length == 1 ? data[0] : data.reduce { |a, b| a + b } * (1.0 / data.length)
            f, db = Plot::Presets.spectrum_db(mix, rate, FLOOR)
            Plot.chart(legend: false) { |c|
              c.x :frequency, 20.0..(rate / 2.0), notes: true
              c.y Plot::Scale::DB.new(FLOOR..0.0)
              c.line db, x: f
            }
          end
        end
      end
    end
  end
end
