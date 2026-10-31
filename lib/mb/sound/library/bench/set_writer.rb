module MB
  module Sound
    module Library
      module Bench
        # A finished (or listed, with +list+) Bench run: the set +id+, its
        # +dir+, the +jobs+, the +measures+ ({ item => Measure }), the
        # +before+ measures of a --vs run, the +skipped+ entries, +vs+, and
        # the +wall+ seconds.
        # +lufs+ is the loudness the set was matched to.
        Result = Data.define(:id, :dir, :jobs, :measures, :before, :skipped, :vs, :wall, :lufs) do
          # The entries benched.
          def entries = jobs.filter_map(&:entry).uniq

          # Items that rendered silence (no file, not on the set).
          def silent = jobs.select { |j| measures[j.item]&.silent && !measures[j.item].error }

          # Items whose render raised (no file, not on the set).
          def failed = jobs.select { |j| measures[j.item]&.error }

          # Items turned down to the ceiling (under an explicit loudness).
          def peak_bound = jobs.select { |j| (m = measures[j.item]) && !m.missing? && m.peak_bound }

          # Items at the ceiling at the set's loudness: those whose loudest
          # sets the level of the set.
          def sets_level = jobs.select { |j| (m = measures[j.item]) && !m.missing? && m.sets_level }

          # Megabytes of audio written (materials excluded).
          def megabytes
            Dir[File.join(dir, '**', '*.{flac,mp3}')].sum { |f| File.size(f) } / 1e6
          end

          # Mean render seconds per job.
          def per_render
            list = measures.values.map(&:render_seconds)
            list.empty? ? 0.0 : list.sum / list.length
          end

          # Lines for the end of a run.
          def summary
            lines = ["Bench set #{id}: #{entries.length} presets, #{measures.length} renders#{vs ? " (+ #{before.length} from #{vs})" : ''} in #{format('%.1f', wall)} s " \
                     "(#{format('%.2f', per_render)} s each), #{format('%.1f', megabytes)} MB#{lufs ? format(', matched to %.1f LUFS', lufs) : ''}"]
            lines << "  #{dir}/bench_set.py (build_manifest.py: exec it; not published)"
            lines << "  failed, left out: #{failed.map { |j| "#{j.entry&.head_path} #{j.material.key} (#{measures[j.item].error})" }.join('; ')}" unless failed.empty?
            lines << "  silent, left out: #{silent.map { |j| "#{j.entry&.head_path} #{j.material.key}" }.join(', ')}" unless silent.empty?
            lines << "  peak-bound (under the target): #{peak_bound.map { |j| "#{j.entry&.head_path || 'dry'} #{j.material.key}" }.join(', ')}" unless peak_bound.empty?
            lines << "  at the ceiling (they set the level): #{sets_level.map { |j| "#{j.entry&.head_path || 'dry'} #{j.material.key}" }.join(', ')}" unless sets_level.empty?
            lines << "  skipped: #{skipped.map { |e, r| "#{e.respond_to?(:head_path) ? e.head_path : e} (#{r})" }.join(', ')}" unless skipped.empty?
            lines.join("\n")
          end

          def to_s
            return "Bench plan #{id}: #{jobs.length} renders\n#{jobs.map { |j| "  #{j.item}" }.join("\n")}" if measures.empty?
            summary
          end

          def inspect = to_s
        end

        module_function

        # Writes +result+'s set.json and bench_set.py.  Returns the set Hash.
        def write_set(result, title: nil, lufs: result.lufs, ceiling: CEILING, format: 'flac', what: nil, find: nil)
          set = set_hash(result, title: title, lufs: lufs, ceiling: ceiling, format: format, what: what, find: find)
          File.write(File.join(result.dir, 'set.json'), JSON.pretty_generate(set))
          File.write(File.join(result.dir, 'bench_set.py'), bench_set_py(result, set))
          set
        end

        # The set as build_manifest.py reads it (id, title, date, summary,
        # groups of items with variants) plus the `bench` metadata key.
        def set_hash(result, title: nil, lufs: result.lufs, ceiling: CEILING, format: 'flac', what: nil, find: nil)
          here = describe_checkout
          root = File.dirname(result.dir)
          groups = {}
          meta = {}
          result.jobs.each do |j|
            m = result.measures[j.item]
            b = result.before[j.item]
            meta[j.item] = item_meta(j, m, b, root)
            next if m.nil? || m.missing?
            g = groups[j.material.key] ||= {
              'id' => j.material.key.to_s, 'title' => j.material.title,
              'note' => j.material.key == :template ? 'Each preset on the phrase its genre template plays it on (the item notes name it), at that template\'s tempo.' : "#{j.material.about}.",
              'items' => [],
            }
            g['items'] << item_hash(result, j, m, b, here)
          end
          {
            'id' => result.id,
            'title' => title || "Presets: #{slug(what, find).tr('-', ' ')} (#{result.entries.length})",
            'date' => Date.today.iso8601,
            'summary' => summary_text(result, lufs, ceiling, here),
            'groups' => groups.values,
            'bench' => {
              'version' => 1, 'target_lufs' => lufs, 'ceiling' => ceiling, 'format' => format, 'created' => Time.now.utc.iso8601,
              'mb_sound' => here, 'vs' => result.vs, 'what' => Array(what).flatten.map { |w| w.respond_to?(:head_path) ? w.head_path : w.respond_to?(:path) ? w.path : w.to_s },
              'find' => find, 'items' => meta,
              'skipped' => result.skipped.map { |e, r| { 'entry' => e.respond_to?(:head_path) ? e.head_path : e.to_s, 'reason' => r } },
            },
          }
        end

        def summary_text(result, lufs, ceiling, here)
          s = "#{result.entries.length} presets on standard material, every render matched to #{lufs ? format('%.1f', lufs) : '?'} LUFS integrated, " \
              "the loudest every one reaches with its true peak at most #{format('%g', ceiling)} dBTP (the notes say which set it). "
          s << 'Effects: the 4-bar audition mix (beat and bass, pluck, pad, a silent bar for tails), the A7 arp, the jungle break, and a saw pad, after a dry reference of each. ' if result.entries.any? { |e| e.kind == :effect }
          s << 'Instruments: two phrases for their role, then their genre template phrase. ' if result.entries.any? { |e| e.kind == :instrument }
          s << 'Kits: two beats, then a template beat. ' if result.entries.any? { |e| e.kind == :kit }
          s << "Before = #{result.vs}, after = #{here[:branch]} (matched together). " if result.vs
          s << "Rendered by bin/preset_bench.rb (mb-sound #{here[:branch]} #{here[:commit]}). Listen for: which presets sound good as they are, " \
               "which need work (note what), and tags that fit (bright, dark, wide, ...)."
        end

        def item_hash(result, job, m, b, here)
          e = job.entry
          title = e ? e.head_path : "dry (#{job.material.title})"
          code = "#{console_line(job, m)}\n# or: #{shell_line(job, File.dirname(result.dir))}"
          variants = []
          if result.vs && e && b.is_a?(Measure) && !b.missing?
            variants << { 'label' => "before (#{result.vs})", 'role' => 'before', 'file' => audio_path(result, job, 'before', b),
                          'code' => "# in a #{result.vs} checkout:\n#{console_line(job, b)}" }
          end
          after = result.vs && e ? 'after' : nil
          variants << { 'label' => result.vs && e ? "after (#{here[:branch]})" : (e ? e.name.to_s : 'dry'), 'role' => result.vs && e ? 'after' : 'other',
                        'file' => audio_path(result, job, after, m), 'code' => code }
          { 'id' => job.item, 'title' => title, 'note' => item_note(job, m, b, result.vs), 'variants' => variants }
        end

        # The audio path the page serves: audio/<set dir>/[before|after/]<material>/<file>.
        def audio_path(result, job, side, measure)
          ext = File.exist?(File.join(result.dir, *[side].compact, "#{job.file}.mp3")) ? 'mp3' : 'flac'
          ['audio', File.basename(result.dir), side, "#{job.file}.#{ext}"].compact.join('/')
        end

        def level(m)
          return "failed (#{m.error})" if m&.error
          return 'silent' if m.nil? || m.silent
          format('%.1f LUFS, %.1f dBTP, %+.1f dB%s%s%s', m.lufs, m.true_peak, m.gain, m.peak_bound ? ' (peak-bound: under the target to keep the ceiling)' : '',
            m.sets_level ? ' (at the ceiling: the loudest it reaches sets the level of the set)' : '',
            m.cut ? format(', cut at %.0f s and faded', m.seconds) : '')
        end

        def item_note(job, m, b, vs)
          e = job.entry
          return "The dry material, matched like the presets: #{level(m)}." unless e
          tags = e.tags.empty? ? '' : " [#{e.tags.join(', ')}]"
          about = e.about.to_s.strip
          about = "#{about[0, 220].sub(/\s\S*\z/, '')}..." if about.length > 240
          about = "#{about}." unless about.empty? || about.end_with?('.', '...', '!', '?')
          params = e.params.keys
          s = +"#{e.family} :#{e.name} (#{e.kind})#{tags}. #{about}"
          s << ' ' unless about.empty?
          s << "Params: #{params.join(', ')}. " unless params.empty?
          s << "On: #{job.material.about}. " if job.material.key == :template
          s << (vs ? "After: #{level(m)}; before: #{b == :missing ? 'not in that checkout' : level(b)}." : "Level: #{level(m)}.")
          s
        end

        def item_meta(job, m, b, root)
          e = job.entry
          {
            'entry' => e && {
              'name' => e.name.to_s, 'family' => e.family.to_s, 'kind' => e.kind.to_s, 'head_path' => e.head_path, 'tags' => e.tags.map(&:to_s),
              'about' => e.about, 'params' => e.params.keys.map(&:to_s), 'shelf' => e.shelf.name.to_s,
            },
            'material' => { 'key' => job.material.key.to_s, 'title' => job.material.title, 'about' => job.material.about, 'bpm' => job.material.bpm },
            'file' => job.file, 'measure' => m&.to_h&.transform_keys(&:to_s),
            'before' => b == :missing ? 'missing' : b&.to_h&.transform_keys(&:to_s),
            'console' => console_line(job, m), 'shell' => shell_line(job, root),
          }
        end

        # The bench_set.py that build_manifest.py execs (it reads set.json,
        # dropping the `bench` key).
        def bench_set_py(result, set)
          here = set['bench']['mb_sound']
          rows = result.jobs.map { |j|
            m = result.measures[j.item]
            name = j.entry ? "#{j.entry.family}.#{j.entry.name}" : 'dry'
            "#   #{name.ljust(28)} #{j.material.key.to_s.ljust(11)} #{m.nil? || m.missing? ? (m&.error ? 'failed (left out)' : 'silent (left out)') : format('%6.1f LUFS %5.1f dBTP gain %+5.1f dB%s', m.lufs, m.true_peak, m.gain, m.peak_bound ? ' peak-bound' : '')}"
          }
          <<~PY
            # Listening Bench set: #{set['id']} (#{set['date']}): #{set['title']}.  NOT published (the main session decides).
            # Made by bin/preset_bench.rb / Library::Bench (mb-sound #{here[:branch]} #{here[:commit]}#{result.vs ? ", before = #{result.vs}" : ''}).
            # Audio: #{result.dir}/ (publish as audio/#{File.basename(result.dir)}/...); materials/ holds the dry inputs (not published).
            # Every render matched to #{format('%g', set['bench']['target_lufs'])} LUFS, true peak <= #{format('%g', set['bench']['ceiling'])} dBTP (gains below):
            #{rows.join("\n")}
            # Read his verdicts back: bin/preset_bench.rb --notes NOTES_EXPORT.json #{set['id']} -d #{File.dirname(result.dir)}
            import json as _json
            _s = _json.load(open(#{File.join(result.dir, 'set.json').inspect}))
            sets.append({k: v for k, v in _s.items() if k != 'bench'})
          PY
        end
      end
    end
  end
end
