require 'json'
require 'fileutils'
require 'time'

module MB
  module Sound
    module Library
      # Listening Bench sets for library presets (audition-1, 2026-10-30;
      # maintainer: his first deep project is building out the patch and
      # effect libraries by ear, on the Bench).  Bench.run renders every
      # preset of a family, kind, list, or find query on standard
      # material (Bench::Material: instruments on phrases for their role
      # and their genre template's phrase, kits on beats, effects on the
      # A7 arp, the jungle break, and a saw pad), each matched to one
      # loudness (TARGET_LUFS integrated, true peak at most CEILING), and
      # writes a Bench set directory: audio per material, `set.json` (the
      # set as the Bench's build_manifest.py reads it, plus a `bench` key
      # with per item measurements), and `bench_set.py` (the line
      # build_manifest.py execs).  Bench.read_notes turns an export of the
      # Bench's `notes` collection back into per preset verdicts.
      #
      #     L.fx.reverb.bench                      # console: every reverb
      #     L.inst.dnb.bench(materials: [:template])
      #     bin/preset_bench.rb reverb -d /app/tmp/listening
      #
      # Each render is built and played inside its own render (the
      # material's tempo, a fresh seed 0), so a preset sounds the same in
      # any order and at any time; see design/notes/library.md.
      module Bench
        # The loudness every render is matched to (integrated LUFS).
        TARGET_LUFS = -20.0

        # The highest true peak a render may have (dBTP); a render that
        # would pass it at TARGET_LUFS is turned down to it instead (and
        # marked peak-bound in the set).
        CEILING = -1.0

        # Fade at the end of a render cut at its material's max_seconds.
        FADE_SECONDS = 0.5

        # Families never auditioned unless named (feedback, 2026-10-19: no
        # SQ-80 in demos until the maintainer lifts the ban).
        BANNED = { sq80: 'SQ-80 is banned from demos (name the entries to bench them anyway)' }.freeze

        # Kinds with materials (see Bench.materials_for).
        KINDS = %i[instrument effect kit clip].freeze

        # Keys of a Bench set item and variant that build_manifest.py and
        # the page read (the rest of set.json is the `bench` key).
        ITEM_KEYS = %w[id title note variants].freeze
        VARIANT_KEYS = %w[label role file code].freeze

        # One render to make: the +item+ id, the +entry+, the +material+,
        # and the +file+ it writes (relative to the set directory).
        Job = Data.define(:item, :entry, :material, :file)

        # What a render measured: integrated +lufs+ and +true_peak+ after
        # matching, the +gain+ applied (dB), +peak_bound+ (true if the
        # ceiling, not the target, set the gain), +seconds+ of audio,
        # +cut+ (true if it was cut at max_seconds and faded), and
        # +render_seconds+ (wall time).  +silent+ renders wrote no file.
        # +error+ is the message of a render that raised (no file either).
        Measure = Data.define(:lufs, :true_peak, :gain, :peak_bound, :seconds, :cut, :render_seconds, :silent, :error) do
          def initialize(lufs: nil, true_peak: nil, gain: nil, peak_bound: false, seconds: 0.0, cut: false, render_seconds: 0.0, silent: false, error: nil)
            super
          end

          # True if there is no file (silent or failed).
          def missing? = silent || !error.nil?

          def to_h = super.transform_values { |v| v.is_a?(Float) ? v.round(3) : v }
        end

        # A collecting output for renders (no file, no clipping): float
        # buffers, joined by #data.
        class Capture
          attr_reader :channels, :sample_rate, :buffer_size

          def initialize(channels: 2, sample_rate: 48000, buffer_size: 800)
            @channels = channels
            @sample_rate = sample_rate
            @buffer_size = buffer_size
            @buffers = Array.new(channels) { [] }
            @closed = false
          end

          def write(data)
            data.each_with_index { |c, i| @buffers[i] << Numo::SFloat.cast(c) if i < @channels }
          end

          def data
            @buffers.map { |list| list.empty? ? Numo::SFloat[] : Numo::SFloat.hstack(list) }
          end

          def close = (@closed = true)
          def closed? = @closed
        end

        module_function

        # Where Bench sets go when no directory is given: $MB_SOUND_BENCH_DIR,
        # else tmp/listening in the project (GraphIO.project_dir) or the
        # working directory.
        def default_root
          ENV['MB_SOUND_BENCH_DIR'] || File.join(GraphIO.project_dir || Dir.pwd, 'tmp', 'listening')
        end

        # The entries for +specs+ (each a family, kind, or entry name
        # Symbol/String, `family.name`, a head path like 'L.fx.reverb', an
        # Entry, a Query, or an Array of those) and +find+ (a find query),
        # deduplicated, with what was skipped: [entries, skipped] where
        # skipped is [[entry or spec, reason], ...].
        def select(specs, find: nil)
          found = []
          skipped = []
          named = {}
          Array(specs).flatten.each do |spec|
            list, explicit = resolve(spec)
            list.each { |e| named[[e.family, e.name]] = true if explicit; found << e }
          end
          find&.then { |q| found.concat(Library.index.find(q, limit: 1000).entries) }
          seen = {}
          entries = found.select { |e| seen[[e.family, e.name]] ? false : (seen[[e.family, e.name]] = true) }
          entries = entries.select { |e|
            reason = skip_reason(e, named[[e.family, e.name]])
            skipped << [e, reason] if reason
            reason.nil?
          }
          [entries, skipped]
        end

        # [entries, explicit] for one selection spec (explicit when the
        # spec named the entry itself).
        def resolve(spec)
          case spec
          when Entry then [[spec], true]
          when Heads::Query, Index::Results then [spec.entries, false]
          when Symbol, String
            text = spec.to_s.strip
            return head_path(text) if text.match?(/\A(L\.|MB::Sound::L\.)/)
            fam, name = text.split('.', 2)
            return head_path("L.#{text}") if name && (HEADS.key?(fam.to_sym) || fam == 'all')
            if name
              e = entry(fam, name) or
                raise ArgumentError, "no #{fam} :#{name} in the library#{Library.suggest(name.to_sym, Library.index.entries(family: fam.to_sym).map(&:name))}"
              return [[e], true]
            end
            sym = text.to_sym
            return [Library.index.entries(family: sym), false] if Library.families.key?(sym) || Library.index.entries(family: sym).any?
            return [Library.index.entries(kind: sym), false] if Library::KINDS.include?(sym)
            by_name = Library.index.entries.select { |e| e.name == sym }
            return [by_name, true] unless by_name.empty?
            words = Library.families.keys + Library::KINDS + Library.index.entries.map(&:name)
            raise ArgumentError, "#{text.inspect} is no family, kind, or entry name#{Library.suggest(sym, words.uniq)}"
          else
            raise ArgumentError, "bench what? #{spec.inspect} (a family like :reverb, a kind like :effect, an entry, a head path, or find:)"
          end
        end

        # The entry +name+ of +family+ (Strings or Symbols; graph documents
        # too, which Index#lookup leaves to `preset`), or nil.
        def entry(family, name)
          family = family.to_sym
          name = name.to_sym
          Library.index.lookup(family, name, note: false) || Library.index.entries(family: family).find { |e| e.name == name }
        end

        # Entries under a head path ('L.fx.reverb', 'L.inst.dnb_reese').
        def head_path(text)
          words = text.sub(/\AMB::Sound::/, '').split('.').drop(1).map(&:to_sym)
          head = words.shift
          node = head == :all ? Heads::Root.new.all : (HEADS.key?(head) ? Heads::Root.new.public_send(head) : nil)
          raise ArgumentError, "no head #{head.inspect} (#{[*HEADS.keys, :all].join(', ')})" unless node
          words.each { |w| node = node.word(w) }
          node.is_a?(Entry) ? [[node], true] : [node.entries, false]
        end

        # Why +entry+ isn't benched (nil if it is).
        def skip_reason(entry, explicit)
          return "a #{entry.kind} (Bench sets cover #{KINDS.join(', ')})" unless KINDS.include?(entry.kind)
          return BANNED[entry.family] if BANNED.key?(entry.family) && !explicit
          return BANNED[:sq80] if entry.family == :preset && entry.name.to_s.start_with?('sq80_') && !explicit
          nil
        end

        # The jobs for +entries+ in set +set_id+: one per entry and
        # material (+materials+ limits the material keys), plus a dry
        # reference per effect material (+dry+).
        def plan(entries, set_id:, materials: nil, dry: true)
          keys = materials&.map(&:to_sym)
          jobs = []
          entries.each do |e|
            Bench.materials_for(e).each do |m|
              next if keys && !keys.include?(m.key)
              jobs << Job.new(item: item_id(set_id, e, m), entry: e, material: m, file: "#{m.key}/#{e.family}_#{e.name}")
            end
          end
          if dry
            used = jobs.select { |j| j.material.audio? }.map { |j| j.material.key }.uniq
            dry_jobs = EFFECT_MATERIALS.select { |k| used.include?(k) }.map { |k|
              Job.new(item: "#{set_id}.dry.#{k}", entry: nil, material: effect_material(k), file: "#{k}/dry")
            }
            jobs = dry_jobs + jobs
          end
          jobs
        end

        # An item id unique across Bench sets (the notes collection is keyed
        # by item id, so a later set's verdicts never attach to an older
        # set's items).
        def item_id(set_id, entry, material)
          "#{set_id}.#{entry.family}.#{entry.name}.#{material.key}"
        end

        # The graph +entry+ plays on +material+ (a Material or its key):
        # what Entry#audition returns and the Bench renders.  Effects
        # process the dry audio; instruments and kits play the phrase;
        # clips play on their instrument.
        def graph(entry, material = nil)
          material = materials_for(entry).first if material.nil?
          material = (self.material(entry, material) or raise ArgumentError, "no #{material.inspect} material for #{entry.head_path} (#{materials_for(entry).map(&:key).join(', ')})") unless material.is_a?(Material)
          raise ArgumentError, "#{entry.head_path} is a #{entry.kind}: Bench sets cover #{KINDS.join(', ')}" unless KINDS.include?(entry.kind)
          src = material.build
          case entry.kind
          when :clip then Playable.graph(src)
          when :instrument then entry.(src.is_a?(Sequence::Kit) ? src.to_clip : src)
          else entry.(src)
          end
        end

        # Renders +graph+ (or what +build+ returns, built inside the
        # render, so build-time lengths read the material's tempo) into
        # float channels: until it ends or +max_seconds+, at +bpm+, master
        # gain 0 dB.  Returns [channels, cut] (cut true if it ran to
        # max_seconds).
        def render_graph(graph = nil, bpm:, max_seconds:, &build)
          out = Capture.new
          MB::Sound.render(out, gain: 1.0, bpm: bpm, max_seconds: max_seconds) do
            Session.current.add(graph || build.call, on: :now)
          end
          data = out.data
          [data, data[0].length >= (max_seconds * 48000).round - 800]
        end

        # Matches +data+ to +lufs+ (true peak at most +ceiling+): trims a
        # tail more than QUIET_DB below the peak (renders of graphs that
        # never report their end run to max_seconds), else fades the end
        # when +cut+.  Returns [data, Measure fields] (+:cut+ false when
        # the trim found the end).
        def match(data, lufs: TARGET_LUFS, ceiling: CEILING, cut: false)
          data, trimmed = trim(data.map(&:dup))
          cut &&= !trimmed
          fade(data, FADE_SECONDS) if cut
          before = MB::Sound.loudness(data)
          return [data, { silent: true, cut: cut }] if before.integrated.nil? || !before.integrated.finite? || before.integrated < -70
          gain = lufs - before.integrated
          bound = before.true_peak && before.true_peak + gain > ceiling
          gain = ceiling - before.true_peak if bound
          # (BS.1770's absolute gate at -70 LUFS isn't scale-invariant:
          # quiet tail blocks a gain lifts over it lower the integrated
          # loudness, so correct once or twice)
          out = after = nil
          3.times do
            out = data.map { |c| c * 10.0 ** (gain / 20.0) }
            after = MB::Sound.loudness(out)
            off = lufs - after.integrated
            break if bound || off.abs < 0.02 || after.true_peak + off > ceiling
            gain += off
          end
          data = out
          [data, { lufs: after.integrated, true_peak: after.true_peak, gain: gain, peak_bound: bound, silent: false, cut: cut }]
        end

        # How far below the peak a tail counts as ended (see #trim).
        QUIET_DB = -80

        # Seconds kept after the last sample above QUIET_DB (faded).
        TRIM_KEEP = 0.25

        # [data, trimmed]: +data+ cut TRIM_KEEP after its last sample above
        # QUIET_DB re its peak, if that leaves off more than 0.1 s.
        def trim(data)
          peak = data.map { |c| c.empty? ? 0.0 : c.abs.max.to_f }.max.to_f
          return [data, false] if peak <= 0
          thr = peak * 10.0 ** (QUIET_DB / 20.0)
          last = data.map { |c| (c.abs > thr).where.to_a.last || 0 }.max
          keep = [last + 1 + (TRIM_KEEP * 48000).round, data[0].length].min
          return [data, false] if data[0].length - keep < 4800
          data = data.map { |c| c[0...keep].dup }
          fade(data, TRIM_KEEP)
          [data, true]
        end

        # Fades the last +seconds+ of +data+ (in place) to zero.
        def fade(data, seconds)
          n = [(seconds * 48000).round, data[0].length].min
          return data if n < 2
          ramp = Numo::SFloat.linspace(1, 0, n)
          data.each { |c| c[-n..] = c[-n..] * ramp }
        end

        # Renders +job+ into +dir+ (FLAC, or MP3 with +format+ 'mp3').
        # Returns a Measure.
        def render_job(job, dir, lufs: TARGET_LUFS, ceiling: CEILING, format: 'flac', files: nil, raise_errors: false)
          t0 = MB::U.clock_now
          render_job!(job, dir, t0, lufs: lufs, ceiling: ceiling, format: format, files: files)
        rescue StandardError, ScriptError => e
          raise if raise_errors
          Measure.new(render_seconds: MB::U.clock_now - t0, error: "#{e.class}: #{e.message.lines.first&.strip}")
        end

        def render_job!(job, dir, t0, lufs:, ceiling:, format:, files:)
          m = job.material
          m = effect_material(m.key, files: files) if files && m.audio?
          data, cut = MB::Sound.with_seed(0) {
            render_graph(bpm: m.bpm, max_seconds: m.max_seconds) {
              job.entry ? graph(job.entry, m) : m.build
            }
          }
          data, info = match(data, lufs: lufs, ceiling: ceiling, cut: cut)
          path = File.join(dir, "#{job.file}.#{format}")
          unless info[:silent]
            FileUtils.mkdir_p(File.dirname(path))
            write_audio(path, data)
          end
          Measure.new(lufs: info[:lufs], true_peak: info[:true_peak], gain: info[:gain], peak_bound: info[:peak_bound] || false,
            seconds: data[0].length / 48000.0, cut: info[:cut], render_seconds: MB::U.clock_now - t0, silent: info[:silent])
        end

        # Writes +data+ to +path+: FLAC as ffmpeg writes it, MP3 at 320 kbps.
        def write_audio(path, data)
          return MB::Sound.write(path, data, sample_rate: 48000, overwrite: true) unless path.end_with?('.mp3')
          out = MB::Sound.file_output(path, channels: data.length, overwrite: true, bitrate: '320k')
          out.write(data)
          out.close
        end

        # Writes the dry audio materials the plan uses as float WAVs in
        # +dir+/materials (the inputs --vs gives another checkout).
        # Returns { key => path }.
        def write_materials(dir, keys)
          keys.to_h { |k|
            path = File.join(dir, 'materials', "#{k}.wav")
            FileUtils.mkdir_p(File.dirname(path))
            MB::Sound.write(path, audio(k).to_a, sample_rate: 48000, overwrite: true)
            [k.to_s, path]
          }
        end

        # Renders and writes a Bench set for +what+ (see #select; +find:+
        # adds a find query) into +root+/+id+ (default: "presets-<what>-<date>",
        # with -r2, -r3 ... when taken).  +materials+ limits the material
        # keys, +lufs+/+ceiling+ set the match, +format+ 'flac' or 'mp3',
        # +vs+ a git ref or worktree path rendering the same presets as the
        # "before" variants (see Bench.render_elsewhere), +io+ gets one line
        # per render.  Returns a Result.
        def run(what = nil, find: nil, root: default_root, id: nil, title: nil, materials: nil, dry: true, lufs: TARGET_LUFS, ceiling: CEILING,
                format: 'flac', vs: nil, io: $stdout, list: false)
          entries, skipped = select(what, find: find)
          raise ArgumentError, "nothing to bench#{skipped.empty? ? '' : " (skipped: #{skipped.map { |e, r| "#{e.respond_to?(:head_path) ? e.head_path : e}: #{r}" }.join('; ')})"}" if entries.empty?
          id ||= unique_id(root, "presets-#{slug(what, find)}-#{Date.today.iso8601}")
          dir = File.join(File.expand_path(root), id)
          jobs = plan(entries, set_id: id, materials: materials, dry: dry && entries.any? { |e| e.kind == :effect })
          skipped.each { |e, r| io&.puts "skip #{e.respond_to?(:head_path) ? e.head_path : e}: #{r}" }
          return Result.new(id: id, dir: dir, jobs: jobs, measures: {}, before: {}, skipped: skipped, vs: vs, wall: 0.0) if list

          FileUtils.mkdir_p(dir)
          t0 = MB::U.clock_now
          files = write_materials(dir, jobs.select { |j| j.material.audio? }.map { |j| j.material.key }.uniq)
          measures = {}
          jobs.each do |j|
            measures[j.item] = render_job(j, vs && j.entry ? File.join(dir, 'after') : dir, lufs: lufs, ceiling: ceiling, format: format, files: files)
            io&.puts "#{line(j, measures[j.item])}"
          end
          before = vs ? render_elsewhere(vs, jobs, dir, lufs: lufs, ceiling: ceiling, format: format, files: files, io: io) : {}
          result = Result.new(id: id, dir: dir, jobs: jobs, measures: measures, before: before, skipped: skipped, vs: vs, wall: MB::U.clock_now - t0)
          write_set(result, title: title, lufs: lufs, ceiling: ceiling, format: format, what: what, find: find)
          io&.puts result.summary
          result
        end

        # A short slug for set ids from the selection.
        def slug(what, find)
          words = Array(what).flatten.map { |w|
            case w
            when Entry then w.name
            when Heads::Query then w.path.sub(/\AL\./, '')
            else w.to_s.sub(/\A(MB::Sound::)?L\./, '')
            end
          }
          words << find if find
          s = words.join('-').downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')
          s = s[0, 40].sub(/-[^-]*\z/, '') if s.length > 40
          s.empty? ? 'set' : s
        end

        # +base+, or base-r2, base-r3, ... when +root+ has it.
        def unique_id(root, base)
          return base unless File.exist?(File.join(root, base))
          (2..).each { |n| id = "#{base}-r#{n}"; return id unless File.exist?(File.join(root, id)) }
        end

        # One progress line for a render.
        def line(job, m)
          what = job.entry ? job.entry.head_path : 'dry'
          return format('%-34s %-10s failed: %s', what, job.material.key, m.error[0, 200]) if m.error
          return format('%-34s %-10s silent (no file)', what, job.material.key) if m.silent
          format('%-34s %-10s %6.1f LUFS %5.1f dBTP %+5.1f dB%s%s  %.1f s in %.1f s', what, job.material.key, m.lufs, m.true_peak, m.gain,
            m.peak_bound ? ' peak-bound' : '', m.cut ? ' cut' : '', m.seconds, m.render_seconds)
        end

        # The console line playing +job+'s render (what the Bench code
        # panel shows; runnable in bin/sound.rb).
        def console_line(job, measure)
          gain = measure && !measure.missing? ? format('.at(%+.1f.db)', measure.gain).sub('+', '') : ''
          src = job.entry ? "#{job.entry.head_path}.audition(:#{job.material.key})" : "Library::Bench.graph_of(:#{job.material.key})"
          "bpm #{job.material.bpm}; play #{src}#{gain}"
        end

        # The dry graph of an audio material (the dry reference items).
        def graph_of(key) = effect_material(key.to_sym).build

        # The shell command rendering +job+ again into a set of its own.
        def shell_line(job, root)
          return "bin/preset_bench.rb --materials #{job.material.key} -d #{root} reverb.room   # (the dry item comes with any effect)" unless job.entry
          "bin/preset_bench.rb #{job.entry.family}.#{job.entry.name} --materials #{job.material.key} -d #{root}"
        end
      end
    end
  end
end

require_relative 'bench/materials'
require_relative 'bench/elsewhere'
require_relative 'bench/set_writer'
require_relative 'bench/notes'
