require 'digest'

module MB
  module Sound
    module Library
      # Pins of the built-in presets a song used (`collect` pins built-ins;
      # the maintainer, 2026-10-31: "Pin instead"): `collect` writes, into
      # the song's presets/pins.rb, the mb-sound version and a fingerprint
      # of each used built-in's settings, one `pin` line each, and loading
      # the song's shelf warns (once) when a built-in it pinned has changed
      # since.  The built-ins themselves stay with mb-sound (`collect
      # builtin: true` copies them instead, as before).
      #
      #     library 1
      #
      #     # Built-in presets this song used, pinned by collect: loading warns when one changes.
      #     pin :reverb, :hall, mb_sound: "0.12.0 (e720da83)", fingerprint: "6b1e0c..."
      #     pin :preset, :dnb_reese, mb_sound: "0.12.0 (e720da83)", fingerprint: "a07f3d..."
      #
      # A pins file is a library file (FileLoader reads `pin` lines; no
      # eval), so it may sit with the song's other presets.
      module Pins
        # The file collect writes pins into, in the song's presets/.
        FILE = 'pins.rb'

        # The comment above a new file's pins.
        HEADER = '# Built-in presets this song used, pinned by collect: loading warns when one changes.'

        # A pin line: the entry's +family+ and +name+, the +mb_sound+
        # version it was pinned with, its +fingerprint+ then (nil when the
        # entry has nothing to fingerprint), and the line's +location+.
        Pin = Data.define(:family, :name, :mb_sound, :fingerprint, :location) do
          def label = "#{family} #{name.inspect}"

          # The line collect writes for this pin.
          def to_ruby
            parts = [family.inspect, name.inspect, "mb_sound: #{mb_sound.to_s.inspect}"]
            parts << "fingerprint: #{fingerprint.inspect}" if fingerprint
            "pin #{parts.join(', ')}"
          end
        end

        module_function

        # The pin for +entry+ now: this mb-sound's version and the entry's
        # fingerprint.
        def pin_for(entry)
          Pin.new(family: entry.family, name: entry.name, mb_sound: GraphIO.library_version, fingerprint: fingerprint(entry), location: nil)
        end

        # A short hash (16 hex digits of SHA-256) of what makes +entry+
        # sound as it does: a graph document's text (a bundle's files;
        # without the `saved:` and `mb_sound:` header lines, which change on
        # every save), a class preset's settings (a struck instrument's with
        # its resonator preset's), a genre patch's method source; nil for
        # entries with none of those (drum machines: pinned by version
        # only).
        def fingerprint(entry)
          text = fingerprint_text(entry)
          text && Digest::SHA256.hexdigest(text)[0, 16]
        rescue StandardError
          nil
        end

        # The text #fingerprint hashes, or nil.
        def fingerprint_text(entry)
          s = entry.settings
          if s.is_a?(Hash) && s[:document]
            document_text(entry.location)
          elsif entry.family == :struck
            res = GraphNode::ModalResonator.preset_entry(s[:resonator] || entry.name)
            "#{settings_text(s)}\n#{settings_text(res.settings)}"
          elsif entry.family == :genre_patch
            method_source(Genre::Patches, entry.name)
          elsif s.is_a?(Hash)
            settings_text(s)
          end
        end

        # +settings+ as sorted `key: literal` lines.
        def settings_text(settings)
          settings.sort_by { |k, _| k.to_s }.map { |k, v| "#{k}: #{Param.literal(v)}" }.join("\n")
        end

        # A graph document's text (every file of a bundle), without the
        # header lines that change on every save.
        def document_text(path)
          dir = File.dirname(path)
          files = dir.end_with?('.mbg') ? Dir.glob('**/*', base: dir).sort.map { |f| File.join(dir, f) }.select { |f| File.file?(f) } : [path]
          files.map { |f|
            text = File.binread(f)
            text = text.lines.reject { |l| l.match?(/\A\s*(saved|mb_sound):/) }.join if f.end_with?('.rb')
            "#{File.basename(f)}\n#{text}"
          }.join("\n")
        end

        # The source of +mod+'s method +name+ (its def, read with Prism).
        def method_source(mod, name)
          file, line = mod.method(name).source_location
          found = nil
          walk = ->(n) {
            next if found || n.nil?
            found = n if n.is_a?(Prism::DefNode) && n.name == name && n.location.start_line == line
            n.compact_child_nodes.each(&walk)
          }
          walk.(Prism.parse_file(file).value)
          found&.slice
        end

        # Pins +entries+ (built-ins) in the pins file of shelf directory
        # +dir+, creating it: a new pin is added, an equal one kept, a
        # different one (the built-in changed since, or another mb-sound)
        # replaced.  Returns [[entry, status, old pin or nil], ...], status
        # :pinned, :same, or :repinned.
        def write(dir, entries)
          path = File.join(dir, FILE)
          text = File.file?(path) ? File.read(path) : nil
          old = text ? read(text, path) : []
          out = entries.map { |e|
            pin = pin_for(e)
            prev = old.find { |p| p.family == e.family && p.name == e.name }
            if prev.nil?
              text = text ? "#{text.chomp}\n#{pin.to_ruby}\n" : "library #{Library::FORMAT}\n\n#{HEADER}\n#{pin.to_ruby}\n"
              [e, :pinned, nil]
            elsif prev.fingerprint == pin.fingerprint && (pin.fingerprint || prev.mb_sound == pin.mb_sound)
              [e, :same, prev]
            else
              text = replace_line(text, prev, pin)
              [e, :repinned, prev]
            end
          }
          if out.any? { |_, st, _| st != :same }
            FileUtils.mkdir_p(dir)
            File.write(path, text)
          end
          out
        end

        # The pins in library file text +text+ (read like the shelf's
        # files; +path+ for locations).
        def read(text, path)
          loader = FileLoader.new(text, path: path)
          loader.entries(Shelf.new(name: :project, dir: File.dirname(path), label: 'pins'))
          loader.pins
        end

        # +text+ with +prev+'s pin line replaced by +pin+'s.
        def replace_line(text, prev, pin)
          Prism.parse(text).value.statements.body.each do |st|
            next unless st.is_a?(Prism::CallNode) && st.receiver.nil? && st.name == :pin
            a = st.arguments&.arguments || []
            next unless a[0].is_a?(Prism::SymbolNode) && a[1].is_a?(Prism::SymbolNode)
            next unless a[0].unescaped.to_sym == prev.family && a[1].unescaped.to_sym == prev.name
            return text[0...st.location.start_offset] + pin.to_ruby + text[st.location.end_offset..]
          end
          "#{text.chomp}\n#{pin.to_ruby}\n"
        end

        # The warning for +pin+ when the built-in it pins changed or is
        # gone (+entry+ the built-in now, or nil), else nil.
        def change_warning(pin, entry)
          where = "#{pin.location.to_s.delete_prefix("#{Dir.pwd}/")}"
          unless entry
            return "this song pinned the built-in #{pin.label} (mb-sound #{pin.mb_sound}; #{where}), which mb-sound #{GraphIO.library_version} no longer ships"
          end
          now = fingerprint(entry)
          return nil if pin.fingerprint.nil? || now == pin.fingerprint
          "the built-in #{pin.label} has changed since this song pinned it with mb-sound #{pin.mb_sound} (#{where}; now #{GraphIO.library_version}): " \
            'listen, then `collect` pins it as it is now'
        end
      end
    end
  end
end
