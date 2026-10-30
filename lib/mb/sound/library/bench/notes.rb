module MB
  module Sound
    module Library
      module Bench
        # The maintainer's verdicts and notes on a Bench set, per preset
        # (Bench.read_notes): +set+ (the set Hash from set.json), +presets+
        # (Arrays of PresetNotes in set order), +dry+ (the dry items'
        # notes), and +unmatched+ (note documents of this set naming no
        # item in it).
        Notes = Data.define(:set, :presets, :dry, :unmatched) do
          # Presets with a "Something's wrong" verdict or any note text:
          # the fix list.
          def fixes = presets.select { |p| p.status == :problem || p.status == :notes }

          # Presets every heard item of which sounds good.
          def good = presets.select { |p| p.status == :good }

          # Presets not heard yet.
          def unheard = presets.select { |p| p.status == :unheard }

          def to_h
            {
              'set' => set['id'], 'presets' => presets.map(&:to_h), 'dry' => dry.map(&:to_h),
              'fix' => fixes.map(&:head_path), 'good' => good.map(&:head_path), 'unheard' => unheard.map(&:head_path),
              'unmatched' => unmatched,
            }
          end

          def to_s
            heard = presets.count { |p| p.status != :unheard }
            out = ["Bench set #{set['id']}: #{heard} of #{presets.length} presets heard"]
            presets.each { |p| out << p.to_s }
            dry.each { |d| out << "  dry #{d.material}: #{d.describe}" if d.heard? }
            unless fixes.empty?
              out << '' << 'Fix list:'
              fixes.each { |p| out << "  #{p.head_path}: #{p.problems.join(' | ')}" << "    #{p.console}" }
            end
            out << '' << "Sounds good: #{good.map(&:head_path).join(', ')}" unless good.empty?
            out << "Not heard yet: #{unheard.map(&:head_path).join(', ')}" unless unheard.empty?
            out << "Notes for items not in the set: #{unmatched.join(', ')}" unless unmatched.empty?
            out.join("\n")
          end
        end

        # One item's note document (nil fields when unheard).
        ItemNote = Data.define(:item, :material, :verdict, :text, :blind, :updated) do
          def heard? = !(verdict.to_s.empty? && text.to_s.strip.empty?)

          def describe
            return 'not heard' unless heard?
            [verdict.to_s.empty? ? nil : verdict, text.to_s.strip.empty? ? nil : text.strip.inspect, blind ? '(blind)' : nil].compact.join(' ')
          end

          def to_h = { 'item' => item, 'material' => material, 'verdict' => verdict, 'text' => text, 'blind' => blind, 'updated' => updated }
        end

        # A preset's notes: its head path, family, name, the console line of
        # its first item, and an ItemNote per material.
        PresetNotes = Data.define(:head_path, :family, :name, :console, :items) do
          # :problem (any "Something's wrong"), :notes (text without a
          # problem), :good (every heard item good, no text), :heard (other
          # verdicts: A/B picks), :unheard.
          def status
            heard = items.select(&:heard?)
            return :unheard if heard.empty?
            return :problem if heard.any? { |i| i.verdict.to_s == 'problem' }
            return :notes if heard.any? { |i| !i.text.to_s.strip.empty? }
            return :good if heard.all? { |i| i.verdict.to_s == 'good' }
            :heard
          end

          # "material: verdict "text"" for the heard items that need work.
          def problems
            items.select { |i| i.heard? && (i.verdict.to_s == 'problem' || !i.text.to_s.strip.empty?) }.map { |i| "#{i.material}: #{i.describe}" }
          end

          def to_s
            line = "  #{head_path.ljust(30)} #{status}"
            details = items.select(&:heard?).map { |i| "#{i.material} #{i.describe}" }
            details.empty? ? line : "#{line}: #{details.join('; ')}"
          end

          def to_h
            { 'head_path' => head_path, 'family' => family, 'name' => name, 'status' => status.to_s, 'console' => console, 'items' => items.map(&:to_h) }
          end
        end

        module_function

        # The Bench page's document id for an item id (its notes
        # collection: characters outside A-Za-z0-9_- become _).
        def doc_id(item) = item.to_s.gsub(/[^A-Za-z0-9_-]/, '_')

        # The set Hash for +set+: a set id (a directory under +root+), a
        # set directory, or a set.json path.
        def load_set(set, root: default_root)
          path = set.to_s
          path = File.join(root, path) unless File.exist?(path)
          path = File.join(path, 'set.json') if File.directory?(path)
          raise Error, "no Bench set #{set.inspect} (looked for #{path})" unless File.file?(path)
          JSON.parse(File.read(path))
        end

        # The note documents of an export of the Bench's `notes` collection
        # (+notes+: a path, JSON text, or parsed JSON), as { doc id =>
        # Hash }.  Takes the shapes exports come in: { id => doc }, [doc,
        # ...] with `id` or `item`, [{ id:, data: doc }], or any of those
        # under a `documents`, `docs`, `items`, or `notes` key.
        def note_docs(notes)
          data = notes
          data = File.read(data) if data.is_a?(String) && !data.lstrip.start_with?('{', '[') && File.file?(data)
          data = JSON.parse(data) if data.is_a?(String)
          if data.is_a?(Hash)
            key = %w[documents docs items notes].find { |k| data[k].is_a?(Array) || data[k].is_a?(Hash) }
            return note_docs(data[key]) if key
            return data.to_h { |id, doc| [id.to_s, doc.is_a?(Hash) && doc['data'].is_a?(Hash) ? doc['data'] : doc] }.select { |_, d| d.is_a?(Hash) }
          end
          raise Error, "a notes export is a JSON object or array (got #{data.class})" unless data.is_a?(Array)
          data.each_with_object({}) do |d, h|
            next unless d.is_a?(Hash)
            doc = d['data'].is_a?(Hash) ? d['data'] : d
            id = d['id'] || d['doc_id'] || (doc['item'] && doc_id(doc['item']))
            h[id.to_s] = doc if id
          end
        end

        # Reads the maintainer's verdicts on Bench set +set+ (see #load_set)
        # from +notes+ (see #note_docs).  Returns a Notes.
        def read_notes(set, notes, root: default_root)
          set = load_set(set, root: root) unless set.is_a?(Hash)
          docs = note_docs(notes)
          items = set.dig('bench', 'items') or raise Error, "#{set['id']} is not a preset Bench set (no bench items)"
          used = {}
          by_preset = {}
          dry = []
          items.each do |item, meta|
            doc = docs[doc_id(item)] || docs.values.find { |d| d['item'] == item }
            used[doc_id(item)] = true if doc
            note = ItemNote.new(item: item, material: meta.dig('material', 'key'), verdict: doc&.fetch('verdict', nil), text: doc&.fetch('text', nil),
              blind: doc ? !!doc['blind'] : nil, updated: doc&.fetch('updated', nil))
            if (e = meta['entry'])
              by_preset[e['head_path']] ||= { e: e, console: meta['console'], items: [] }
              by_preset[e['head_path']][:items] << note
            else
              dry << note
            end
          end
          presets = by_preset.map { |path, v| PresetNotes.new(head_path: path, family: v[:e]['family'], name: v[:e]['name'], console: v[:console], items: v[:items]) }
          unmatched = docs.select { |id, d| !used[id] && (d['set'] == set['id'] || id.start_with?(doc_id(set['id']))) }.keys
          Notes.new(set: set, presets: presets, dry: dry, unmatched: unmatched)
        end
      end
    end
  end
end
