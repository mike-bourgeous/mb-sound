module MB
  module Sound
    module UI
      # The tuner's screens (hand-tune-3; HandTune::Wizard): `ui :tuner`
      # for steps 1 and 2 (the tuner pane's lists), `ui :tuning` for step 3
      # (ui :sound with the tune strip: the keys for A/B, refine, notes,
      # retune, and the way back).  `tuner` and NAV h open it; `tuner off`
      # puts back the screen before.
      module TunerScreen
        # The tuner's layouts: steps 1-2, step 3.
        LAYOUTS = %i[tuner tuning].freeze

        class << self
          # The screen up before the tuner ([:tiles, name], [:band, name],
          # [:none]), for `tuner off`.
          attr_reader :before

          # Opens the tuner (HandTune::Wizard.open) and shows its step.
          # Returns the Wizard.
          def open(folder: nil)
            w = HandTune::Wizard.open(folder: folder)
            show(w)
            w
          end

          # Shows +w+'s step: ui :tuner (into the tuner pane) or, while
          # tuning, ui :tuning (into the inspector).  Nothing without a
          # terminal (a script, a pipe).
          def show(w = HandTune::Wizard.current)
            return nil unless w && terminal?
            t = UI.tiles
            now =
              if t&.active? then [:tiles, t.layout_name]
              elsif (b = UI.screen) then [:band, b.layout.name]
              else [:none]
              end
            @before = now unless @before || (now[0] == :tiles && (LAYOUTS + [:sound]).include?(now[1]))
            name = w.state == :tuning ? :tuning : :tuner
            screen = UI.show(name)
            pane = name == :tuner ? :tuner : :inspector
            screen.enter(pane) if screen.respond_to?(:enter) && screen.respond_to?(:tiler) && screen.tiler.layout.panes.include?(pane)
            screen
          end

          # Closes the tuner and puts back the screen before it.  Returns a
          # line saying so.
          def close
            w = HandTune::Wizard.current
            HandTune::Wizard.close
            was = @before
            @before = nil
            kind, name = was
            if UI.tiles&.active? && LAYOUTS.include?(UI.tiles.layout_name)
              case kind
              when :tiles, :band then UI.show(name)
              else UI.off
              end
            end
            plays = w&.tuned ? "; #{w.tuned.inspect} plays on (stop #{w.tuned.inspect})" : ''
            "tuner off: #{%i[tiles band].include?(kind) ? "back to ui #{name.inspect}" : 'ui off'}#{plays}"
          end

          # The layout `design` shows: the tuner's step 3 while a tuner line
          # tunes, else the sound screen.
          def design_layout
            HandTune::Wizard.current&.state == :tuning ? :tuning : :sound
          end

          private

          def terminal?
            $stdout.tty? || !UI.tiles.nil? || !UI.screen.nil?
          rescue StandardError
            false
          end
        end
      end

      module Panes
        # The tuner's steps 1 and 2 (HandTune::Wizard): the steps across
        # the top, the list of the step (references: their length and
        # summary; synths: what they are and, for the one under the cursor,
        # its comparison score), and the picked entry's details.  Enter
        # picks (step 2: runs its tune line), a listens, b (step 2) A/Bs the
        # synth with the reference, / finds, d another folder, e the line
        # onto the console, Esc a step back.
        class Tuner < Pane
          mode_keys do
            group 'Tuner'
            on [:up, 'k'], :pick, -1, help: 'previous, next entry', label: 'Up Down'
            on [:down, 'j'], :pick, 1, help: 'previous, next entry', label: 'Up Down'
            on :page_up, :pick, -10, help: 'a page up, down', label: 'PgUp PgDn'
            on :page_down, :pick, 10, help: 'a page up, down', label: 'PgUp PgDn'
            on :home, :pick, -100_000, help: 'first, last entry', label: 'Home End'
            on :end, :pick, 100_000, help: 'first, last entry', label: 'Home End'
            on :enter, :act, help: 'pick the reference; tune with the synth'
            on 'a', :audition, help: 'listen (the synth on its note; again: stop)'
            on 'b', :ab, help: 'A/B the synth with the reference'
            on '/', :find, help: 'find as you type (Esc: back)'
            on :backspace, :unfind, help: 'a letter less of the find'
            on 'd', :folder, help: 'another folder of references (remembered)'
            on 'r', :refresh, help: 'read the lists again'
            on 'e', :edit, help: 'the line onto the console to edit'
            on 'q', :quit, help: 'close the tuner (tuner off)'
            doc 'Esc', 'a step back (in step 1: NAV)'
          end

          def initialize = super(:tuner, rate: 8, height: 20, width: 80, title: 'tuner', min_height: 6,
                                         description: 'the tuner: pick a reference, then a synth to tune against it (tuner, NAV h)')

          def priority = :list

          # NAV h when the tuner isn't on screen: the tuner opens (Tiles#jump).
          def jump_to_screen(_tiles)
            w = TunerScreen.open
            "tuner step #{w.step}: #{w.state == :synth ? 'a synth' : w.state == :tuning ? 'tuning' : 'a reference'}"
          end

          def wizard = HandTune::Wizard.current

          def enter_hint(_state)
            w = wizard or return nil
            x = w.under_cursor or return nil
            case w.state
            when :reference then "pick #{x.name}: then a synth to pair it with (step 2)"
            when :synth
              x.problem ? "#{x.name} can't load: #{x.problem}" : "tune #{w.track.inspect} with #{x.name} against #{w.ref.name}#{x.ears ? ' (by ear: no retune or refine)' : ''}"
            end
          end

          def draw_body(c, s, state)
            state[:snap] = s
            w = wizard
            unless w
              c.text(0, 0, c.fit('the tuner is closed: tuner (or NAV h) opens it', c.w), :dim)
              return
            end
            draw_steps(c, w)
            return if c.h < 3
            draw_find(c, 1, w, state)
            list = w.shown
            detail = c.h >= 14 ? 5 : c.h >= 9 ? 2 : 0
            rows = [c.h - 2 - detail, 1].max
            pick = list.empty? ? 0 : w.cursor[w.state].to_i.clamp(0, list.length - 1)
            w.cursor[w.state] = pick
            tops = (state[:tops] ||= {})
            top = tops[w.state].to_i
            top = pick if pick < top
            top = pick - rows + 1 if pick >= top + rows
            top = tops[w.state] = top.clamp(0, [list.length - rows, 0].max)
            if list.empty?
              c.text(0, 2, c.fit(empty_text(w), c.w), :dim)
            else
              shown = list[top, rows]
              width = [shown.map { |x| x.name.to_s.length }.max.to_i + 1, (c.w * 0.45).to_i].min
              shown.each_with_index { |x, i| draw_row(c, 2 + i, w, x, width, top + i == pick, state) }
              # (the cursor's entry last: the background works on it first)
              w.state == :synth ? want_score(w, list[pick], state) : w.summary(list[pick])
              c.text(c.w - 8, 1 + rows, " +#{list.length - top - rows} ", :dim) if top + rows < list.length && c.w > 14
            end
            draw_detail(c, c.h - detail, w, list[pick], detail) if detail > 0 && !list.empty?
          end

          # The steps line: 1 reference > 2 synth > 3 tune, the step shown
          # reversed, what was picked beside the steps done.
          def draw_steps(c, w)
            x = 0
            [[:reference, '1 reference'], [:synth, '2 synth'], [:tuning, '3 tune']].each_with_index do |(st, label), i|
              x = c.text(x, 0, ' › ', :dim) if i > 0
              on = w.state == st
              x = c.run(x, 0, " #{label} ", on ? :key : :dim, reverse: on)
              x = c.text(x, 0, " #{w.ref.name}", :name) if st == :reference && w.ref && w.state != :reference
              x = c.text(x, 0, " #{w.synth.name}", :name) if st == :synth && w.synth && w.state == :tuning
            end
            right = w.state == :reference ? " #{w.folder}" : " track #{w.track.inspect}"
            c.text([c.w - right.length, x + 1].max, 0, c.fit(right, [c.w - x - 1, 0].max), :dim) if c.w - x > 12
          end

          def draw_find(c, y, w, state)
            q = w.query[w.state].to_s
            n = w.shown.length
            if state[:finding]
              c.line(y, ['find ', :key], [q, :text], ['▏', :key], ["  (#{n})", :dim])
            elsif !q.empty?
              c.line(y, ['find ', :dim], [q, :text], [" (#{n}; Backspace: less)", :dim])
            elsif w.state == :reference
              c.text(0, y, c.fit(state[:mode] ? "#{n} references: Enter pick  a listen  / find  d folder  r again  Esc NAV" : "#{n} references (in: NAV h, or Enter on this pane)", c.w), :dim)
            else
              note = Note.new(w.note.to_i).name rescue '?'
              c.text(0, y, c.fit(state[:mode] ? "#{n} synths on #{note}: Enter tune  a listen  b A/B  / find  e edit the line  Esc back" : "#{n} synths (in: NAV h)", c.w), :dim)
            end
          end

          def empty_text(w)
            q = w.query[w.state].to_s
            return "no match for '#{q}' (Backspace)" unless q.empty?
            w.state == :reference ? "no references: the queue (#{HandTune::Wizard.queue_dir}) and #{w.folder} have no sound files; d lists another folder" : 'no synths'
          end

          # A row: the cursor, the kind, the name, the length or score, the
          # summary or what the synth is.
          def draw_row(c, y, w, x, width, on, state)
            c.run(0, y, on ? '▸' : ' ', :key)
            kind = w.state == :reference ? KIND_MARKS[x.kind] : SYNTH_MARKS[x.kind]
            c.text(1, y, kind.to_s, :dim)
            role = x.respond_to?(:problem) && x.problem ? :dim : (on ? :key : :name)
            col = c.run(3, y, c.pad(x.name.to_s, width), role, reverse: on && state[:mode])
            col += 1
            if w.state == :reference
              secs = x.seconds ? format('%5.2f s', x.seconds) : '    ? s'
              col = c.text(col, y, secs, :dim) + 2
              sm = w.summary(x)
              txt = sm ? sm.to_s : '…'
              c.text(col, y, c.fit(txt, [c.w - col, 0].max), sm&.error ? :warn : :text)
            else
              sc = w.score(x, want: false)
              score = sc.is_a?(HandTune::Wizard::Score) && sc.total ? format('L3 %5.2f', sc.total) : (sc.is_a?(HandTune::Wizard::Score) && sc.error ? 'L3   err' : '        ')
              col = c.text(col, y, score, sc&.total ? :ok : :dim) + 2
              about = x.problem ? "can't load: #{x.problem}" : x.about.to_s
              c.text(col, y, c.fit(about, [c.w - col, 0].max), x.problem ? :warn : :dim)
            end
          end

          KIND_MARKS = { queue: 'q', file: 'f', sample: 's' }.freeze
          SYNTH_MARKS = { queue: 'q', fit: 'f', init: 'i', blank: 'b', library: 'L' }.freeze

          # The score of the synth under the cursor, asked for once the
          # cursor stayed on it HandTune::Wizard::SCORE_DWELL seconds.
          def want_score(w, x, state)
            return unless x
            now = MB::U.clock_now
            if state[:dwell_on] != x
              state[:dwell_on] = x
              state[:dwell_at] = now
            end
            w.score(x) if now - state[:dwell_at] >= HandTune::Wizard::SCORE_DWELL
          end

          # The picked entry's details in the last +rows+ rows.
          def draw_detail(c, y, w, x, rows)
            return unless x
            c.text(0, y, c.glyph(:hrule) * c.w, :dim)
            lines =
              if w.state == :reference
                sm = w.summary(x, want: false)
                [x.path, x.about.to_s, sm ? "#{sm}#{sm.seconds ? " (#{format('%.2f', sm.seconds)} s read)" : ''}" : 'reading the sound in the background…']
              else
                sc = w.score(x, want: false)
                score =
                  if sc.is_a?(HandTune::Wizard::Score) && sc.total
                    "L3 #{format('%.3f', sc.total)} against #{w.ref.name} (lower is closer), one note #{format('%.1f', sc.lufs)} LUFS (#{sc.ms} ms)"
                  elsif sc.is_a?(HandTune::Wizard::Score)
                    "no score: #{sc.error}"
                  else
                    'scored once the cursor stays on it (a render and a comparison in the background)'
                  end
                line = begin
                  x.problem ? "can't load: #{x.problem}" : w.tune_line(x).gsub(/\s*\n\s*/, ' ')
                rescue StandardError => e
                  "#{e.class}: #{e.message}"
                end
                [x.about.to_s, score, line]
              end
            room = rows - 1
            lines.each_with_index do |l, i|
              break if i >= room
              last = i == room - 1
              if last && lines.length > i + 1
                c.wrap(lines[i..].join('  '), y: y + 1 + i, rows: 1, role: :dim)
              elsif i == lines.length - 1 && room - i > 1
                c.wrap(l, y: y + 1 + i, rows: room - i, role: :text)
              else
                c.text(0, y + 1 + i, c.fit(l, c.w), i.zero? ? :text : :dim)
              end
            end
          end

          def key_pick(_state, d)
            w = wizard or return closed_note
            n = w.shown.length
            w.cursor[w.state] = (w.cursor[w.state].to_i + d).clamp(0, [n - 1, 0].max)
            nil
          end

          def key_act(state)
            w = wizard or return closed_note
            state[:finding] = false
            x = w.under_cursor or return 'nothing picked'
            case w.state
            when :reference
              w.pick(x)
              "step 2: #{w.synths.length} synths for #{x.name} (track #{w.track.inspect})"
            when :synth
              return "#{x.name} can't load: #{x.problem}" if x.problem
              w.pick(x)
              state[:tuning] = true
              PaneKeys::Run[w.line, "tune #{w.track.inspect}: #{x.name} against #{w.ref.name}"]
            end
          end

          # After the tune line ran: on to step 3 if it set up the track,
          # else back to step 2.
          def lines_ran(state)
            return unless state.delete(:tuning)
            w = wizard or return
            return unless w.state == :tuning
            if w.tuned == w.track
              TunerScreen.show(w) unless UI.tiles&.layout_name == :tuning
            else
              w.back
            end
          end

          def key_audition(state)
            w = wizard or return closed_note
            x = w.under_cursor or return 'nothing picked'
            line = w.audition_line(x) or return "#{x.name}: nothing to listen to before it loads"
            return audition_off(state) if state[:auditioned] == line && auditioning?(state)
            state[:auditioned] = line
            state[:ab] = nil
            PaneKeys::Run[line, "listening to #{x.name}"]
          end

          def key_ab(state)
            w = wizard or return closed_note
            return 'A/B is for step 2 (a synth against the reference)' unless w.state == :synth
            x = w.under_cursor or return 'nothing picked'
            if state[:ab] == :ref
              state[:ab] = :synth
              line = w.audition_line(x) or return "#{x.name}: nothing to listen to"
              PaneKeys::Run[line, "B: #{x.name} on its note (b: the reference)"]
            else
              state[:ab] = :ref
              matched = w.score(x, want: false)&.lufs
              PaneKeys::Run[w.audition_line(w.ref, match: x), "A: the reference#{matched ? ' matched to the synth' : ''} (b: #{x.name})"]
            end
          end

          def key_find(state)
            w = wizard or return closed_note
            state[:finding] = true
            state[:was] = w.query[w.state].to_s
            PaneKeys::Ask['find: ', w.query[w.state].to_s, :found, changed: :finding]
          end

          def key_finding(_state, text)
            w = wizard or return nil
            w.query[w.state] = text.to_s
            w.cursor[w.state] = 0
            nil
          end

          def key_found(state, text)
            state[:finding] = false
            key_finding(state, text)
            n = wizard&.shown&.length.to_i
            "#{n} match#{'es' unless n == 1}"
          end

          def key_unfind(_state)
            w = wizard or return closed_note
            w.query[w.state] = w.query[w.state].to_s[0...-1]
            w.cursor[w.state] = 0
            nil
          end

          def key_folder(_state)
            w = wizard or return closed_note
            return 'a folder is for step 1 (Esc: back to it)' unless w.state == :reference
            PaneKeys::Ask['folder: ', w.folder, :folder_given]
          end

          def key_folder_given(_state, text)
            w = wizard or return closed_note
            dir = File.expand_path(text.to_s.strip)
            return "no folder #{dir}" unless File.directory?(dir)
            w.folder = dir
            "#{w.refs.length} references (#{dir}, remembered)"
          end

          def key_refresh(_state)
            w = wizard or return closed_note
            w.refresh
            "#{w.refs.length} references read again"
          end

          def key_edit(_state)
            w = wizard or return closed_note
            x = w.under_cursor or return 'nothing picked'
            line = w.state == :synth && !x.problem ? w.tune_line(x) : w.audition_line(x)
            return 'nothing to edit' unless line
            PaneKeys::Paste[line, 'on the console: edit it, Enter runs it']
          end

          def key_quit(_state) = TunerScreen.close

          # Esc in the pane's mode: a step back (step 2: the references);
          # nil in step 1 (the screen goes to NAV).
          def key_escape(state)
            w = wizard or return nil
            return nil unless w.state == :synth
            state[:ab] = nil
            w.back
            "step 1: the references (#{w.ref&.name} kept)"
          end

          def full_text(_state)
            w = wizard or return ''
            w.shown.map { |x| "#{x.name}\t#{x.respond_to?(:path) ? x.path : x.about}" }.join("\n")
          end

          private

          def closed_note = 'the tuner is closed (tuner, or NAV h)'

          def auditioning?(state)
            s = state[:snap]
            s && s.players.any? { |p| %i[audition audition/cue].include?(p.name) }
          end

          def audition_off(state)
            state[:auditioned] = nil
            PaneKeys::Run['audition off', 'stopped']
          end
        end

        # The tuner's step 3 strip (ui :tuning, above the sound screen):
        # what is tuned against what, what is heard, refine's progress, and
        # the inspector's hand-tune keys (from its keymap, so they can't
        # drift).
        class TuneStrip < Pane
          # The inspector's actions the strip names, in order.
          ACTIONS = %i[ab refine apply retune note tuner_back tuner_restart].freeze

          def initialize = super(:tune_strip, rate: 4, height: 2, width: 80, title: 'tune', description: 'the tuner\'s step 3: the reference, what is heard, refine, and the hand-tune keys')

          def priority = :list

          # [[label, help], ...] of the inspector's hand-tune keys.
          def self.keys
            map = Inspector.mode_keymap
            ACTIONS.filter_map { |a|
              b = map.entries.find { |e| e.action == a } or next
              [MB::Term::Input::Keymap.keys_name(b.keys), b.help.to_s]
            }
          end

          SHORT = { ab: 'A/B', refine: 'refine', apply: 'apply', retune: 'retune', note: 'note', tuner_back: 'synths', tuner_restart: 'references' }.freeze

          def draw_body(c, _s, _state)
            w = HandTune::Wizard.current
            session = w&.session || Session.existing
            track = w&.tuned || (UI::Inspect.target.is_a?(Hash) ? UI::Inspect.target[:track] : nil)
            pair = track && session ? Reference.pairs(session)[track] : nil
            x = c.run(0, 0, ' TUNE ', :key, reverse: true)
            if track
              x = c.line(0, [" #{track}", :name], [' vs ', :dim], [pair ? File.basename(pair.source.to_s) : 'no reference', pair ? :name : :warn], x: x)
              heard = pair ? { patch: 'the patch', ref: 'the reference', alt: 'the refined copy' }[pair.hearing] : nil
              x = c.line(0, ['  hearing ', :dim], [heard.to_s, :ok], x: x) if heard
              ref_state = refine_text(session, track)
              x = c.line(0, ['  ', :dim], [ref_state, :text], x: x) if ref_state
            else
              x = c.text(x, 0, ' nothing tuned yet (tuner: pick a reference and a synth)', :dim)
            end
            keys = TuneStrip.keys.zip(ACTIONS).map { |(k, _), a| "#{k} #{SHORT[a]}" }.join('  ')
            if c.h >= 2
              c.text(0, 1, c.fit("keys (inspector): #{keys}  Esc NAV", c.w), :dim)
            else
              c.text(x + 2, 0, c.fit(keys, [c.w - x - 2, 0].max), :dim)
            end
          end

          # refine's state for +track+ in one phrase, or nil.
          def refine_text(session, track)
            r = session && HandTune.refinements[session]
            return nil unless r && r.track == track
            case r.state
            when :running, :new
              e, best, start, t = r.progress
              e ? "refine #{format('%.0f', t)} s: #{e} evals, loss #{format('%.3f', start)} → #{format('%.3f', best)}" : 'refine starting…'
            when :failed then "refine failed: #{r.error.to_s[0, 40]}"
            else
              pr = r.proposal || {}
              pr.empty? ? 'refine: nothing moved' : "refine proposes #{pr.length} knob#{'s' unless pr.length == 1} (R: A/B it, A: apply)"
            end
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
