module MB
  module Sound
    module UI
      # The library picker of `ui :sound` (ui-scaffold-1, the design's
      # sd-picker; design/notes/sound_design_ui.md, The library picker):
      # the library index under one head at a time (L.inst, L.fx, ...),
      # narrowed as you type by the console popup's ranking
      # (Library::Finder: the words typed become a head chain, "dnb ree" is
      # L.inst.dnb.ree; when a word doesn't narrow, Index#find's), an entry
      # auditioned (`audition L.inst.x`: CUE when the output has it, else
      # MAIN at -6 dB) or loaded into the inspected track (`track :bass,
      # L.inst.x`, at its launch point), every action a console line.
      # This module is the part without a screen: results, and what each
      # entry's actions are.
      module Picker
        # The heads in the order the picker shows them (Library::HEADS
        # with entries, then :all).
        ORDER = %i[inst fx kit seq gen flow master env set edit mfx analyze mod].freeze

        # How long results are kept before the index is read again (a save
        # or a shelf change shows within this).
        KEEP = 2.0

        # What Enter (or a key) does with an entry: +kind+ :run (a console
        # line run: journaled, undoable), :paste (a line put on the
        # console to edit), :audition; +code+ the line, +note+ what it does
        # (the status line names it before Enter is pressed).
        Action = Data.define(:kind, :code, :note)

        module_function

        # The index the picker reads (Library.index; specs give a fixed one).
        def index = Library.index

        # The head path of +entry+ (Entry#head_path in the picker's index;
        # kept KEEP seconds: a head path reads the whole index, ~6 ms on the
        # shipped library, and the status line asks for Enter's action every
        # frame).
        def path_of(entry)
          c = cache
          CACHE_LOCK.synchronize { c[:paths][entry] ||= entry.head_path(index).freeze }
        end

        # The heads that have entries now, in ORDER, then :all (kept KEEP
        # seconds).
        def heads
          c = cache
          CACHE_LOCK.synchronize {
            c[:heads] ||= begin
              kinds = index.entries.map(&:kind).uniq
              (ORDER.select { |h| kinds.include?(Library::HEADS[h]) } + [:all]).freeze
            end
          }
        end

        CACHE_LOCK = Mutex.new

        # What #heads and #path_of keep: renewed when KEEP seconds old or
        # the index is another one.
        def cache
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          idx = index
          CACHE_LOCK.synchronize {
            c = @cache
            if c.nil? || now - c[:at] > KEEP || !c[:index].equal?(idx)
              c = @cache = { at: now, index: idx, heads: nil, paths: {}.compare_by_identity }
            end
            c
          }
        end

        # The entries under head +head+ (a Library::HEADS key or :all)
        # matching +query+ (words typed; spaces or dots between them), best
        # first, at most +limit+.  Empty: every entry under the head, by
        # name.
        def results(head, query, limit: 200)
          root = "L.#{head}"
          q = query.to_s.downcase.strip
          words = q.split(/[\s.]+/).reject(&:empty?)
          typed = query.to_s =~ /[\s.]\z/ || words.empty? ? '' : words.pop
          text = [root, *words].join('.') + ".#{typed}"
          found = Library::Finder.new(index).candidates(text, limit: limit)
          return found.filter_map(&:entry) if found
          # (an exact name: Finder leaves it to Pry; a word that doesn't
          # narrow: find's ranking over the head)
          exact = walk(head, [*words, typed].reject(&:empty?))
          return [exact] if exact.is_a?(Library::Entry)
          return exact.entries.first(limit) if exact.is_a?(Library::Heads::Query)
          return [] if q.empty?
          index.find(q, kind: Library::HEADS[head], limit: limit).entries
        end

        # What head +head+ and +words+ reach (an Entry, a Query), or nil.
        def walk(head, words)
          kind = head == :all ? nil : Library::HEADS.fetch(head)
          node = Library::Heads::Query.new(kind, path: "L.#{head}", pool: index.entries(kind: kind))
          words.each do |w|
            return nil unless node.is_a?(Library::Heads::Query)
            node = node.word(w.to_sym)
          end
          node
        rescue KeyError, ArgumentError
          nil
        end

        # Enter's action for +entry+ with +track+ the inspected track (nil
        # for none); +patch+ is true when +track+ is a track with a patch
        # (one `track :x, L.inst.y` can give another instrument).
        def action(entry, track:, patch: false)
          path = path_of(entry)
          t = track&.inspect
          case entry.kind
          when :instrument, :kit
            return audition(entry) unless track
            return Action.new(:run, "track #{t}, #{path}", "#{track} plays #{entry.name} from its launch point (knobs you turned carry; undo takes it back)") if patch
            Action.new(:paste, "track #{t}, #{path}; bg #{t}, clip",
                       "#{track} isn't a track with a patch (bg played it): edit the clip, Enter runs it")
          when :clip, :generator
            return audition(entry) unless track
            # (a generator bare: the track's knobs steer it; gen-knobs-1)
            gen = entry.kind == :generator
            Action.new(:run, "bg #{t}, #{path}#{'.()' unless gen}", "#{track} plays #{entry.name} from its launch point#{gen ? " (its params #{track}'s knobs)" : ''}")
          when :flow
            Action.new(:paste, "flow #{path}", "#{entry.name} is a section chain: the flow that plays it over this set's scenes onto the console")
          when :effect
            # (a patch track's effect insert, at its launch point: Arrangement::Fx)
            return Action.new(:run, "fx #{t}, #{path}", "#{track}'s effect becomes #{entry.name} at its launch point (its notes play on; undo takes it back)") if track && patch
            bus = entry.name.inspect
            feed = track ? "; feed #{t}, #{bus}, -12.db" : ''
            Action.new(:paste, "bus(#{bus}) { |sig| sig.then(&#{path}) }#{feed}",
                       "effects go on a bus#{track ? " #{track} feeds" : ''} (or a patch track's fx): the line onto the console to edit")
          when :master
            code = entry.family == :mastering ? "master #{entry.name.inspect}" : "master { |mix| mix.then(&#{path}) }"
            Action.new(:paste, code, 'a mastering chain ends the master: the line onto the console to edit')
          when :set
            Action.new(:paste, "preset #{entry.name.inspect}", "#{entry.name} is a set: the line that loads it (tracks, scenes, flow) onto the console")
          else
            Action.new(:paste, (entry.to_ruby rescue path).to_s, "#{entry.name} (#{entry.label}): its code onto the console")
          end
        end

        # The audition Action for +entry+.
        def audition(entry)
          Action.new(:audition, "audition #{path_of(entry)}", "audition #{entry.name}")
        end
      end

      module Panes
        # The library picker (ui-scaffold-1; see UI::Picker): heads across
        # the top (Tab or Left/Right), the entries under the head as you
        # type (/), the inspected track's instrument marked, the picked
        # entry's description, tags, and params below.  Enter does the
        # likely action named on the status line (an instrument or kit:
        # load it into the inspected track; a clip: play it there; an
        # effect: its bus line onto the console; nothing inspected: an
        # audition), a auditions (again: stops), e puts the action's line
        # on the console to edit, t T pick the track (as the inspector's
        # t T).  Every action is a console line (journaled, undoable, in
        # the take).
        class Picker < Pane
          jump 'l'

          mode_keys do
            group 'Library'
            on [:up, 'k'], :pick, -1, help: 'previous, next entry', label: 'Up Down'
            on [:down, 'j'], :pick, 1, help: 'previous, next entry', label: 'Up Down'
            on :page_up, :pick, -10, help: 'a page up, down', label: 'PgUp PgDn'
            on :page_down, :pick, 10, help: 'a page up, down', label: 'PgUp PgDn'
            on [:tab, :right, 'l'], :head, 1, help: 'next, previous head (inst fx kit ... all)', label: 'Tab Left Right'
            on [[:tab, :shift], :left, 'h'], :head, -1, help: 'next, previous head (inst fx kit ... all)', label: 'Tab Left Right'
            on '/', :find, help: 'find as you type (dnb ree; Esc: back)'
            on :backspace, :unfind, help: 'a letter less of the find'
            on :enter, :act, help: 'the likely action (the status line names it)'
            on 'a', :audition, help: 'audition (CUE, else MAIN -6 dB; again: stop)'
            on 'e', :edit, help: "the action's line onto the console to edit"
            on 't', :track, 1, help: 'next, previous track to load into', label: 't T'
            on 'T', :track, -1, help: 'next, previous track to load into', label: 't T'
            on 'q', :quit, help: 'away (when NAV l put it in)'
          end

          def initialize = super(:picker, rate: 8, height: 10, width: 30, needs: [:inspect], title: 'library', min_height: 3,
                                          description: 'the library picker: heads, find as you type, audition (a), load into the inspected track (Enter)')

          def priority = :list

          # 12 rows beside the inspector when the layout lacks the picker
          # (ui :sound at 80x24).
          def temporary_rows(names) = names.include?(:inspector) ? 12 : nil

          # The head shown (state[:head], else :inst).
          def head(state) = state[:head] || :inst

          # The results for the state's head and find, kept KEEP seconds.
          def results(state)
            # (compared in place: drawing asks several times a frame)
            h = head(state)
            q = state[:query].to_s
            idx = UI::Picker.index.__id__
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            r = state[:results]
            return r[2] if r && r[0] == h && r[3] == q && r[4] == idx && now - r[1] < UI::Picker::KEEP
            list = UI::Picker.results(h, state[:query]).freeze
            state[:results] = [h, now, list, q.frozen? ? q : q.dup.freeze, idx]
            list
          end

          # The picked Entry, or nil.
          def picked(state)
            list = results(state)
            list.empty? ? nil : list[state[:pick].to_i.clamp(0, list.length - 1)]
          end

          # #target without one.
          NO_TARGET = [nil, false].freeze

          # [track name, patch track?] the picker loads into: the inspected
          # track (the inspector's, which t T move), or [nil, false].
          def target(state)
            s = state[:snap]
            t = s&.inspector&.track
            return NO_TARGET unless t
            # (kept while the poll's tracks and the track stay: the status
            # line asks every frame)
            m = state[:target]
            return m[2] if m && m[0].equal?(s.tracks) && m[1].equal?(t)
            tr = s.tracks.find { |x| x.name == t }
            pair = [t, tr && tr.clip != 'graph' ? true : false].freeze
            state[:target] = [s.tracks, t, pair]
            pair
          end

          # Enter's Action for the picked entry, or nil (kept while the
          # entry and the target stay: the status line asks every frame).
          def action(state)
            e = picked(state) or return nil
            t, patch = target(state)
            a = state[:action]
            return a[1] if a && a[0].equal?(e) && a[2] == t && a[3] == patch
            act = UI::Picker.action(e, track: t, patch: patch)
            state[:action] = [e, act, t, patch]
            act
          end

          def enter_hint(state)
            a = action(state) or return nil
            # (the note itself when a String: "#{note}" made one a frame)
            a.kind == :paste && !a.note.is_a?(String) ? "#{a.note}" : a.note
          end

          def draw_body(c, s, state)
            state[:snap] = s
            draw_heads(c, state)
            return if c.h < 2
            draw_find(c, 1, state)
            list = results(state)
            detail = c.h >= 12 ? 4 : 0
            rows = c.h - 2 - detail
            # (a longer list gives its last row to "+N more", never over an
            # entry's text; sd-ux-fixes-1, the review's #23: "dn +48")
            rows -= 1 if list.length > rows && rows > 1
            pick = state[:pick] = list.empty? ? 0 : state[:pick].to_i.clamp(0, list.length - 1)
            top = state[:top].to_i
            top = pick if pick < top
            top = pick - rows + 1 if pick >= top + rows
            top = state[:top] = top.clamp(0, [list.length - rows, 0].max)
            if list.empty?
              c.text_fit(0, 2, state[:query].to_s.empty? ? "nothing under L.#{head(state)}" : "no match for '#{state[:query]}' under L.#{head(state)} (Tab: other heads)", c.w, :dim)
            else
              playing = playing_entry(s)
              # (no slices or Arrays per draw)
              last = [top + rows, list.length].min
              width = 0
              i = top
              while i < last
                l = list[i].name.length
                width = l if l > width
                i += 1
              end
              width = [width, c.w / 2 + 2].min
              i = top
              while i < last
                draw_entry(c, 2 + i - top, list[i], width, i == pick, state, playing)
                i += 1
              end
              c.text_fit(0, 2 + rows, "  +#{list.length - top - rows} more", c.w, :dim) if top + rows < list.length
            end
            draw_detail(c, c.h - detail, picked(state)) if detail > 0 && !list.empty?
          end

          # The Entry the target track plays now (to mark), or nil.
          def playing_entry(s)
            t = s&.inspector&.track or return nil
            s.tracks.find { |x| x.name == t }&.instrument
          end

          # The heads line: the shown head reversed, the target at the
          # right (→ bass).
          def draw_heads(c, state)
            hs = UI::Picker.heads
            cur = head(state)
            t, = target(state)
            right = t ? c.fit(" → #{t}", [c.w / 2, 4].max) : ''
            room = c.w - right.length
            # (start so the current head shows on a narrow pane)
            i = hs.index(cur) || 0
            first = 0
            first += 1 while first < i && hs[first..i].sum { |h| h.length + 1 } > room
            x = 0
            hs[first..].each do |h|
              break if x + h.length > room
              x = h == cur ? c.run(x, 0, h, :key, reverse: state[:mode]) : c.text(x, 0, h.to_s, :dim)
              x += 1
            end
            c.text(c.w - right.length, 0, right, :name) unless right.empty?
          end

          def draw_find(c, y, state)
            q = state[:query].to_s
            if state[:finding]
              c.line(y, ['find ', :key], [q, :text], ['▏', :key])
            elsif q.empty?
              c.text_fit(0, y, state[:mode] ? '/ find  a listen  Enter load  e edit' : '/ find (in: NAV l)', c.w, :dim)
            else
              c.line(y, ['find ', :dim], [q, :text], [" (#{results(state).length})", :dim])
            end
          end

          # One entry's row: the cursor, ● for the track's instrument, the
          # name, then its family (its kind under L.all; nothing for
          # presets, whose head says what they are) and tags.
          def draw_entry(c, y, e, width, on, state, playing)
            c.run(0, y, on ? '▸' : ' ', :key)
            c.run(1, y, playing && playing.family == e.family && playing.name == e.name ? '●' : ' ', :ok)
            name = e.name
            x = c.run_pad(2, y, name.is_a?(Symbol) ? name.name : name.to_s, width, on ? :key : :name, reverse: on && state[:mode])
            c.text_fit(x + 1, y, entry_words(e, head(state) == :all), [c.w - x - 1, 0].max, :dim)
          end

          # An entry's family (its kind under L.all) and first tags, kept
          # per entry (drawn every frame).
          def entry_words(e, all)
            hit = WORDS[e]
            return hit[1] if hit && hit[0] == all
            what = all ? e.kind.to_s : (e.family == :preset ? nil : e.family.to_s)
            words = [what, *e.tags.first(3)].compact.join(' ').freeze
            WORDS[e] = [all, words].freeze
            words
          end

          # The picked entry's description, tags and params, and where it
          # comes from, in the last 4 rows.
          def draw_detail(c, y, e)
            return unless e
            # (the texts kept per entry and width: drawn every frame)
            d = DETAILS[e]
            unless d && d[0] == c.w
              about = e.about.to_s.empty? ? "#{e.label}" : e.about.to_s
              params = e.params.keys rescue []
              words = []
              words << "tags #{e.tags.join(' ')}" unless e.tags.empty?
              words << "params #{params.join(' ')}" unless params.empty?
              # (Canvas#wrap's first row of one: cut with an ellipsis when
              # more would follow)
              lines = Canvas.wrap(about, c.w)
              line = lines[0]
              if lines.length > 1
                last = line.chomp(Canvas::BREAK)
                line = last.length >= c.w ? "#{last[0, c.w - 1]}…" : "#{last}…"
              end
              d = DETAILS[e] = [c.w, ('─' * c.w).freeze, line.freeze, words.join('  ').freeze, "#{UI::Picker.path_of(e)}  #{e.shelf&.name}".freeze].freeze
            end
            c.text(0, y, d[1], :dim)
            c.text(0, y + 1, d[2], :text)
            c.row = y + 2
            c.text_fit(0, y + 2, d[3], c.w, :dim)
            c.text_fit(0, y + 3, d[4], c.w, :dim)
          end

          # #entry_words and #draw_detail's texts by entry (weak, by identity).
          WORDS = ObjectSpace::WeakMap.new
          DETAILS = ObjectSpace::WeakMap.new

          def key_pick(state, d)
            state[:pick] = state[:pick].to_i + d
            nil
          end

          def key_head(state, d)
            hs = UI::Picker.heads
            i = hs.index(head(state)) || 0
            state[:head] = hs[(i + d) % hs.length]
            state[:pick] = 0
            state[:top] = 0
            "L.#{state[:head]}: #{results(state).length} entr#{results(state).length == 1 ? 'y' : 'ies'}"
          end

          def key_find(state)
            state[:finding] = true
            state[:was] = state[:query].to_s
            PaneKeys::Ask['find: ', state[:query].to_s, :found, changed: :finding]
          end

          # Each edit of the find line (PaneKeys::Ask changed:).
          def key_finding(state, text)
            state[:query] = text.to_s
            state[:pick] = 0
            state[:top] = 0
            nil
          end

          # Enter on the find line: the find stays.
          def key_found(state, text)
            state[:finding] = false
            key_finding(state, text)
            n = results(state).length
            "#{n} match#{'es' unless n == 1} under L.#{head(state)}"
          end

          def key_unfind(state)
            state[:query] = state[:query].to_s[0...-1]
            state[:pick] = 0
            nil
          end

          def key_act(state)
            state[:finding] = false
            a = action(state) or return 'nothing picked'
            run(state, a)
          end

          def key_audition(state)
            e = picked(state) or return 'nothing picked'
            s = state[:snap]
            on = s && s.players.any? { |p| %i[audition audition/cue].include?(p.name) }
            path = UI::Picker.path_of(e)
            return PaneKeys::Run['audition off', "audition #{e.name}: stopped"] if on && state[:auditioned] == path
            state[:auditioned] = path
            run(state, UI::Picker.audition(e))
          end

          def key_edit(state)
            a = action(state) or return 'nothing picked'
            PaneKeys::Paste[a.code, "#{a.code}  (on the console: edit, Enter runs it)"]
          end

          def key_track(state, d)
            info = state[:snap]&.inspector or return 'no tracks to load into (bg :bass, clip; or Enter auditions)'
            return 'no tracks playing' if info.tracks.empty?
            i = info.tracks.index(info.track) || 0
            t = info.tracks[(i + d) % info.tracks.length]
            Inspect.target = { track: t, node: nil }.freeze
            "loads into #{t}"
          end

          def key_quit(_state) = :close

          # The pane's text for `y`.
          def full_text(state) = results(state).map { |e| UI::Picker.path_of(e) }.join("\n")

          private

          def run(state, a)
            case a.kind
            when :run, :audition
              where = state[:snap]&.cue_heard ? 'on CUE' : 'on MAIN at -6 dB'
              PaneKeys::Run[a.code, a.kind == :audition ? "#{a.note} #{where}" : a.note]
            else
              PaneKeys::Paste[a.code, a.note]
            end
          end
        end
      end
    end
  end
end
