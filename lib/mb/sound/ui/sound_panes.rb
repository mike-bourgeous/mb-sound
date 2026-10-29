module MB
  module Sound
    module UI
      # The sound-design screen's panes (sound-design-ui-1; `ui :sound`,
      # design/notes/sound_design_ui.md): the patch inspector (a track's
      # knobs to turn and its nodes' params), the selected node's preview,
      # the graph's code, and, until the library index lands
      # (library-core-1), placeholders for the picker and the audition
      # line.  Every pane draws from Slow#inspector (Inspect, gathered by
      # Poll while a pane needs :inspect) and the snapshot's knobs; keys
      # change the set only through console lines (PaneKeys::Run).
      module Panes
        # The patch inspector: a track's voice in sections (SOURCE FILTER
        # AMP MOD FX, the Minimoog way: each envelope in the section it
        # shapes; sound-design-nav-1, design/notes/sound_design_ui.md,
        # Sections), the picked row open with its params as rows to turn
        # (a knob's meter, value with unit, what else moves it; literals
        # dim, with Enter offering their `bind` line), knobs no row reads
        # above the sections; or the same knobs as a front panel (P; the
        # default at 80x24); or every node as chips, plumbing included (p;
        # the old list).  Follows the clip matrix's track (else the first
        # playing one) until t (or a row) picks one; opens on the filter.
        #
        # Mode keys (NAV Enter, or NAV d): s f a o x jump to SOURCE FILTER
        # AMP MOD FX (again: the next row there), n/N (] [, Tab) the
        # next/previous row, Up/Down pick a param (or a loose knob),
        # Left/Right turn it (Shift or H/L fine; a held key is a live sweep
        # and one `turn` line when it stops; a param a knob drives turns
        # that knob), Enter types a value (`turn :cut, 3000.hz`) or, on a
        # param no knob drives (a literal like `resonance: 0.25`, an
        # envelope time), offers its `bind` line (Arrangement::LiteralBinding:
        # a new knob, the patch rebuilt with it on the track's launch point;
        # the status line says so first), 0 its default, m learns a MIDI
        # controller for it (`learn :cut`), t/T the next/previous track, v/V
        # a kit's next/previous voice, P the panel, p the plumbing.
        class Inspector < Pane
          include KnobTurns
          jump 'd'

          mode_keys do
            group 'Inspector'
            on [:up, 'k'], :pick, -1, help: 'previous param or knob', label: 'Up Down'
            on [:down, 'j'], :pick, 1, help: 'next param or knob', label: 'Up Down'
            on [:right, 'l'], :turn, KnobTurns::STEP, help: 'turn the knob up (held: a live sweep, one turn line)', label: 'Left Right'
            on [:left, 'h'], :turn, -KnobTurns::STEP, help: 'turn the knob down (held: a live sweep, one turn line)', label: 'Left Right'
            on [:right, :shift], :turn, KnobTurns::FINE, help: 'turn up, fine'
            on [:left, :shift], :turn, -KnobTurns::FINE, help: 'turn down, fine'
            on ['L'], :turn, KnobTurns::FINE, help: 'turn up, fine'
            on ['H'], :turn, -KnobTurns::FINE, help: 'turn down, fine'
            on :enter, :ask, help: 'type a value, or bind a literal param (turn :cut, 3000.hz)', label: 'Enter'
            on '0', :reset, help: "the knob's default"
            on 'm', :learn, help: 'learn a MIDI controller for the knob (learn :cut: turn one)'
            on ['s'], :section, :source, help: 'SOURCE: oscillators, samples, glide (again: the next row)', label: 's f a o x'
            on ['f'], :section, :filter, help: 'FILTER: filters and the filter envelope', label: 's f a o x'
            on ['a'], :section, :amp, help: 'AMP: drive, the amp envelope', label: 's f a o x'
            on ['o'], :section, :mod, help: 'MOD: LFOs and other modulators', label: 's f a o x'
            on ['x'], :section, :fx, help: 'FX: effects, post-amp filters, pans', label: 's f a o x'
            on ['n', ']'], :node, 1, help: 'the next row (preview and params)', label: 'n N'
            on ['N', '['], :node, -1, help: 'the previous row', label: 'n N'
            on :tab, :node, 1, help: 'the next row (preview and params)', label: 'Tab S-Tab'
            on [:tab, :shift], :node, -1, help: 'the previous row', label: 'Tab S-Tab'
            on ['t'], :track, 1, help: 'the next track', label: 't T'
            on ['T'], :track, -1, help: 'the previous track', label: 't T'
            on ['v'], :voice, 1, help: "a kit's next voice", label: 'v V'
            on ['V'], :voice, -1, help: "a kit's previous voice", label: 'v V'
            on ['P'], :view, help: 'the front panel (the knobs by section) or the sections', label: 'P'
            on ['p'], :plumbing, help: 'every node as chips, the hidden plumbing too (again: back)', label: 'p'
          end

          keys do
            group 'Inspector'
            doc 'Enter', 'turn the track\'s knobs, pick sections and rows (Esc back to NAV)'
          end

          # Params a section row leaves out (note plumbing: they come from
          # the notes, nothing to turn) when no number is set.
          NOTE_PARAMS = %i[gate trigger velocity choke frequency phase reset release_at timeline_jumps timeline_phase].freeze

          # Short names for row summaries and panel cells.
          SHORTS = { resonance: 'reso', attack: 'A', decay: 'D', sustain: 'S', release: 'R', quality: 'q', cutoff: 'cut', frequency: 'freq' }.freeze

          def priority = :live

          def initialize = super(:inspector, rate: 15, height: 14, width: 52, needs: [:inspect], title: 'sound', min_height: 4,
                                             description: 'a track\'s voice in sections (SOURCE FILTER AMP MOD FX) with its knobs and params to turn, or as a front panel')

          # The view shown: :plumbing (p), else state[:view] (P flips), else
          # by the screen's size (the maintainer, 2026-10-29: the panel at
          # 80x24, sections from 120x40 up).
          def view(state, info = state[:snap]&.inspector)
            return :plumbing if state[:plumbing] || (info && !info.sections?)
            state[:view] || (state[:level] == :compact ? :panel : :sections)
          end

          # What Enter does now, for the status line (the design's rule:
          # name Enter's action before it is pressed).
          def enter_hint(state)
            if (pp = picked_param(state)) && !knob_of(state, pp)
              b = pp[2]
              return nil unless b
              return "#{pp[0]}: #{b.reason}" unless b.line
              track = state[:snap]&.inspector&.track
              return "make #{pp[0]} knob #{b.knob.inspect}: rebuilds #{track} at its launch point (voices and tails start fresh)"
            end
            cell = picked(state)
            cell ? "type #{cell[0]}'s value" : nil
          end

          def draw_body(c, s, state)
            state[:snap] = s
            info = s&.inspector
            if info.nil? || info.track.nil?
              c.puts ['nothing to inspect ', :dim], ['(play a track: bg :bass, clip)', :dim]
              return
            end
            knobs = s.knobs.to_h { |k| [k.name, k] }
            list = pick_list(state, info)
            # (nothing picked yet: the panel starts on the picked row's first cell)
            state[:pick] ||= list.index { |e| e[0] == :param && e[3] == info.node } if view(state, info) == :panel
            pick = list.empty? ? nil : (state[:pick] = state[:pick].to_i.clamp(0, list.length - 1))
            case view(state, info)
            when :plumbing then draw_plumbing(c, info, knobs, list, pick, state)
            when :panel then draw_panel(c, info, knobs, list, pick, state)
            else draw_sections(c, info, knobs, list, pick, state)
            end
          end

          # The track line: name, which of the tracks, and the keys.
          def draw_header(c, info, state, hint)
            idx = info.tracks.index(info.track)
            x = c.line(0, [info.track.to_s, :name], [info.document ? "  #{info.document}" : '', :text], ["  #{idx ? idx + 1 : '?'}/#{info.tracks.length}", :dim])
            c.text(x, 0, c.fit(state[:mode] ? "  #{hint}" : '', [c.w - x, 0].max), :dim)
            y = 1
            if info.error
              c.text(0, y, c.fit(info.error, c.w), :warn)
              y += 1
            end
            if info.voices.length > 1
              # A kit: one voice at a time (v V), its sections below
              x = c.text(0, y, 'voice ', :dim)
              info.voices.each do |v|
                break if x >= c.w
                sel = v == info.voice
                x = c.run(x, y, " #{v} ", sel ? :key : :name, reverse: sel)
              end
              c.text(x, y, c.fit('  v V', [c.w - x, 0].max), :dim)
              y += 1
              # (the voice's knob values: the kit's per-voice settings,
              # `tr909(clip, kick: { decay: 0.4 })`)
              if (vk = info.voice_knobs[info.voice]) && !vk.empty? && y < c.h - 2
                text = vk.map { |k, v| "#{k} #{v.is_a?(Float) ? Panes.fmt(v) : v}" }.join('  ')
                c.text(1, y, c.fit("#{info.voice}: #{text}", c.w - 1), :dim)
                y += 1
              end
            end
            y
          end

          # Knob rows (name, meter on the knob's curve, value, range) for
          # +names+ from row +y+; +first+ the pick index of the first.
          def draw_knob_rows(c, y, names, knobs, pick, state, first = 0, bottom: c.h - 1)
            names.each_with_index do |kn, i|
              break if y >= bottom && i > 0
              k = knobs[kn]
              value, turning = shown_value(state, kn, k)
              spec = k&.spec
              sel = state[:mode] && first + i == pick
              x = c.run(0, y, " #{c.fit(kn.to_s, 9).ljust(9)}", sel ? :key : :name, reverse: sel)
              unless spec
                c.text(x + 1, y, '(not in the session yet)', :dim)
                y += 1
                next
              end
              vtext = "#{Panes.fmt(value)}#{spec.unit ? " #{spec.unit}" : ''}"
              range = " #{Panes.fmt(spec.range.begin)}..#{Panes.fmt(spec.range.end)}#{spec.curve == :exp ? ' exp' : ''}"
              range = '' if c.w < 40
              mw = (c.w - x - vtext.length - range.length - 3).clamp(3, 32)
              x = c.meter(spec.position(value.to_f).to_f, width: mw, x: x + 1, y: y, role: :key)
              x = c.text(x + 1, y, vtext, turning ? :queued : :text)
              c.text(x, y, c.fit(range, [c.w - x, 0].max), :dim)
              y += 1
            end
            y
          end

          # The sections view: SOURCE FILTER AMP MOD FX with their rows, the
          # picked row open (every row open when they all fit; sections
          # other than the picked one on one line each when short of
          # room).
          def draw_sections(c, info, knobs, list, pick, state)
            keys = Inspect::SECTIONS.map { |sec| Inspect::SECTION_KEYS[sec] }.join(' ')
            y = draw_header(c, info, state, "#{keys}  n N rows  P panel")
            loose = info.loose
            y = draw_knob_rows(c, y, loose, knobs, pick, state, 0, bottom: c.h - 3) unless loose.empty?

            rows = info.shown
            secs = Inspect::SECTIONS.select { |sec| rows.any? { |i| info.nodes[i].section == sec } }
            sel = info.node
            cur = sel && info.nodes[sel]&.section
            hidden = info.hidden.values.sum
            foot = hidden > 0 && c.h - y > secs.length + 3 ? 1 : 0
            room = c.h - y - foot
            params = ->(i) { shown_params(info.nodes[i]).length }
            # (every row open when all fit; else the picked row open, and
            # sections collapsed to one line each, farthest from the
            # picked one first, until the rest fit)
            srows = secs.to_h { |sec| [sec, rows.select { |i| info.nodes[i].section == sec }] }
            all_open = secs.sum { |sec| 1 + srows[sec].sum { |i| 1 + params.(i) } }
            open = all_open <= room ? :all : :picked
            need = ->(sec) { 1 + srows[sec].length + (srows[sec].include?(sel) ? params.(sel) : 0) }
            collapsed = {}
            if open == :picked
              total = secs.sum { |sec| need.(sec) }
              ci = secs.index(cur) || 0
              far = secs.each_with_index.sort_by { |sec, i| [-(i - ci).abs, -need.(sec)] }.map(&:first) - [cur]
              far.each do |sec|
                break if total <= room
                collapsed[sec] = true
                total -= need.(sec) - 1
              end
              # (still too tall: the farthest collapsed lines go too)
              far.each do |sec|
                break if total <= room
                collapsed[sec] = :omit
                total -= 1
              end
            end
            psel = pick && pick >= loose.length ? pick - loose.length : nil

            secs.each do |sec|
              break if y >= c.h - foot
              list = srows[sec]
              title = Inspect::SECTION_TITLES[sec]
              key = Inspect::SECTION_KEYS[sec]
              next if collapsed[sec] == :omit
              if collapsed[sec]
                x = c.text(0, y, c.pad(title, 7), :title)
                x = c.text(x, y, "#{key} ", :key)
                c.text(x, y, c.fit(list.map { |i| row_title(info.nodes[i]) }.join(' · '), [c.w - x, 0].max), :text)
                y += 1
                next
              end
              x = c.text(0, y, "#{title} ", sec == cur ? :key : :title)
              x = c.text(x, y, key, :key)
              c.text(x, y, " #{'─' * [c.w - x - 2, 0].max}", :dim)
              y += 1
              # (the picked section's rows scroll to keep the picked row and
              # its params on screen)
              if sel && list.include?(sel)
                before = list.index(sel)
                fit = c.h - foot - y - params.(sel) - 1
                list = list.drop(before - [fit, 0].max) if before > fit
              end
              list.each do |i|
                break if y >= c.h - foot
                n = info.nodes[i]
                on = i == sel
                x = c.run(0, y, on ? '▸' : ' ', :key)
                x = c.run(x, y, c.pad(row_title(n), 14), on && psel.nil? ? :key : :name, reverse: on && state[:mode] && psel.nil?)
                c.text(x + 1, y, c.fit(row_tail(n, knobs), [c.w - x - 1, 0].max), :dim)
                y += 1
                next unless on || open == :all
                shown_params(n).each_with_index do |(name, v), pi|
                  break if y >= c.h - foot
                  y = draw_param(c, y, info, n, name, v, knobs, state, sel: on && state[:mode] && pi == psel, indent: 2)
                end
              end
            end
            c.text(0, c.h - 1, c.fit("#{hidden} plumbing nodes hidden (p shows)", c.w), :dim) if foot == 1
          end

          # A row's title: its DSL words and copies ("saw ×6", "lp4").
          def row_title(n)
            label = n.label == 'env' && n.what&.end_with?(' env') ? n.what : n.label
            "#{label}#{n.count > 1 ? " ×#{n.count}" : ''}"
          end

          # A row's dim tail: its role, where it goes, its first settings.
          def row_tail(n, knobs)
            bits = []
            bits << n.what if n.what && !%w[drive lfo pitch].include?(n.what) && n.what != n.label && !(n.label == 'env' && n.what.end_with?(' env'))
            bits << "→ #{n.dest.join(', ')}" unless n.dest.empty?
            bits << 'stereo' if n.channels > 1
            sum = shown_params(n).filter_map { |name, v|
              kn = n.knob_of(name)
              v = v.with(unit: Panes.unit_of(knobs[kn].spec, name)) if v.unit.nil? && kn && knobs[kn]&.spec
              t = value_text(v, param_value(n, name, v, knobs))
              t && "#{SHORTS[name] || name} #{t}"
            }.first(4)
            (bits + sum).join('  ')
          end

          # A param's value now: its knob's (turned values follow), else
          # the snapshot's.
          def param_value(n, name, v, knobs)
            kn = n.knob_of(name)
            kn && knobs[kn] ? knobs[kn].value : v.value
          end

          # +value+ (of ParamValue +v+) as text with its unit (seconds as ms
          # below 1 s), or nil.
          def value_text(v, value = v.value)
            return nil unless value.is_a?(Numeric)
            unit = v.unit&.strip
            if unit == 's'
              value.abs < 1 ? "#{Panes.fmt(value * 1000)}ms" : "#{Panes.fmt(value)}s"
            elsif unit && !unit.empty? && unit != 'Q'
              "#{Panes.fmt(value)} #{unit}"
            else
              Panes.fmt(value)
            end
          end

          # One param row: name, a meter for a knob, the value, what else
          # moves it (a knob's name dim).  Returns the next row.
          def draw_param(c, y, info, n, name, v, knobs, state, sel:, indent: 2)
            x = c.run(indent, y, c.pad(name.to_s, 10), sel ? :key : :name, reverse: sel)
            kn = n.knob_of(name)
            k = kn && knobs[kn]
            mods = modulators(info, n, name)
            if k&.spec
              value, turning = shown_value(state, kn, k)
              vtext = value_text(v.unit ? v : v.with(unit: Panes.unit_of(k.spec, name)), value) || Panes.fmt(value)
              more = mods.empty? ? '' : "← #{mods.join(', ')}"
              mw = (c.w - x - vtext.length - more.length - kn.to_s.length - 6).clamp(3, 16)
              x = c.meter(k.spec.position(value.to_f).to_f, width: mw, x: x + 1, y: y, role: :key)
              x = c.text(x + 1, y, vtext, turning ? :queued : :text)
              x = c.text(x + 1, y, more, :dim) unless more.empty?
              c.text(x, y, c.fit("  #{kn}", [c.w - x, 0].max), :dim)
            elsif !v.value.nil?
              x = c.text(x + 1, y, value_text(v) || v.value.to_s, :text)
              hint = sel && (b = n.binds[name]) ? (b.line ? "  Enter: knob #{b.knob.inspect}" : "  #{b.reason}") : (v.detail == Inspect::LITERAL ? '  ·' : '')
              c.text(x, y, c.fit(hint, [c.w - x, 0].max), :dim)
            else
              c.text(x + 1, y, c.fit(mods.empty? ? "#{c.glyph(:arrow)} #{v.label || v.detail}" : "← #{mods.join(', ')}", [c.w - x - 1, 0].max), :dim)
            end
            y + 1
          end

          # The envelopes and modulators going to row +n+'s param +name+
          # ("lfo", "filter env"), from their rows' destinations.
          def modulators(info, n, name)
            want = "#{n.label} #{name}"
            info.nodes.filter_map { |m|
              next if m.section == :plumbing || m.equal?(n) || (n.voice && m.voice && m.voice != n.voice)
              row_title(m) if m.dest.include?(want)
            }.uniq
          end

          # The params a row shows: note plumbing left out (see NOTE_PARAMS).
          def shown_params(n)
            vals = n.params.values.to_a
            return vals unless n.section
            vals.reject { |name, v| v.value.nil? && NOTE_PARAMS.include?(name) }
          end

          # Columns of a panel cell, at least.
          CELL = 24

          # The front panel (P; the default at 80x24): each section's knobs
          # and bindable literals as cells side by side (name, a meter for a
          # knob, dim dots for a literal, the value), like a synth's panel;
          # when the pane is too short for every section, the picked one is
          # open and the others are one line each.  Up/Down step the cells
          # (the row a cell belongs to becomes the picked row: its preview
          # follows), Left/Right turn, Enter types or binds.
          def draw_panel(c, info, knobs, list, pick, state)
            keys = Inspect::SECTIONS.map { |sec| Inspect::SECTION_KEYS[sec] }.join(' ')
            y = draw_header(c, info, state, "#{keys}  P sections")
            if list.empty?
              text = info.voices.length > 1 ? "no knobs: the voice's settings are above (a kit's knob Hash: #{info.voice}: { decay: 0.4 }); P the sections" : 'no knobs or literals to show (P: the sections, p: every node)'
              c.text(0, y, c.fit(text, c.w), :dim)
              return
            end
            groups = list.each_with_index.group_by { |e, _| cell_section(info, e) }
            order = [nil, *Inspect::SECTIONS].select { |sec| groups.key?(sec) }
            per = [c.w / CELL, 1].max
            cw = c.w / per
            room = c.h - y
            cur = pick && cell_section(info, list[pick])
            need = order.sum { |sec| 1 + (groups[sec].length + per - 1) / per }
            tight = need > room
            psel = state[:mode] ? pick : nil
            order.each do |sec|
              break if y >= c.h
              cells = groups[sec]
              title = sec ? Inspect::SECTION_TITLES[sec] : 'KNOBS'
              key = sec ? Inspect::SECTION_KEYS[sec] : ''
              names = cell_names(info, cells.map(&:first))
              if tight && sec != cur
                x = c.text(0, y, c.pad(title, 7), :title)
                x = c.text(x, y, "#{key} ", :key) unless key.empty?
                summary = cells.each_with_index.map { |(e, _), j| "#{names[j]} #{cell_value_text(info, e, knobs, state)}" }.join('  ')
                c.text(x, y, c.fit(summary, [c.w - x, 0].max), :dim)
                y += 1
                next
              end
              x = c.text(0, y, "#{title} ", sec == cur ? :key : :title)
              x = c.text(x, y, key, :key) unless key.empty?
              c.text(x, y, " #{'─' * [c.w - x - 2, 0].max}", :dim)
              y += 1
              cells.each_slice(per).with_index do |slice, si|
                break if y >= c.h
                slice.each_with_index do |(e, idx), j|
                  draw_cell(c.sub(j * cw, y, cw - 1, 1), info, e, names[si * per + j], knobs, state, idx == psel)
                end
                y += 1
              end
            end
          end

          # The section a panel entry goes in (nil: a knob no row shows).
          def cell_section(info, e)
            e[0] == :knob ? nil : info.nodes[e[3]]&.section
          end

          # Cell names for +entries+ of one section: the param's short name,
          # with its row's title before it where two rows share it (an amp
          # env's and a layer env's attack).
          def cell_names(info, entries)
            base = entries.map { |e|
              kn = e[0] == :knob ? e[1] : info.nodes[e[3]].knob_of(e[1])
              # (a knob's cell is named after the knob: bass/glide is glide, not time)
              kn ? kn.to_s.split('/').last : (SHORTS[e[1]] || e[1]).to_s
            }
            dup = base.tally.select { |_, n| n > 1 }.keys
            entries.each_with_index.map { |e, i|
              next base[i] unless e[0] == :param && dup.include?(base[i])
              "#{row_title(info.nodes[e[3]]).split(' ').first}.#{base[i]}"
            }
          end

          # A panel entry's value as text ("2400 Hz", "4ms").
          def cell_value_text(info, e, knobs, state)
            kn = e[0] == :knob ? e[1] : info.nodes[e[3]].knob_of(e[1])
            if kn && (k = knobs[kn])&.spec
              value, = shown_value(state, kn, k)
              v = e[0] == :param ? e[2] : GraphNode::Traversable::ParamValue.new(value: value, type: :control, unit: nil, range: nil, label: kn, detail: nil)
              return value_text(v.unit ? v : v.with(unit: Panes.unit_of(k.spec, e[1])), value) || Panes.fmt(value)
            end
            e[0] == :param ? (value_text(e[2]) || '-') : '-'
          end

          # One panel cell on +c+ (a one-row canvas): name, a meter (a knob)
          # or dots (a literal), the value.
          def draw_cell(c, info, e, name, knobs, state, sel)
            x = c.run(0, 0, c.pad(name, 8), sel ? :key : :name, reverse: sel)
            kn = e[0] == :knob ? e[1] : info.nodes[e[3]].knob_of(e[1])
            vtext = cell_value_text(info, e, knobs, state)
            mw = (c.w - x - vtext.length - 2).clamp(2, 10)
            if kn && (k = knobs[kn])&.spec
              value, turning = shown_value(state, kn, k)
              x = c.meter(k.spec.position(value.to_f).to_f, width: mw, x: x + 1, y: 0, role: :key)
              c.text(x + 1, 0, c.fit(vtext, [c.w - x - 1, 0].max), turning ? :queued : :text)
            else
              x = c.text(x + 1, 0, '·' * mw, :dim)
              c.text(x + 1, 0, c.fit(vtext, [c.w - x - 1, 0].max), :dim)
            end
          end

          # The plumbing view (p): every knob the graph reads as knob rows,
          # every node as chips (plumbing too), the picked node's params.
          def draw_plumbing(c, info, knobs, list, pick, state)
            y = draw_header(c, info, state, 't: next track')
            if info.knobs.empty?
              c.text(0, y, c.fit('no knobs: knob :cut, 800.hz then knob(:cut) in the patch', c.w), :dim)
              y += 1
            end
            y = draw_knob_rows(c, y, info.knobs, knobs, pick, state)
            if pick && state[:mode] && y < c.h && pick < info.knobs.length && (desc = knobs[info.knobs[pick]]&.spec&.param&.description)
              c.text(1, y, c.fit(desc, c.w - 1), :dim)
              y += 1
            end
            draw_node(c, info, y + (y < c.h - 2 ? 1 : 0), state[:mode] && pick && pick >= info.knobs.length ? pick - info.knobs.length : nil) if y < c.h - 1
          end

          # The selected node (title row: label, copies, which of how many)
          # and its params below (param +psel+ picked: reversed, and a
          # literal's Enter action after it).
          def draw_node(c, info, y, psel = nil)
            n = info.selected
            unless n
              c.text(0, y, 'no nodes with params', :dim)
              return
            end
            # The nodes as a row of chips (the selected one reversed), then
            # the selected node's class and params
            x = c.text(0, y, 'nodes ', :dim)
            info.nodes.each_with_index do |m, i|
              chip = "#{m.label}#{m.count > 1 ? "×#{m.count}" : ''}"
              if x + chip.length + 1 > c.w
                y += 1
                x = 6
                break if y >= c.h - 1
              end
              x = c.run(x, y, chip, i == info.node ? :key : m.knobs.empty? ? :text : :name, reverse: i == info.node)
              x += 1
            end
            y += 1
            return if y >= c.h
            role = n.role && n.role != n.label ? "  #{n.role}" : ''
            x = c.line(y, [n.label, :key], ["#{role}#{n.count > 1 ? " ×#{n.count}" : ''}", :dim], ["  #{info.node + 1}/#{info.nodes.length}", :dim])
            c.text(x, y, c.fit('  n N: other nodes', [c.w - x, 0].max), :dim)
            y += 1
            # (a picked param below the pane's last row scrolls the list)
            vals = n.params.values.to_a
            first = psel && psel >= c.h - y ? psel - (c.h - y) + 1 : 0
            vals.each_with_index do |(name, v), i|
              next if i < first
              break if y >= c.h
              sel = i == psel
              x = c.run(1, y, c.pad(name.to_s, 10), sel ? :key : :name, reverse: sel)
              text, role =
                if v.label.is_a?(Symbol) then ["#{c.glyph(:arrow)} knob #{v.label} #{Panes.fmt(v.value)}#{v.unit ? " #{v.unit}" : ''}", :key]
                elsif !v.value.nil? then ["#{Panes.fmt(v.value)}#{v.unit ? " #{v.unit}" : ''}", :text]
                else ["#{c.glyph(:arrow)} #{v.label || v.detail}", :dim]
                end
              x = c.text(x + 1, y, c.fit(text, [c.w - x - 1, 0].max), role)
              if sel && (b = n.binds[name])
                c.text(x, y, c.fit(b.line ? "  Enter: knob #{b.knob.inspect}" : "  #{b.reason}", [c.w - x, 0].max), :dim)
              end
              y += 1
            end
            c.text(1, y, '(no params of its own)', :dim) if n.params.values.empty? && y < c.h
          end

          def key_pick(state, d)
            out = flush(state)
            state[:pick] = state[:pick].to_i + d
            # (the panel: the picked cell's row becomes the picked row, so
            # the preview follows and its literals' bind lines are ready)
            info = state[:snap]&.inspector
            if info && view(state, info) == :panel
              list = pick_list(state, info)
              state[:pick] = state[:pick].clamp(0, [list.length - 1, 0].max)
              e = list[state[:pick]]
              Inspect.target = { track: info.track, node: e[3], voice: info.voice }.freeze if e && e[0] == :param && e[3] != info.node
            end
            out
          end

          def key_ask(state)
            if (pp = picked_param(state)) && !knob_of(state, pp)
              name, _v, b = pp
              return "#{name}: driven by #{pp[1].detail || 'a node'}" unless b
              return "#{name}: #{b.reason}" unless b.line
              return [*flush(state), PaneKeys::Ask['', b.line, :bind]]
            end
            cell = picked(state) or return no_knob_note
            kn, k = cell
            value, = shown_value(state, kn, k)
            [*flush(state), PaneKeys::Ask["turn #{kn.inspect}, ", TurnGesture.number(value), :typed]]
          end

          # The typed answer to #key_ask: one `turn` line with it (Ruby:
          # 3000, 3000.hz, -6.db).
          def key_typed(state, text)
            cell = picked(state) or return no_knob_note
            text = text.to_s.strip
            return 'nothing typed' if text.empty?
            PaneKeys::Run["turn #{cell[0].inspect}, #{text}", "#{cell[0]} #{text}"]
          end

          # The `bind` line #key_ask offered, as typed (Enter runs it).
          def key_bind(state, text)
            text = text.to_s.strip
            return 'nothing typed' if text.empty?
            PaneKeys::Run[text, "#{text}: the patch rebuilds at the track's launch point"]
          end

          def key_learn(state)
            cell = picked(state) or return no_knob_note
            [*flush(state), PaneKeys::Run["learn #{cell[0].inspect}", "learn #{cell[0]}: turn a controller"]]
          end

          def key_track(state, d)
            info = state[:snap]&.inspector or return 'nothing to inspect'
            return 'no tracks playing' if info.tracks.empty?
            i = info.tracks.index(info.track) || 0
            t = info.tracks[(i + d) % info.tracks.length]
            state[:pick] = nil
            Inspect.target = { track: t, node: nil }.freeze
            [*flush(state), "inspecting #{t}"]
          end

          def key_node(state, d)
            info = state[:snap]&.inspector or return 'nothing to inspect'
            rows = view(state, info) == :plumbing ? info.nodes.each_index.to_a : info.shown.sort_by { |j| [Inspect::SECTIONS.index(info.nodes[j].section) || 99, j] }
            return 'no nodes' if rows.empty?
            at = rows.index(info.node)
            i = rows[at ? (at + d) % rows.length : (d > 0 ? 0 : -1)]
            pick_row(state, info, i)
          end

          # s f a o x: the first row of section +sec+, or (in it already)
          # its next row.
          def key_section(state, sec)
            info = state[:snap]&.inspector or return 'nothing to inspect'
            rows = info.shown.select { |i| info.nodes[i].section == sec }
            return "no #{Inspect::SECTION_TITLES[sec]} rows in #{info.track}" if rows.empty?
            at = rows.index(info.node)
            state[:plumbing] = nil
            pick_row(state, info, at ? rows[(at + 1) % rows.length] : rows.first)
          end

          # v V: a kit's next/previous drum voice.
          def key_voice(state, d)
            info = state[:snap]&.inspector or return 'nothing to inspect'
            return "#{info.track} has no drum voices (a kit's voices appear once played)" if info.voices.length < 2
            v = info.voices[((info.voices.index(info.voice) || 0) + d) % info.voices.length]
            state[:pick] = info.loose.length
            Inspect.target = { track: info.track, node: nil, voice: v }.freeze
            [*flush(state), "voice #{v}"]
          end

          # P: the panel or the sections.
          def key_view(state)
            info = state[:snap]&.inspector
            now = view(state, info)
            state[:plumbing] = nil
            state[:view] = now == :panel ? :sections : :panel
            state[:pick] = nil
            "#{state[:view]} view (P flips)"
          end

          # p: the plumbing view (every node as chips) or back.
          def key_plumbing(state)
            state[:plumbing] = !state[:plumbing]
            state[:pick] = nil
            state[:plumbing] ? 'every node, plumbing too (p: back to the sections)' : 'sections'
          end

          private

          def no_knob_note = 'no knob to turn: the graph reads none (knob :cut, 800.hz; then knob(:cut) in the patch)'

          # Picks row +i+ (the inspector, preview, and code follow).
          def pick_row(state, info, i)
            n = info.nodes[i]
            state[:pick] =
              case view(state, info)
              when :plumbing then info.knobs.length
              when :panel then pick_list(state, info).index { |e| e[0] == :param && e[3] == i } || state[:pick]
              else info.loose.length
              end
            Inspect.target = { track: info.track, node: i, voice: info.voice }.freeze
            sec = n.section && n.section != :plumbing ? "#{Inspect::SECTION_TITLES[n.section]} " : ''
            "#{sec}#{row_title(n)}#{n.what ? " (#{n.what})" : ''}"
          end

          # What Up/Down step through: [[:knob, name], ...] then [[:param,
          # name, ParamValue], ...] of the selected row (the plumbing view:
          # every knob; the others: the knobs no row shows).
          #
          # Entries are [:knob, name] or [:param, name, ParamValue, row].  The
          # panel's are every shown row's knob-driven and literal params, in
          # section order (they don't depend on the picked row).
          def pick_list(state, info)
            n = info.selected
            case view(state, info)
            when :plumbing
              info.knobs.map { |k| [:knob, k] } + (n ? n.params.values.map { |name, v| [:param, name, v, info.node] } : [])
            when :panel
              rows = info.shown.sort_by { |j| [Inspect::SECTIONS.index(info.nodes[j].section) || 99, j] }
              info.loose.map { |k| [:knob, k] } + rows.flat_map { |j|
                m = info.nodes[j]
                shown_params(m).filter_map { |name, v|
                  # (counts stay out: read once while the patch builds, never knobs)
                  # (and a preset's numbers: fixed in its document, its params are the knobs)
                  [:param, name, v, j] if m.knob_of(name) || (!info.document && v.detail == Inspect::LITERAL && !Arrangement::LiteralBinding.count?(name, v.value))
                }
              }
            else
              info.loose.map { |k| [:knob, k] } + (n ? shown_params(n).map { |name, v| [:param, name, v, info.node] } : [])
            end
          end

          # The knob param row +pp+ ([name, ParamValue, Bind, row]) turns, or
          # nil.
          def knob_of(state, pp)
            n = state[:snap]&.inspector&.nodes&.[](pp[3])
            n&.knob_of(pp[0]) || (pp[1].label.is_a?(Symbol) ? pp[1].label : nil)
          end

          # The picked knob: a knob row, or a param row a knob drives
          # ([name, KnobValue]), else nil.
          def picked(state)
            s = state[:snap] or return nil
            info = s.inspector or return nil
            list = pick_list(state, info)
            return nil if list.empty?
            e = list[state[:pick].to_i.clamp(0, list.length - 1)]
            kn = e[0] == :knob ? e[1] : knob_of(state, [e[1], e[2], nil, e[3]])
            return nil unless kn
            k = s.knobs.find { |kv| kv.name == kn } or return nil
            [kn, k]
          end

          # The picked param row of the selected node: [name, ParamValue,
          # Bind or nil], or nil on a knob row.
          def picked_param(state)
            info = state[:snap]&.inspector or return nil
            list = pick_list(state, info)
            return nil if list.empty?
            e = list[state[:pick].to_i.clamp(0, list.length - 1)]
            return nil unless e[0] == :param
            [e[1], e[2], info.nodes[e[3]]&.binds&.[](e[1]), e[3]]
          end
        end

        # The selected node's preview (Plot::Panels: a filter's response, a
        # shaper's curve, an envelope's note), drawn through Plot::Live like
        # the scope; follows turned knobs (the node's snapshot is taken
        # again every poll).  An envelope's playhead (NodeInfo#live, read
        # 4 times a second) moves on between polls by the clock while its
        # segment runs (Clock: a lambda for specs).
        class Preview < Pane
          class << self
            # The clock the playhead moves by (monotonic seconds; specs set
            # a lambda).
            attr_writer :clock

            def now = @clock ? @clock.call : Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          # The playhead's time step: elapsed time is rounded to it, finer
          # than a frame at 120 fps, so the playhead moves every frame
          # while a segment runs (and a held sustain, without elapsed
          # time, never rebuilds the chart).
          PLAYHEAD_STEP = 1 / 240.0

          def initialize
            super(:preview, rate: 8, height: 10, width: 48, needs: [:inspect], title: 'preview', min_height: 3,
                            description: 'the inspected node\'s preview: a filter\'s response, a shaper\'s transfer curve, an envelope\'s note with a playhead')
            @playhead = false
          end

          # A live pane (UI::PaneRates: the painter's target rate, slowing
          # under load like the meters) while the inspected node has a
          # playhead (an envelope's note: maintainer 2026-10-28, "can it
          # reach 60+ like other parts of the UI?"), else a list pane at its
          # own rate (a filter's response changes only when turned).
          # Measured per frame (48x10 and 100x20, YJIT): the envelope chart
          # 0.18 ms, Plot::Live#draw 0.27-0.34 ms, so the chart is rebuilt
          # whole rather than caching it and moving only the playhead.
          def priority = @playhead ? :live : :list

          def plot?
            true
          end

          def draw(c, s, state, look: nil)
            w = c.w
            h = c.h
            return if w <= 0 || h <= 0
            n = s&.inspector&.selected
            @playhead = !n&.live.nil?
            chart = n&.preview ? chart_for(n, state) : nil
            unless chart
              c.clear
              c.text(0, 0, c.fit(n ? "#{n.label}: no preview (filters, shapers, and envelopes have one)" : 'no node selected (the inspector: n)', w), :dim)
              return
            end
            native = c.grid.is_a?(FastUI::Grid)
            lk = look && look != :auto ? look : Scope.auto_look(w, h)
            live = state[:live]
            if live.nil? || live.width != w || live.height != h || state[:native] != native || state[:look] != lk
              live = state[:live] = Plot::Live.new(width: w, height: h, look: lk, native: native)
              state[:native] = native
              state[:look] = lk
            end
            live.draw(chart, c.grid, x: c.x, y: c.y)
          end

          private

          # The node's chart, rebuilt only when its params (or a playhead)
          # change.
          def chart_for(n, state)
            live = live_now(n.live)
            key = [n.params, live]
            return state[:chart] if state[:chart_of] == key
            b = Plot::ChartBuilder.new(title: nil, x: nil, y: nil, legend: false, grid: true)
            chart = Plot::Panels.preview(n.params.node_class, n.params, b, live: live) ? b.build : nil
            state[:chart_of] = key
            state[:chart] = chart
          rescue StandardError => e
            state[:chart_of] = key
            state[:chart] = nil
            warn "preview of #{n.label}: #{e.class}: #{e.message}"
            nil
          end

          # +live+ (NodeInfo#live) with +:elapsed+, the seconds since it was
          # read while its segment runs (in PLAYHEAD_STEPs).
          def live_now(live)
            return live unless live && live[:at] && live[:stage] == :segment
            live.merge(elapsed: ((Preview.now - live[:at]) / PLAYHEAD_STEP).floor * PLAYHEAD_STEP)
          end
        end

        # A preview of the inspected track's voice (sound-design-ui-2: "a
        # one-shot render of the processed waveform updated periodically
        # when parameters change"): a second copy of one voice
        # (UI::PatchRender) plays one note (the clip's first, else a guess
        # from the track's role) from a reset state, drawn as one settled
        # cycle from a rising zero crossing (a few cycles when detuned
        # unison copies never repeat) above the settled sound's spectrum,
        # with the note's envelope (half a second, min/max) below them in a
        # tall pane; the render before it faintly behind; LUFS, peak, and
        # RMS on the first row.  It renders again 0.1 s after the knobs the
        # voice reads stop moving, at most every 0.2 s while they move; the
        # live graph is never touched.
        #
        # Mode keys (NAV Enter, or NAV w): s the views (all that fit, the
        # cycle, the envelope, the spectrum), o the faint previous render on
        # or off, p the role's guessed note instead of the clip's first, +
        # and - the envelope's length, r render again.
        class Render < Pane
          jump 'w'

          mode_keys do
            group 'Render'
            on 's', :view, help: 'the views: all that fit, the cycle, the envelope, the spectrum'
            on 'o', :overlay, help: 'the previous render (faint) on or off'
            on 'p', :phrase, help: "the role's guessed note or the clip's first note"
            on ['+', '='], :length, 1, help: 'a longer envelope view', label: '+ -'
            on '-', :length, -1, help: 'a shorter envelope view', label: '+ -'
            on 'r', :again, help: 'render again'
          end

          # The color of the previous render behind the current one.
          PREVIOUS = '#5c6370'

          # Render lengths + and - step through (seconds).
          LENGTHS = [0.1, 0.2, 0.3, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0, 8.0, 12.0, 16.0, 20.0].freeze

          # Views s cycles through.
          VIEWS = %i[all cycle envelope spectrum].freeze

          # The fewest rows of each plot when both are stacked, and the
          # fewest columns of each side by side.
          STACK_ROWS = 5
          SIDE_COLS = 45

          def initialize = super(:render, rate: 10, height: 12, width: 48, needs: [:inspect, :render], title: 'render', min_height: 3,
                                          description: 'a preview of one note through a copy of the inspected voice: a settled cycle, its spectrum, the envelope, peak, RMS, LUFS, redone when its knobs change')

          def plot?
            true
          end

          # The pane's PatchRender::Driver in +state+ (made on first use).
          def self.driver(state) = (state[:driver] ||= PatchRender::Driver.new)

          def draw(c, s, state, look: nil)
            c.clear
            return if c.w <= 0 || c.h <= 0
            if @title && !state[:title_in_rule]
              c.text(0, 0, 'RENDER', :title)
              c = c.sub(0, 1, c.w, c.h - 1)
              return if c.h <= 0
            end
            src = s&.render_source
            unless src
              c.text(0, 0, c.fit('nothing to render (play a track: bg :bass, clip)', c.w), :dim)
              return
            end
            unless src.synth
              c.text(0, 0, c.fit(src.note || 'no voice to copy', c.w), :dim)
              return
            end
            driver = Render.driver(state)
            driver.guess = !!state[:guess]
            driver.tick(src, s.knobs, s.inspector&.knobs || [].freeze)
            r = driver.shown
            r = nil if r && r.track != src.track
            draw_header(c, r, driver)
            return if c.h < 2
            if r.nil? || r.error
              c.text(0, 1, c.fit(r ? r.error : 'rendering...', c.w), r ? :warn : :dim)
              return
            end
            prev = state[:overlay] == false ? nil : driver.previous
            areas(c.sub(0, 1, c.w, c.h - 1), state[:view] || :all).each do |view, body|
              chart = chart_for(r, prev, view, state)
              plot(body, chart, state, view, look) if chart
            end
          end

          # [[view, canvas], ...]: the plots that fit +body+ for +view+ (:all:
          # the cycle above the spectrum above the envelope, as many as fit
          # STACK_ROWS rows each; side by side in a wide, short pane).
          def areas(body, view)
            return [[view, body]] unless view == :all
            rows = body.h / STACK_ROWS
            if rows >= 2
              list = rows >= 3 ? %i[cycle spectrum envelope] : %i[cycle spectrum]
              h = body.h / list.length
              list.each_with_index.map { |v, i| [v, body.sub(0, i * h, body.w, i == list.length - 1 ? body.h - i * h : h)] }
            elsif body.w >= 2 * SIDE_COLS
              left = body.w / 2
              [[:cycle, body.sub(0, 0, left, body.h)], [:spectrum, body.sub(left, 0, body.w - left, body.h)]]
            else
              [[:cycle, body]]
            end
          end

          # Draws +chart+ into +body+ through a Plot::Live kept per view.
          def plot(body, chart, state, view, look)
            native = body.grid.is_a?(FastUI::Grid)
            lk = look && look != :auto ? look : Scope.auto_look(body.w, body.h)
            lives = (state[:lives] ||= {})
            live, was = lives[view]
            if live.nil? || live.width != body.w || live.height != body.h || was != [native, lk]
              live = Plot::Live.new(width: body.w, height: body.h, look: lk, native: native)
              lives[view] = [live, [native, lk]]
            end
            live.draw(chart, body.grid, x: body.x, y: body.y)
          end

          # The first row: the track and its figures, what it played (and
          # whether its period settled), the copy's rate, the render's time,
          # and a mark while a newer render waits or runs.
          def draw_header(c, r, driver)
            x = c.text(0, 0, r&.track.to_s, :name)
            if r && !r.error
              x = c.line(0, ['  ', :dim], [Panes.db(r.lufs), :text], [' LUFS', :dim], ['  peak ', :dim], [Panes.db(r.peak), :text],
                         ['  rms ', :dim], [Panes.db(r.rms), :text], x: x)
              how = r.settled ? "settled #{(r.settled * 1000).round} ms" : "#{r.periods} cycles"
              tail = "  #{r.input}, #{how}, #{Panes.fmt(r.rate / 1000.0)} kHz, #{r.ms.round} ms"
            else
              tail = r ? "  #{r.input}" : ''
            end
            x = c.text(x, 0, c.fit(tail, [c.w - x - 2, 0].max), :dim)
            c.text(x, 0, ' …', :queued) if driver.pending? && x + 2 <= c.w
          end

          def key_view(state)
            i = VIEWS.index(state[:view] || :all) || 0
            state[:view] = VIEWS[(i + 1) % VIEWS.length]
            { all: 'render: the cycle, the spectrum, and the envelope (where they fit)', cycle: 'render: the settled cycle',
              envelope: 'render: the envelope', spectrum: 'render: the spectrum' }[state[:view]]
          end

          def key_overlay(state)
            state[:overlay] = state[:overlay] == false
            state[:overlay] ? 'render: the previous render behind' : 'render: no previous render'
          end

          def key_phrase(state)
            state[:guess] = !state[:guess]
            state[:guess] ? "render: the role's guessed note" : "render: the clip's first note (a guess without a clip)"
          end

          def key_length(_state, d)
            now = PatchRender.seconds
            i = LENGTHS.index { |l| l >= now - 1e-9 } || LENGTHS.length - 1
            i += 1 if d > 0 && LENGTHS[i] <= now + 1e-9
            i -= 1 if d < 0
            PatchRender.seconds = LENGTHS[i.clamp(0, LENGTHS.length - 1)]
            "render: the envelope #{Panes.fmt(PatchRender.seconds)} s (PatchRender.seconds)"
          end

          def key_again(state)
            Render.driver(state).again
            'render: again'
          end

          # What Enter does in the pane (the status line).
          def enter_hint(_state) = nil

          private

          # The chart for Result +r+ (and +prev+ faintly behind, if any) in
          # +view+ (:cycle, :envelope, or :spectrum), rebuilt only when they
          # change.
          def chart_for(r, prev, view, state)
            charts = (state[:charts] ||= {})
            key = [r.seq, prev&.seq]
            hit = charts[view]
            return hit[1] if hit && hit[0] == key
            b = Plot::ChartBuilder.new(title: nil, x: nil, y: nil, legend: false, grid: true)
            case view
            when :spectrum
              return nil unless r.spectrum
              f, db = r.spectrum
              ps = prev&.spectrum
              top = [db.max, ps ? ps[1].max : -Float::INFINITY].max
              b.x :frequency, 20.0..[r.rate / 2.0, ps ? prev.rate / 2.0 : 0].max
              b.y Plot::Scale::DB.new(-90.0..[(top / 10.0).ceil * 10, -40].max.to_f)
              b.line(ps[1], x: ps[0], color: PREVIOUS) if ps
              b.line(db, x: f)
            when :cycle
              return nil unless r.cycle && r.cycle[0].length > 1
              ms = ->(res) { (0..(res.cycle[0].length - 1) * 1000.0 / res.rate) }
              peak = [*r.cycle.map { |d| d.abs.max }, *(prev&.cycle || []).map { |d| d.abs.max }].max.to_f
              peak = 1.0 if peak <= 0
              b.x :linear, label: 'ms'
              b.y Plot::Scale::Symmetric.new(-peak..peak, label: nil)
              prev&.cycle&.each { |d| b.line(d, x: ms.(prev), color: PREVIOUS) }
              r.cycle.each_with_index { |d, i| b.line(d, x: ms.(r), color: i) }
            else
              b.x :time, sample_rate: r.rate
              peak = [r.hi.max, -r.lo.min, prev ? [prev.hi.max, -prev.lo.min].max : 0].max.to_f
              peak = 1.0 if peak <= 0
              b.y Plot::Scale::Symmetric.new(-peak..peak, label: nil)
              # (two areas from 0 draw the min/max envelope: in C, where a
              # band mark's fill is Ruby, 1.3-3 ms a draw)
              if prev
                b.area(prev.hi, x: 0..(prev.frames * r.rate / prev.rate), base: 0.0, color: PREVIOUS)
                b.area(prev.lo, x: 0..(prev.frames * r.rate / prev.rate), base: 0.0, color: PREVIOUS)
              end
              b.area(r.hi, x: 0..r.frames, base: 0.0, color: 0)
              b.area(r.lo, x: 0..r.frames, base: 0.0, color: 0)
            end
            chart = b.build
            charts[view] = [key, chart]
            chart
          rescue StandardError => e
            charts[view] = [key, nil]
            warn "render pane: #{e.class}: #{e.message}"
            nil
          end
        end

        # The inspected graph's code: the knobs it reads at their values now
        # (`knob :cut, (150.hz..8000.hz).at(3100.hz)`), then its Ruby
        # (`to_ruby`), redrawn only when either changes.  Arrows scroll.
        class Code < Pane
          jump 'c'

          def initialize = super(:code, rate: 4, height: 12, width: 56, needs: [:inspect], title: 'code', min_height: 3,
                                        description: 'the inspected graph\'s Ruby (to_ruby) with the knobs it reads at their values now')

          mode_keys do
            group 'Code'
            on 'y', :copy_text, help: "copy the pane's text (OSC 52)"
            on [:up, 'k'], :scroll, -1, help: 'scroll up', label: 'Up Down'
            on [:down, 'j'], :scroll, 1, help: 'scroll down', label: 'Up Down'
            on :page_up, :scroll, -10, help: 'a page up', label: 'PgUp PgDn'
            on :page_down, :scroll, 10, help: 'a page down', label: 'PgUp PgDn'
          end

          # The code's lines for +info+ with the snapshot's +knobs+ (cached
          # in +state+ while neither changes).
          def self.lines(info, knobs, state = {})
            read = info.knobs.filter_map { |kn| knobs.find { |k| k.name == kn } }
            key = [info.code, read.map(&:value)]
            return state[:lines] if state[:lines_of] == key
            out = read.map { |k| Code.knob_line(k) }
            out << '' unless out.empty?
            out << "# #{info.track}: the graph it plays (to_ruby)"
            out.concat((info.code || '# (no recipe: this graph was not built by the DSL)').lines.map(&:chomp))
            state[:lines_of] = key
            state[:lines] = out.freeze
          end

          # `knob :cut, (150.hz..8000.hz).at(3100.hz)` for KnobValue +k+ at
          # its value now.
          def self.knob_line(k)
            "knob #{k.spec.call_args(value: k.value).join(', ')}"
          rescue StandardError
            "knob #{k.name.inspect}, #{TurnGesture.number(k.value)}"
          end

          def draw_body(c, s, state)
            info = s&.inspector
            unless info&.track
              c.puts ['no graph (the inspector follows a playing track)', :dim]
              return
            end
            lines = Code.wrapped(Code.lines(info, s.knobs, state), c.w, state)
            top = state[:top] = state[:top].to_i.clamp(0, [lines.length - c.h, 0].max)
            lines[top, c.h].each_with_index do |(l, role), y|
              c.text(0, y, c.fit(l, c.w), role)
            end
            c.text(c.w - 6, c.h - 1, ' more ', :dim) if top + c.h < lines.length && c.w > 12
          end

          # +lines+ wrapped to +width+ (a hanging indent of 4 past each
          # line's own), as [text, role] pairs (knob lines in the key color,
          # comments dim), cached in +state+ per lines and width.
          def self.wrapped(lines, width, state = {})
            key = [lines.object_id, width]
            return state[:wrapped] if state[:wrapped_of] == key
            out = lines.flat_map { |l|
              role = l.start_with?('knob ') ? :key : l.lstrip.start_with?('#') ? :dim : :text
              ind = l[/\A */].length
              next [[l, role]] if l.length <= width || width - ind < 12
              Canvas.wrap(l.lstrip, width - ind, indent: 4).map { |x| [' ' * ind + x, role] }
            }
            state[:wrapped_of] = key
            state[:wrapped] = out.freeze
          end

          def key_scroll(state, d = 1)
            state[:top] = state[:top].to_i + d
            nil
          end

          # The pane's text for `y` (Tiles#copy_pane copies what is drawn;
          # this is the whole code).
          def full_text(state) = (state[:lines] || []).join("\n")
        end

        # Where the library picker goes (library-core-1 builds the index;
        # this screen's design: find-as-you-type, Enter does the likely
        # action named on the status line, a shortcut per action, a side
        # panel with description, tags, facts, and crosslinks).  A
        # placeholder until the index lands: the inspector never needs it.
        class Picker < Pane
          def initialize = super(:picker, rate: 1, height: 10, width: 30, title: 'library', min_height: 2,
                                          description: 'the library picker (placeholder until the library index lands)')

          LINES = [
            ['the library picker goes here:', :dim],
            ['find-as-you-type, then', :dim],
            ['Enter: the likely action', :dim],
            ['(named on the status line),', :dim],
            ['a key per action, auditions', :dim],
            ['on CUE only.', :dim],
          ].freeze

          def draw_body(c, _s, _state)
            c.line(0, ['find ', :dim], ['▏', :key])
            LINES.each_with_index { |(t, r), i| c.text(0, i + 2, c.fit(t, c.w), r) if i + 2 < c.h }
          end
        end

        # One line about CUE (the phones): parts on CUE, the phones level
        # and CUE/MAIN blend knobs, and what an audition would play.
        class Audition < Pane
          def initialize = super(:audition, rate: 4, height: 1, width: 60, description: 'CUE (the phones): parts cued, the phones level and blend, the audition')

          def draw_body(c, s, _state)
            return c.text(0, 0, 'CUE  no session', :dim) unless s
            cued = s.players.select { |p| p.name.to_s.end_with?('/cue') }.map { |p| p.name.to_s.delete_suffix('/cue') }
            k = s.knobs.to_h { |kv| [kv.name, kv] }
            x = c.line(0, ['CUE ', :title], [cued.empty? ? c.glyph(:off) : c.glyph(:on), cued.empty? ? :dim : :ok], ' ')
            x = c.text(x, 0, cued.empty? ? 'nothing cued' : cued.join(' '), cued.empty? ? :dim : :name)
            if (ph = k[:phones])
              x = c.line(0, ['  phones ', :dim], [Panes.fmt(ph.value), :text], x: x)
            end
            if (mx = k[:cue_mix])
              x = c.line(0, ['  cue_mix ', :dim], [Panes.fmt(mx.value), :text], x: x)
            end
            c.line(0, ["  #{c.glyph(:sep)} audition: ", :dim], ['the picker\'s entry plays here (cue :x, sound)', :dim], x: x)
          end
        end

        # The sound-design screen's keys: the inspector's (from its keymap,
        # so they can't drift) and the ones the design plans (dim, marked
        # later).
        class SoundKeys < Pane
          def initialize = super(:sound_keys, rate: 1, height: 9, width: 40, title: 'keys', min_height: 2,
                                              description: 'the sound-design screen\'s keys: the inspector\'s and the planned ones')

          # Keys the design plans but this build doesn't have yet.
          PLANNED = [
            ['/', 'find in the library'], ['a', 'audition on CUE'], ['Enter', "the picker's likely action"],
            ['S', 'save (name, tags, params)'], ['b', 'A/B against the loaded preset'], ['*', 'favourite'],
          ].freeze

          # [built, planned]: [[keys, help], ...] each; the inspector's
          # bindings grouped by their label ("Up Down": "previous knob /
          # next knob"), fine turns left out (Shift is on the status line).
          def self.rows
            groups = {}
            Inspector.mode_keymap.help_groups.flat_map { |_, rows| rows }.each do |keys, help|
              next if help.include?('fine')
              label = keys.split.length > 2 ? keys.split.first(2).join(' ') : keys
              (groups[label] ||= []) << help.sub(/ \(.*\z/, '')
            end
            [groups.map { |label, helps| [label, helps.uniq.join(' / ')] }, PLANNED]
          end

          def draw_body(c, _s, _state)
            built, planned = SoundKeys.rows
            w = [[built.map { |l, _| l.length }.max.to_i, 10].min, 6].max
            y = 0
            built.each do |label, help|
              break if y >= c.h
              x = c.text(0, y, c.pad(label, w), :key)
              c.text(x + 1, y, c.fit(help, [c.w - x - 1, 0].max), :text)
              y += 1
            end
            planned.each do |label, help|
              break if y >= c.h
              x = c.text(0, y, c.pad(label, w), :dim)
              c.text(x + 1, y, c.fit("#{help} (later)", [c.w - x - 1, 0].max), :dim)
              y += 1
            end
          end
        end
      end
    end
  end
end
