module MB
  module Sound
    module Help
      # `help rack(:dub)` explains a rack (racks R2): its kind and ports,
      # its macros with ranges (and their Session knobs while it plays),
      # its latency, where it plays, and its source.  Built from
      # Rack#info / Session::Racks#rack_info (the data a rack pane reads).
      class RackPage
        include Page
        include Text

        def initialize(rack, index)
          @rack = rack
          @index = index
        end

        def to_s
          r = @rack
          session = Session.existing
          infos = (r.name && session&.racks&.[](r.name).equal?(r)) ? (session.racks.rack_info[r.name] || [r.info]) : [r.info]
          info = infos.first
          out = []
          out << "#{c(:title, r.name ? "rack #{r.name.inspect}" : "anonymous #{r.constructor}")}  #{c(:dim, "#{info.kind}, #{info.signature}")}"
          out << c(:head, 'ports')
          info.ports.each do |p|
            role = p[:role] == :main ? 'main input' : (p[:required] ? 'port' : 'optional port')
            out << "  #{pad(c(:key, p[:name].to_s), 18)} #{pad(p[:type].to_s, 8)} #{c(:dim, role)}"
          end
          out << "  #{pad(c(:key, '(output)'), 18)} #{r.out || (r.name && session&.racks&.output_of(r.name)) || '?'}"
          out << c(:head, 'macros') + c(:dim, '  (turn :"name/macro", ...)')
          if info.macro_specs.empty?
            out << "  #{c(:dim, 'none (macro :name, value, range: lo..hi inside the block)')}"
          else
            info.macro_specs.each do |n, spec|
              knobs = infos.select(&:path).flat_map(&:macros).select { |k| k.to_s.split('/').last == n.to_s }
              where = knobs.empty? ? 'not playing' : knobs.map(&:inspect).join(', ')
              out << "  #{pad(c(:key, Session::Racks.macro_text(n, spec)), 34)} #{c(:dim, where)}"
            end
          end
          lat = info.latency
          out << "#{c(:head, 'latency')} #{lat.nil? ? 'unknown' : lat.zero? ? 'none' : "#{lat} samples (#{(lat * 1000.0 / 48000).round(2)} ms at 48 kHz)"}"
          plays = r.name && session ? session.racks.uses(r.name) : nil
          out << "#{c(:head, 'uses')} #{plays}" if plays
          src = (r.to_ruby rescue nil)
          if src
            out << c(:head, 'as Ruby') + c(:dim, '  (rack(:x).to_ruby; save :x, rack(:x) writes a rack document)')
            out << src.lines.map { |l| '  ' + code(l.chomp) }.join("\n")
          end
          out << c(:dim, 'topics: help :racks')
          out.join("\n")
        end
      end
    end
  end
end
