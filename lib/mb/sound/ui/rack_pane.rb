module MB
  module Sound
    module UI
      module Panes
        # The rack pane (racks phase V, design/notes/drawing.md): one rack
        # instance in detail, as the clip detail is the matrix's: its path,
        # kind, signature, and latency, its typed ports, its knobs with
        # their values and ranges, its slots, and its inner graph drawn by
        # rank (RackInfo#graph, a Plot::Graph of the rack's stand-in build)
        # in the rest of the pane.  It shows the instance whose knob the
        # racks pane picked (Racks.selected), else the first; in the pane's
        # mode (NAV Enter) arrows pan the drawing (Shift: by a quarter of
        # the pane), Home goes back to its corner, and n/p show the next or
        # previous instance.  These keys only change the view: knobs turn
        # in the racks pane, whose keys run journaled `turn` lines.
        #
        # Data: Snapshot#racks (Rack::RackInfo per instance, from Poll) and
        # knob values from Snapshot#knobs; the drawing was laid out off the
        # painter, so a frame only writes its window into the grid.
        class RackDetail < Pane
          # Columns and rows an arrow pans by.
          STEP = [4, 2].freeze

          mode_keys do
            group 'Rack'
            on [:left, 'h'], :pan, -1, 0, help: 'pan the drawing', label: 'arrows h j k l'
            on [:right, 'l'], :pan, 1, 0, help: 'pan the drawing', label: 'arrows h j k l'
            on [:up, 'k'], :pan, 0, -1, help: 'pan the drawing', label: 'arrows h j k l'
            on [:down, 'j'], :pan, 0, 1, help: 'pan the drawing', label: 'arrows h j k l'
            on [:left, :shift], :pan, -1, 0, :quarter, help: 'pan a quarter of the pane'
            on [:right, :shift], :pan, 1, 0, :quarter, help: 'pan a quarter of the pane'
            on [:up, :shift], :pan, 0, -1, :quarter, help: 'pan a quarter of the pane'
            on [:down, :shift], :pan, 0, 1, :quarter, help: 'pan a quarter of the pane'
            on :home, :home, help: "back to the drawing's corner"
            on 'n', :instance, 1, help: 'the next rack instance'
            on 'p', :instance, -1, help: 'the previous rack instance'
          end

          keys do
            group 'Rack'
            doc 'Enter', 'pan the drawing and change the instance (Esc back to NAV)'
          end

          def priority = :list

          def initialize = super(:rack, rate: 4, height: 16, width: 60, title: 'rack', min_height: 3,
                                        description: "one rack instance: its ports, knobs, slots, and inner graph drawn by rank")

          def draw_body(c, s, state)
            racks = s&.racks || []
            state[:size] = [c.w, c.h]
            if racks.empty?
              c.puts ['no racks ', :dim], ['(arack :dub do |sig| ... end; sig.then(&rack(:dub)))', :dim]
              return
            end
            idx = RackDetail.index(racks, state)
            state[:index] = idx
            r = racks[idx]

            # Header: path kind signature latency (n of N)
            lat = r.latency.nil? ? '' : r.latency.to_i > 0 ? "  lat #{r.latency} smp" : '  lat 0'
            count = racks.length > 1 ? "  #{idx + 1} of #{racks.length}" : ''
            x = c.line(0, [(r.path || r.name || 'rack').to_s, :name], ['  ', nil], [r.kind.to_s, :key], ['  ', nil])
            x = c.text(x, 0, c.fit(r.signature.to_s, [c.w - x - lat.length - count.length, 1].max), :text)
            x = c.text(x, 0, lat, :dim)
            c.text(x, 0, count, :dim)
            y = 1
            return if y >= c.h

            # Ports, typed (optional ones with ?)
            ins = r.ports.map { |p| "#{p[:name]}:#{p[:type]}#{p[:role] == :main || p[:required] ? '' : '?'}" }
            RackDetail.line(c, y, [['in ', :dim], [ins.join(' '), :text], ['  out ', :dim], [r.signature.to_s.split('->').last.to_s.strip, :text]])
            y += 1

            # Knobs on one line: name value (range)
            if y < c.h && !r.knobs.empty?
              values = (s.knobs || []).to_h { |k| [k.name, k] }
              segs = [['knobs', :dim]]
              r.knobs.each do |kn|
                short = Session::Name[kn].leaf.to_s
                k = values[kn]
                spec = k&.spec || r.knob_specs[short.to_sym]
                value = k ? k.value : spec&.default
                unit = spec&.unit ? " #{spec.unit}" : ''
                range = spec ? " (#{Panes.fmt(spec.range.begin)}..#{Panes.fmt(spec.range.end)}#{spec.curve == :exp ? ' exp' : ''})" : ''
                segs << ['  ', nil] << [short, :name] << [" #{Panes.fmt(value)}#{unit}", k ? :key : :dim] << [range, :dim]
              end
              RackDetail.line(c, y, segs)
              y += 1
            end

            # Slots (R3 fills them)
            if y < c.h && c.h > 6
              slots = r.slots.empty? ? 'none (slots come with live swaps, racks R3)' : r.slots.map(&:to_s).join('  ')
              RackDetail.line(c, y, [['slots ', :dim], [slots, r.slots.empty? ? :dim : :text]])
              y += 1
            end
            return if y >= c.h

            g = r.graph
            unless g
              c.text(0, y, c.fit("(no drawing: #{r.name || 'the rack'} didn't build on stand-ins)", c.w), :dim)
              return
            end
            gh = c.h - y
            sx, sy = RackDetail.clamp_scroll(state[:scroll], g, c.w, gh)
            state[:scroll] = [sx, sy]
            g.draw(c.grid, x: c.x, y: c.y + y, w: c.w, h: gh, scroll: [sx, sy], glyphs: c.glyph_set)
            # (more beyond an edge: a dim mark in that corner)
            c.text(c.w - 1, c.h - 1, '…', :dim) if sx + c.w < g.width || sy + gh < g.height
          end

          # Writes [text, role] +segs+ on row +y+, ending in an ellipsis
          # when any of them didn't fit (Canvas#line marks only the segment
          # crossing the edge).
          def self.line(c, y, segs)
            x = 0
            segs.each_with_index do |(str, role), i|
              if x + str.to_s.length > c.w || (x + str.to_s.length == c.w && segs[(i + 1)..].any? { |t, _| !t.to_s.empty? })
                c.text(x, y, Canvas.clip("#{str}…", [c.w - x, 0].max), role)
                return c.w
              end
              x = c.text(x, y, str, role)
            end
            x
          end

          # The instance shown: this placement's pick (n/p, by path), else
          # the racks pane's (Racks.selected), else the first.
          def self.index(racks, state)
            want = state[:path] || Racks.selected
            i = want && racks.index { |r| (r.path || r.name) == want }
            i || 0
          end

          # +scroll+ kept inside the drawing for a window of +w+ x +h+.
          def self.clamp_scroll(scroll, g, w, h)
            sx, sy = scroll || [0, 0]
            [sx.clamp(0, [g.width - w, 0].max), sy.clamp(0, [g.height - h, 0].max)]
          end

          # Pans by +dx+, +dy+ steps (STEP), or quarters of the pane with
          # +size+ :quarter.
          def key_pan(state, dx, dy, size = :step)
            w, h = state[:size] || [40, 10]
            step_x = dx * (size == :quarter ? [w / 4, 1].max : STEP[0])
            step_y = dy * (size == :quarter ? [h / 4, 1].max : STEP[1])
            sx, sy = state[:scroll] || [0, 0]
            # (the next draw clamps it to the drawing)
            state[:scroll] = [[sx + step_x, 0].max, [sy + step_y, 0].max]
            nil
          end

          def key_home(state)
            state[:scroll] = [0, 0]
            nil
          end

          def key_instance(state, d)
            racks = state[:racks] || []
            return 'no rack instances' if racks.empty?

            i = (RackDetail.index(racks, state) + d) % racks.length
            state[:path] = racks[i].path || racks[i].name
            state[:scroll] = [0, 0]
            "rack #{state[:path]} (#{i + 1} of #{racks.length})"
          end

          # Keeps the instances drawn last for #key_instance.
          def draw(c, s, state)
            state[:racks] = s&.racks
            super
          end
        end
      end
    end
  end
end
