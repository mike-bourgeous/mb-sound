require 'weakref'

module MB
  module Sound
    module Sampler
      # Reads SoundFont 2 files (.sf2; the SoundFont 2.04 specification)
      # into Sampler::Instruments: `sf2('GM.sf2', preset: 0)`, or
      # `font = sf2('GM.sf2')` for the Font (`font.presets`, `font[0]`,
      # `font['Strings']`, `font[128, 0]`).
      #
      # Pure Ruby: the RIFF `sfbk` form's INFO list, the `pdta` hydra
      # (phdr/pbag/pmod/pgen, inst/ibag/imod/igen, shdr) read when the file
      # is opened, and the `sdta` sample data (`smpl`, 16 bits, plus `sm24`
      # for 24) read only for the samples a chosen preset plays.  Fonts are
      # cached by file (like Sample['x.flac']) and so are their samples, so
      # presets sharing samples share their playback tables.
      #
      # Mapping (see design/notes/sampler.md, "SoundFont 2"): each preset
      # zone's instrument zones become regions, with the instrument's global
      # zone under each local zone and the preset's generators added (key
      # and velocity ranges intersected), as the specification says.  Keys,
      # velocities, root key (overridingRootKey, else the sample's original
      # pitch), coarse/fine tune and the sample's pitch correction,
      # scaleTuning (keytrack), sample offsets, loop points and sampleModes
      # (0 no loop, 1 continuous, 3 loop until release), initialAttenuation
      # (times #attenuation's EMU factor), pan, linked stereo pairs (one
      # stereo sample), and the default velocity-to-attenuation modulator
      # (veltrack 1: level (velocity)²) map to regions; the volume envelope
      # (delay, attack, hold, decay, sustain, release in timecents and
      # centibels) and initialFilterFc/Q (a lowpass) map to the instrument's
      # envelope and filter, from the zone at C4 of each layer.  Zones that
      # overlap play together as layers (Instrument.layered).  Everything
      # else (LFOs, the modulation envelope, keynum-to-envelope scaling,
      # exclusive classes, modulators in the file, zones whose envelope or
      # filter differs from their layer's) is listed once per preset in a
      # warning (Font#skipped); chorus and reverb sends are ignored quietly.
      #
      # In a graph document the file must be inside the document's directory
      # (GraphIO::FileGuard); bundles copy it as an asset.
      module SF2
        # Generator names by number (the specification's names in
        # snake_case).
        GENERATORS = %i[
          start_addrs_offset end_addrs_offset startloop_addrs_offset endloop_addrs_offset start_addrs_coarse_offset
          mod_lfo_to_pitch vib_lfo_to_pitch mod_env_to_pitch initial_filter_fc initial_filter_q mod_lfo_to_filter_fc
          mod_env_to_filter_fc end_addrs_coarse_offset mod_lfo_to_volume unused1 chorus_effects_send reverb_effects_send
          pan unused2 unused3 unused4 delay_mod_lfo freq_mod_lfo delay_vib_lfo freq_vib_lfo delay_mod_env attack_mod_env
          hold_mod_env decay_mod_env sustain_mod_env release_mod_env keynum_to_mod_env_hold keynum_to_mod_env_decay
          delay_vol_env attack_vol_env hold_vol_env decay_vol_env sustain_vol_env release_vol_env keynum_to_vol_env_hold
          keynum_to_vol_env_decay instrument reserved1 key_range vel_range startloop_addrs_coarse_offset keynum velocity
          initial_attenuation reserved2 endloop_addrs_coarse_offset coarse_tune fine_tune sample_id sample_modes reserved3
          scale_tuning exclusive_class overriding_root_key unused5 end_oper
        ].freeze

        GENERATOR_NUMBERS = GENERATORS.each_with_index.to_h.freeze

        # Instrument-level defaults (the specification's section 8.1.3);
        # generators not listed default to 0.
        DEFAULTS = {
          initial_filter_fc: 13500, delay_mod_lfo: -12000, delay_vib_lfo: -12000, delay_mod_env: -12000,
          attack_mod_env: -12000, hold_mod_env: -12000, decay_mod_env: -12000, release_mod_env: -12000,
          delay_vol_env: -12000, attack_vol_env: -12000, hold_vol_env: -12000, decay_vol_env: -12000,
          release_vol_env: -12000, key_range: [0, 127].freeze, vel_range: [0, 127].freeze, keynum: -1, velocity: -1,
          scale_tuning: 100, overriding_root_key: -1,
        }.freeze

        # Generators that are ranges (two bytes, lo and hi).
        RANGES = %i[key_range vel_range].freeze

        # Generators a preset zone may not set (ignored there; section 8.5).
        INSTRUMENT_ONLY = %i[
          start_addrs_offset end_addrs_offset startloop_addrs_offset endloop_addrs_offset start_addrs_coarse_offset
          end_addrs_coarse_offset startloop_addrs_coarse_offset endloop_addrs_coarse_offset keynum velocity sample_id
          sample_modes exclusive_class overriding_root_key
        ].freeze

        # Generators that are read (mapped, or structural).
        MAPPED = (%i[
          initial_filter_fc initial_filter_q pan delay_vol_env attack_vol_env hold_vol_env decay_vol_env sustain_vol_env
          release_vol_env keynum_to_vol_env_hold keynum_to_vol_env_decay instrument key_range vel_range initial_attenuation
          coarse_tune fine_tune sample_id sample_modes scale_tuning overriding_root_key
          mod_lfo_to_pitch vib_lfo_to_pitch mod_env_to_pitch mod_lfo_to_filter_fc mod_env_to_filter_fc mod_lfo_to_volume
          delay_mod_lfo freq_mod_lfo delay_vib_lfo freq_vib_lfo delay_mod_env attack_mod_env hold_mod_env decay_mod_env
          sustain_mod_env release_mod_env keynum_to_mod_env_hold keynum_to_mod_env_decay
        ] + INSTRUMENT_ONLY - %i[keynum velocity exclusive_class]).freeze

        # What isn't mapped, by the generators that make it matter (listed
        # in Font#skipped when one of them isn't 0).
        UNMAPPED = {
          'exclusive class (choke groups)' => %i[exclusive_class], 'fixed key (keynum)' => %i[keynum], 'fixed velocity' => %i[velocity],
        }.freeze

        # Generators whose key scaling makes per-key values.
        KEYNUM = %i[keynum_to_vol_env_hold keynum_to_vol_env_decay keynum_to_mod_env_hold keynum_to_mod_env_decay].freeze

        # Cents of vibrato at full mod wheel and at full aftertouch (the
        # specification's default modulators; sf2(..., wheel: false) leaves
        # them out).
        WHEEL_VIBRATO = 50.0

        # Generators ignored without a mention: effects sends and unused
        # numbers.
        QUIET = %i[chorus_effects_send reverb_effects_send unused1 unused2 unused3 unused4 unused5 reserved1 reserved2 reserved3 end_oper].freeze

        # The cutoff (Hz) of zones whose filter is open (13500 cents) in a
        # layer where other zones filter.
        OPEN_CUTOFF = 19912.127

        # FluidSynth's (and the EMU hardware's) scale for
        # initialAttenuation, which most fonts are voiced for (see #sf2's
        # +attenuation:+).
        EMU_ATTENUATION = 0.4

        # Sample types (shdr sfSampleType bits).
        MONO = 1
        RIGHT = 2
        LEFT = 4
        LINKED = 8
        COMPRESSED = 0x10 # SF3 (Ogg Vorbis), not part of SoundFont 2.04
        ROM = 0x8000

        # A preset's header: +bank+ (128 for GM percussion), +program+
        # (0..127), +name+, and its index in the file.
        Preset = Data.define(:bank, :program, :name, :index) do
          def to_s = format('%03d:%03d %s', bank, program, name)
          def inspect = "#<SF2 preset #{self}>"
        end

        # A sample header (shdr): positions in sample points of the sdta
        # data (+stop+ and +loop_end+ exclusive), +rate+ (Hz), +pitch+ (the
        # original MIDI key), +correction+ (cents), +link+ (the partner's
        # index), +type+ (bits: MONO, RIGHT, LEFT, LINKED, ROM).
        SampleHeader = Data.define(:name, :start, :stop, :loop_start, :loop_end, :rate, :pitch, :correction, :link, :type, :index)

        # One playable zone of a preset: the instrument zone's generators
        # (global zone under local zone, preset generators added), its key
        # and velocity ranges (intersected with the preset zone's), the
        # SampleHeader, the instrument's name, and the counts of modulators
        # the zones carry.
        Zone = Data.define(:generators, :keys, :vel, :sample, :instrument, :modulators)

        # The presets of a font, listed one per line (`font.presets`).
        class PresetList
          include Enumerable

          def initialize(presets, file)
            @presets = presets.freeze
            @file = file
          end

          def each(&block) = @presets.each(&block)
          def [](i) = @presets[i]
          def length = @presets.length
          alias size length
          def to_a = @presets.dup

          def to_s
            (["#{File.basename(@file.to_s)}: #{@presets.length} preset#{'s' if @presets.length != 1}"] + @presets.map(&:to_s)).join("\n")
          end

          def inspect = to_s

          def pretty_print(pp)
            pp.text(to_s)
          end
        end

        class << self
          # The Font for +path+ (cached while it's in use; a changed file is
          # read again).
          def open(path)
            path = path.to_s
            real = defined?(GraphIO::FileGuard) ? GraphIO::FileGuard.resolve(path, 'reading a SoundFont') : path
            st = File.stat(real.to_s)
            key = [File.expand_path(real.to_s), st.mtime.to_r, st.size]
            @mutex ||= Mutex.new
            @mutex.synchronize {
              @cache ||= {}
              ref = @cache[key]
              font = begin
                ref&.weakref_alive? ? ref.__getobj__ : nil
              rescue WeakRef::RefError
                nil
              end
              unless font
                font = Font.new(real.to_s, name: path)
                @cache[key] = WeakRef.new(font)
              end
              font
            }
          end

          # An Instrument for +preset+ of the font at +path+ (see Font#[]).
          def load(path, preset: nil, name: nil, mips: :octave, attenuation: EMU_ATTENUATION, wheel: true)
            open(path).instrument(preset, name: name, mips: mips, attenuation: attenuation, wheel: wheel, path: path)
          end

          # Seconds for +timecents+.
          def seconds(timecents)
            2.0**(timecents / 1200.0)
          end

          # Hz for absolute cents (8.176 Hz is 0 cents: MIDI key 0).
          def hz(cents)
            8.175798915643707 * 2.0**(cents / 1200.0)
          end
        end

        # A SoundFont file's presets, instruments, and sample headers (read
        # when opened), and its sample data (read when a preset plays it).
        class Font
          # The path the font was opened from, and the file read.
          attr_reader :path, :file

          # The INFO texts by chunk id (e.g. 'INAM' the font's name, 'ICOP'
          # copyright, 'ICMT' comments), and +version+ [major, minor].
          attr_reader :info, :version

          # The SampleHeaders.
          attr_reader :samples

          # +file+ is read; +name+ is the path to print (a graph document's
          # relative name).
          def initialize(file, name: nil)
            @file = file.to_s
            @path = (name || file).to_s
            @info = {}
            @version = nil
            @smpl = nil
            @sm24 = nil
            @presets = []
            @preset_bags = []
            @instruments = []
            @instrument_bags = []
            @pgen = []
            @igen = []
            @samples = []
            @sample_cache = {}
            @warned = {}
            @skipped = {}
            @instrument_cache = {}
            @mutex = Mutex.new
            File.open(@file, 'rb') { |f| read_riff(f) }
          end

          # The font's name (INFO INAM), else the file's.
          def name
            @info['INAM'].to_s.empty? ? File.basename(@path, '.*') : @info['INAM']
          end

          # Every preset, sorted by bank and program (a PresetList).
          def presets
            PresetList.new(preset_headers.sort_by { |p| [p.bank, p.program, p.index] }, @path)
          end

          # The Preset for +selector+: nil (the first by bank and program),
          # an Integer program in bank 0 (GM: 0 is the piano), [bank,
          # program], a Preset, or a name (a String or Symbol: exact, ignoring
          # case, else the one name that contains it).
          def preset(selector = nil)
            list = preset_headers
            raise ArgumentError, "#{@path}: the font has no presets" if list.empty?

            found = case selector
                    when nil then list.min_by { |p| [p.bank, p.program, p.index] }
                    when Preset then list.find { |p| p.index == selector.index }
                    when Integer then list.find { |p| p.bank == 0 && p.program == selector } || list.find { |p| p.program == selector }
                    when Array
                      bank, program = selector.map { |x| Integer(x) }
                      list.find { |p| p.bank == bank && p.program == program }
                    when String, Symbol then preset_named(list, selector.to_s)
                    else raise ArgumentError, "Choose a preset by program, [bank, program], or name (got #{selector.inspect})"
                    end
            raise ArgumentError, "#{@path}: no preset #{selector.inspect}#{suggestions(list, selector)}" unless found
            found
          end

          # An Instrument playing +selector+ (see #preset), +bank+ given
          # separately as `font[128, 0]` (GM percussion).
          def [](selector, program = nil)
            instrument(program.nil? ? selector : [selector, program])
          end

          # The Instrument for preset +selector+ (see #preset), named +name+
          # (the preset's by default), reading tables at level spacing +mips+
          # (:octave by default, as for SFZ), initialAttenuation scaled by
          # +attenuation+ (0.4, FluidSynth's and the EMU hardware's factor,
          # by default; 1.0 for the specification's own centibels), with
          # vibrato from the mod wheel and aftertouch unless +wheel+ is false
          # (the specification's default modulators; a triangle LFO per
          # voice).
          def instrument(selector = nil, name: nil, mips: :octave, attenuation: EMU_ATTENUATION, wheel: true, path: @path)
            p = preset(selector)
            sel = selector.nil? || selector.is_a?(Preset) ? [p.bank, p.program] : selector
            kw = { preset: sel }
            kw[:name] = name if name
            kw[:mips] = mips unless mips == :octave
            kw[:attenuation] = attenuation unless attenuation == EMU_ATTENUATION
            kw[:wheel] = false unless wheel
            lineage = [:sf2, :sf2, [path], kw].freeze
            key = [p.index, name, mips, attenuation, !!wheel]
            inst = @mutex.synchronize { @instrument_cache[key] } || build(p, name: name || p.name, mips: mips, attenuation: attenuation, wheel: wheel).tap { |i|
              @mutex.synchronize { @instrument_cache[key] ||= i }
            }
            inst.with_lineage(lineage)
          end

          # The default preset's instrument plays (see Instrument#play), so
          # `sf2(path).play(v)` works.
          def play(source = nil, **options) = instrument.play(source, **options)

          # See Instrument#sampler.
          def sampler(source, **options, &block) = instrument.sampler(source, **options, &block)

          # What preset +selector+'s instrument leaves out: a Hash of
          # descriptions and zone counts (warned about once when built).
          def skipped(selector = nil)
            p = preset(selector)
            zones(p) unless @skipped.key?(p.index)
            @skipped[p.index].dup
          end

          # The Zones of preset +selector+, in file order.
          def zones(selector = nil)
            p = preset(selector)
            skipped = Hash.new(0)
            out = []
            pz = zone_list(@presets, @preset_bags, @pgen, p.index)
            pglobal, plocal = split_global(pz, :instrument)
            plocal.each do |pzone|
              pg = pglobal.merge(pzone[:gens]).reject { |k, _| INSTRUMENT_ONLY.include?(k) }
              inst = pzone[:gens][:instrument]
              next skipped['preset zones naming a missing instrument'] += 1 unless inst && inst < header_count(@instruments)

              iz = zone_list(@instruments, @instrument_bags, @igen, inst)
              iglobal, ilocal = split_global(iz, :sample_id)
              ilocal.each do |izone|
                g = Hash.new(0).update(DEFAULTS).update(iglobal).update(izone[:gens])
                pg.each { |k, v| g[k] = RANGES.include?(k) || k == :instrument ? g[k] : g.fetch(k, 0) + v }
                keys = intersect(g[:key_range], pg[:key_range] || [0, 127])
                vel = intersect(g[:vel_range], pg[:vel_range] || [0, 127])
                next unless keys && vel # (a preset zone choosing part of an instrument)

                sh = @samples[g[:sample_id]]
                next skipped['zones naming a missing sample'] += 1 unless sh && g[:sample_id] < header_count(@samples)
                next skipped['zones playing ROM samples (not in the file)'] += 1 if sh.type & ROM != 0
                next skipped['zones playing compressed (SF3) samples'] += 1 if sh.type & COMPRESSED != 0
                next skipped['zones playing empty samples'] += 1 if sh.stop <= sh.start

                UNMAPPED.each { |what, gens| skipped[what] += 1 if gens.any? { |k| g[k] != DEFAULTS.fetch(k, 0) } }
                g.each do |k, v|
                  next if MAPPED.include?(k) || QUIET.include?(k) || UNMAPPED.each_value.any? { |l| l.include?(k) } || v == DEFAULTS.fetch(k, 0)
                  skipped[k.to_s] += 1
                end
                mods = pzone[:mods] + izone[:mods]
                skipped['modulators (only the default velocity-to-attenuation one is mapped)'] += 1 if mods > 0
                out << Zone.new(generators: g.freeze, keys: keys, vel: vel, sample: sh, instrument: @instruments[inst][0], modulators: mods)
              end
            end
            @mutex.synchronize { @skipped[p.index] ||= skipped.freeze }
            out
          end

          # The audio of sample header +index+ (an SFloat, -1..1).
          def sample_data(index)
            sh = @samples.fetch(index)
            raise ArgumentError, "#{@path}: sample #{sh.name.inspect} isn't in the file (ROM or compressed)" if sh.type & (ROM | COMPRESSED) != 0
            raise ArgumentError, "#{@path}: the font has no sample data" unless @smpl

            count = @smpl[1] / 2
            a = sh.start.clamp(0, count)
            b = sh.stop.clamp(a, count)
            return Numo::SFloat.zeros(1) if b <= a
            n = b - a
            File.open(@file, 'rb') { |f|
              words = Numo::Int16.from_binary(f.pread(n * 2, @smpl[0] + a * 2))
              if @sm24
                low = Numo::UInt8.from_binary(f.pread(n, @sm24[0] + a))
                (Numo::DFloat.cast(words) * 256 + Numo::DFloat.cast(low)).then { |x| Numo::SFloat.cast(x / 8388608.0) }
              else
                Numo::SFloat.cast(words) / 32768.0
              end
            }
          end

          def to_s
            "#{name} (#{File.basename(@path)}: #{preset_headers.length} presets, #{[@samples.length - 1, 0].max} samples)"
          end

          def inspect
            "#<#{self.class.name} #{self}>"
          end

          private

          # --- Reading the file -------------------------------------------

          def read_riff(f)
            size = f.size
            head = f.read(12)
            unless head && head.bytesize == 12 && head[0, 4] == 'RIFF' && head[8, 4] == 'sfbk'
              raise ArgumentError, "#{@path} isn't a SoundFont 2 file (no RIFF sfbk header)"
            end
            stop = [8 + head[4, 4].unpack1('V'), size].min
            each_chunk(f, 12, stop) do |id, offset, length|
              next unless id == 'LIST' && length >= 4
              f.seek(offset)
              type = f.read(4)
              case type
              when 'INFO' then each_chunk(f, offset + 4, offset + length) { |i, o, l| @info[i] = text(f, o, l) unless i == 'ifil' || l > 65536; @version = f.pread(4, o).unpack('vv') if i == 'ifil' && l >= 4 }
              when 'sdta'
                each_chunk(f, offset + 4, offset + length) { |i, o, l|
                  @smpl = [o, l - l % 2] if i == 'smpl'
                  @sm24 = [o, l] if i == 'sm24'
                }
              when 'pdta' then read_pdta(f, offset + 4, offset + length)
              end
            end
            raise ArgumentError, "#{@path}: no pdta (preset data) list" if @presets.empty?
            # sm24 must hold one byte per smpl word (section 6.2), else it's ignored
            @sm24 = nil if @sm24 && (@smpl.nil? || @sm24[1] < @smpl[1] / 2)
          end

          # Yields [id, data offset, data length] for the chunks between
          # +start+ and +stop+ (lengths clamped to +stop+; odd sizes padded).
          def each_chunk(f, start, stop)
            pos = start
            while pos + 8 <= stop
              head = f.pread(8, pos)
              break unless head && head.bytesize == 8
              id = head[0, 4]
              length = head[4, 4].unpack1('V')
              data = pos + 8
              length = [length, stop - data].min
              yield id, data, length
              pos = data + length + (length.odd? ? 1 : 0)
            end
          end

          def text(f, offset, length)
            f.pread(length, offset).to_s.unpack1('Z*').force_encoding('ISO-8859-1').encode('UTF-8').strip
          end

          def read_pdta(f, start, stop)
            chunks = {}
            each_chunk(f, start, stop) { |id, o, l| chunks[id] = f.pread(l, o).to_s }
            records = ->(id, size, format) {
              data = chunks[id].to_s
              Array.new(data.bytesize / size) { |i| data.byteslice(i * size, size).unpack(format) }
            }
            latin = ->(s) { s.force_encoding('ISO-8859-1').encode('UTF-8').strip }

            @presets = records.('phdr', 38, 'Z20vvvVVV').map { |name, program, bank, bag, *| [latin.(name), program, bank, bag] }
            @preset_bags = records.('pbag', 4, 'vv')
            @pgen = records.('pgen', 4, 'vs<')
            @instruments = records.('inst', 22, 'Z20v').map { |name, bag| [latin.(name), bag] }
            @instrument_bags = records.('ibag', 4, 'vv')
            @igen = records.('igen', 4, 'vs<')
            @samples = records.('shdr', 46, 'Z20VVVVVCcvv').each_with_index.map { |(name, s, e, ls, le, rate, pitch, corr, link, type), i|
              SampleHeader.new(name: latin.(name), start: s, stop: e, loop_start: ls, loop_end: le, rate: rate, pitch: pitch, correction: corr, link: link, type: type, index: i)
            }
            raise ArgumentError, "#{@path}: the pdta list has no presets" if @presets.empty?
          end

          # The presets (without the terminal record), as Presets.
          def preset_headers
            @preset_headers ||= begin
              @presets.first(header_count(@presets)).each_with_index.map { |(name, program, bank, _), i| Preset.new(bank: bank, program: program, name: name, index: i) }.freeze
            end
          end

          # The number of records of a header list without its terminal
          # record: the last record when it's named EOP, EOI, or EOS, or
          # looks like one (no zones after it; an empty sample), so a file
          # missing its terminals keeps its last preset, instrument, or
          # sample.
          def header_count(list)
            return 0 if list.empty?
            last = list[-1]
            terminal = if list.equal?(@samples)
                         last.name.match?(/\AEOS/i) || (last.start == 0 && last.stop == 0)
                       else
                         bags = list.equal?(@presets) ? @preset_bags : @instrument_bags
                         last[0].match?(/\AEO[PI]/i) || last[-1] >= bags.length - 1
                       end
            terminal && list.length > 1 ? list.length - 1 : list.length
          end

          def preset_named(list, name)
            down = name.downcase
            exact = list.select { |p| p.name.downcase == down }
            return exact.min_by { |p| [p.bank, p.program] } unless exact.empty?
            partial = list.select { |p| p.name.downcase.include?(down) }
            return partial[0] if partial.length == 1
            raise ArgumentError, "#{@path}: #{name.inspect} matches #{partial.length} presets: #{partial.first(8).map(&:to_s).join(', ')}" if partial.length > 1
            nil
          end

          def suggestions(list, selector)
            return '' unless selector.is_a?(String) || selector.is_a?(Symbol)
            names = DidYouMean::SpellChecker.new(dictionary: list.map(&:name)).correct(selector.to_s)
            names.empty? ? '' : " (did you mean #{names.first(3).map(&:inspect).join(', ')}?)"
          rescue NameError
            ''
          end

          # The zones of +headers+[+index+] (a preset or an instrument):
          # [{ gens:, mods: }], the generators by name (the last of a
          # repeated generator wins).
          def zone_list(headers, bags, gens, index)
            first = headers[index][-1]
            last = index + 1 < headers.length ? headers[index + 1][-1] : bags.length - 1
            last = [last, bags.length - 1].min
            first = [first, last].min
            (first...last).map { |b|
              g0, m0 = bags[b]
              g1, m1 = bags[b + 1]
              g1 = [g1, gens.length].min
              g0 = [g0, g1].min
              zone = {}
              gens[g0...g1].each do |oper, amount|
                name = GENERATORS[oper] or next
                zone[name] = RANGES.include?(name) ? [amount & 0xff, (amount >> 8) & 0xff].freeze : amount
                zone[name] = amount & 0xffff if name == :instrument || name == :sample_id || name == :sample_modes
              end
              { gens: zone, mods: [m1.to_i - m0.to_i, 0].max }
            }
          end

          # [global generators, local zones] (the first zone is global when
          # it doesn't name +terminal+; later zones without it are ignored).
          def split_global(zones, terminal)
            global = {}
            if zones[0] && !zones[0][:gens].key?(terminal)
              global = zones[0][:gens].reject { |k, _| k == terminal }
              zones = zones.drop(1)
            end
            [global, zones.select { |z| z[:gens].key?(terminal) }]
          end

          def intersect(a, b)
            lo = [a[0], b[0]].max
            hi = [a[1], b[1]].min
            lo <= hi ? [lo, hi].freeze : nil
          end

          # --- Building instruments ---------------------------------------

          def build(p, name:, mips:, attenuation:, wheel:)
            zones = zones(p)
            raise ArgumentError, "#{@path}: preset #{p} has no playable zones" if zones.empty?

            parts = pair_stereo(zones)
            layers = []
            parts.each do |part|
              layer = layers.find { |l| l.none? { |q| overlap?(q, part) } }
              layer ? layer << part : layers << [part]
            end

            warn_skipped(p)

            insts = layers.each_with_index.map { |parts_in_layer, n|
              envelope, filter, modulation = layer_settings(parts_in_layer, wheel)
              Instrument.new(mips: mips, envelope: envelope, filter: filter, modulation: modulation, name: layers.length == 1 ? name : "#{name} layer #{n + 1}") { |i|
                parts_in_layer.each { |q| add_region(i, q, attenuation) }
              }
            }
            insts.length == 1 ? insts[0] : Instrument.layered(insts, name: name, mips: mips)
          end

          # The zones as parts ({ zone:, right: zone or nil, index: }),
          # linked stereo pairs with the same ranges joined.
          def pair_stereo(zones)
            used = {}
            parts = []
            zones.each_with_index do |z, i|
              next if used[i]
              used[i] = true
              partner = nil
              if z.sample.type & (LEFT | RIGHT) != 0
                j = zones.each_index.find { |k|
                  !used[k] && zones[k].sample.index == z.sample.link && zones[k].keys == z.keys && zones[k].vel == z.vel &&
                    zones[k].sample.type & (LEFT | RIGHT) != 0 && zones[k].sample.type & (LEFT | RIGHT) != z.sample.type & (LEFT | RIGHT)
                }
                if j
                  used[j] = true
                  partner = zones[j]
                end
              end
              if partner && z.sample.type & RIGHT != 0
                parts << { zone: partner, right: z, index: i }
              else
                parts << { zone: z, right: partner, index: i }
              end
            end
            parts
          end

          def overlap?(a, b)
            za = a[:zone]
            zb = b[:zone]
            za.keys[0] <= zb.keys[1] && zb.keys[0] <= za.keys[1] && za.vel[0] <= zb.vel[1] && zb.vel[0] <= za.vel[1]
          end

          def inside?(q, key, vel)
            z = q[:zone]
            key.between?(*z.keys) && vel.between?(*z.vel)
          end

          def add_region(inst, part, attenuation)
            z = part[:zone]
            g = z.generators
            sh = z.sample
            base = base_sample(sh, part[:right]&.sample)

            start = (g[:start_addrs_offset] + 32768 * g[:start_addrs_coarse_offset]).clamp(0, base.length - 1)
            stop = (base.length + g[:end_addrs_offset] + 32768 * g[:end_addrs_coarse_offset]).clamp(start + 1, base.length)
            ls = sh.loop_start - sh.start + g[:startloop_addrs_offset] + 32768 * g[:startloop_addrs_coarse_offset]
            le = sh.loop_end - sh.start + g[:endloop_addrs_offset] + 32768 * g[:endloop_addrs_coarse_offset]
            mode = case g[:sample_modes] & 3
                   when 1 then :forward
                   when 3 then :release
                   else :no_loop
                   end
            ls = ls.clamp(start, stop)
            le = le.clamp(start, stop)
            mode = :no_loop if le - ls < 2

            root = g[:overriding_root_key].between?(0, 127) ? g[:overriding_root_key] : (sh.pitch <= 127 ? sh.pitch : 60)
            s = base.with(start: start, stop: stop, root: root, loop: mode == :no_loop ? nil : [ls.to_f, le.to_f], loop_mode: mode)

            pan = g[:pan]
            pan = (pan + part[:right].generators[:pan]) / 2.0 if part[:right]
            pan = 0 if part[:right] && g[:pan] <= -450 && part[:right].generators[:pan] >= 450
            cb = g[:initial_attenuation].clamp(0, 1440) * attenuation
            inst.region(
              s, keys: z.keys[0]..z.keys[1], vel: z.vel[0]..z.vel[1], root: root, keytrack: g[:scale_tuning] / 100.0, veltrack: 1,
              tune: g[:coarse_tune] + (g[:fine_tune] + sh.correction) / 100.0, gain: 10.0**(-cb / 200.0), pan: pan.clamp(-500, 500) / 500.0
            )
          end

          # The Sample of a sample header (with its right channel's), read
          # once per font.
          def base_sample(left, right)
            key = [left.index, right&.index]
            @mutex.synchronize { @sample_cache[key] } || begin
              data = [sample_data(left.index)]
              if right
                r = sample_data(right.index)
                n = [data[0].length, r.length].min
                data = [data[0][0...n].dup, r[0...n].dup]
              end
              rate = left.rate > 0 ? left.rate : 44100
              s = Sample.new(data, sample_rate: rate, name: right ? "#{left.name} + #{right.name}" : left.name, loop_mode: :no_loop)
              @mutex.synchronize { @sample_cache[key] ||= s }
            end
          end

          # The Notes#env options and lowpass ({ cutoff:, quality: } or nil)
          # for the zones of a layer: values that differ from zone to zone
          # (or from key to key, with keynum-to-envelope scaling) are
          # ZoneMaps, read per note by Instrument#play.
          def layer_settings(parts, wheel)
            rows = parts.flat_map { |q|
              z = q[:zone]
              g = z.generators
              if KEYNUM.any? { |k| g[k] != 0 }
                (z.keys[0]..z.keys[1]).map { |k| [[k, k], z.vel, zone_params(g, k)] }
              else
                [[z.keys, z.vel, zone_params(g, 60)]]
              end
            }
            param = ->(name) { ZoneMap.of(rows.map { |keys, vel, values| [keys, vel, values[name]] }) }

            segments = []
            delay = param.(:delay)
            hold = param.(:hold)
            segments << [0, delay, 0] unless delay == 0
            segments << [1, param.(:attack), 0]
            segments << [1, hold, 0] unless hold == 0
            segments << [param.(:sustain), param.(:decay), param.(:decay_curve)]
            segments << [0, param.(:release), 100]
            envelope = { segments: segments, release_at: segments.length - 1, sensitivity: nil }

            sources = {}
            pitch = []
            cutoff = []
            volume = []
            used = ->(name) { rows.any? { |_, _, v| v[name] != 0 } }
            if used.(:mod_env_to_pitch) || used.(:mod_env_to_filter)
              seg = []
              mdelay = param.(:mod_delay)
              mhold = param.(:mod_hold)
              seg << [0, mdelay, 0] unless mdelay == 0
              seg << [1, param.(:mod_attack), 0]
              seg << [1, mhold, 0] unless mhold == 0
              seg << [param.(:mod_sustain), param.(:mod_decay), 0]
              seg << [0, param.(:mod_release), 0]
              sources[:mod_env] = { env: { segments: seg, release_at: seg.length - 1 } }
              pitch << [:mod_env, param.(:mod_env_to_pitch)] if used.(:mod_env_to_pitch)
              cutoff << [:mod_env, param.(:mod_env_to_filter)] if used.(:mod_env_to_filter)
            end
            if used.(:mod_lfo_to_pitch) || used.(:mod_lfo_to_filter) || used.(:mod_lfo_to_volume)
              sources[:mod_lfo] = { lfo: param.(:mod_lfo_freq), delay: param.(:mod_lfo_delay) }
              pitch << [:mod_lfo, param.(:mod_lfo_to_pitch)] if used.(:mod_lfo_to_pitch)
              cutoff << [:mod_lfo, param.(:mod_lfo_to_filter)] if used.(:mod_lfo_to_filter)
              volume << [:mod_lfo, param.(:mod_lfo_to_volume)] if used.(:mod_lfo_to_volume)
            end
            if used.(:vib_lfo_to_pitch) || wheel
              vib = { lfo: param.(:vib_lfo_freq), delay: param.(:vib_lfo_delay), depth: param.(:vib_lfo_to_pitch) }
              vib.merge!(wheel: WHEEL_VIBRATO, pressure: WHEEL_VIBRATO) if wheel
              sources[:vib_lfo] = vib
              pitch << [:vib_lfo, 1]
            end

            filter = nil
            if !cutoff.empty? || rows.any? { |_, _, v| v[:cutoff] < OPEN_CUTOFF }
              filter = { cutoff: param.(:cutoff), quality: param.(:quality) }
            end
            modulation = sources.empty? ? nil : { sources: sources, pitch: pitch, cutoff: cutoff, volume: volume }.reject { |_, v| v.empty? }
            [envelope, filter, modulation]
          end

          # A zone's volume envelope and filter settings for +key+ (keynum
          # scaling of hold and decay): delay, attack (linear), hold, decay
          # (straight in dB, reaching the sustain level after its share of a
          # 100 dB fall), sustain, release (a 100 dB fall), cutoff (Hz;
          # OPEN_CUTOFF for 13500 cents and up), quality.
          def zone_params(g, key)
            t = ->(tc, lo, hi, zero: false) { zero && tc <= -12000 ? 0.0 : SF2.seconds(tc.clamp(lo, hi)).round(6) }
            sus_db = g[:sustain_vol_env].clamp(0, 1000) / 10.0
            mod_sus = 1 - g[:sustain_mod_env].clamp(0, 1000) / 1000.0
            fc = g[:initial_filter_fc].clamp(1500, 13500)
            {
              delay: t.(g[:delay_vol_env], -12000, 5000, zero: true),
              attack: t.(g[:attack_vol_env], -12000, 8000),
              hold: t.(g[:hold_vol_env] + g[:keynum_to_vol_env_hold] * (60 - key), -12000, 5000, zero: true),
              decay: (t.(g[:decay_vol_env] + g[:keynum_to_vol_env_decay] * (60 - key), -12000, 8000) * sus_db / 100.0).round(6),
              decay_curve: sus_db.round(1),
              sustain: sus_db >= 100 ? 0.0 : (10.0**(-sus_db / 20.0)).round(9),
              release: t.(g[:release_vol_env], -12000, 8000),
              cutoff: fc >= 13500 ? OPEN_CUTOFF : SF2.hz(fc).round(3),
              mod_delay: t.(g[:delay_mod_env], -12000, 5000, zero: true),
              mod_attack: t.(g[:attack_mod_env], -12000, 8000),
              mod_hold: t.(g[:hold_mod_env] + g[:keynum_to_mod_env_hold] * (60 - key), -12000, 5000, zero: true),
              mod_decay: (t.(g[:decay_mod_env] + g[:keynum_to_mod_env_decay] * (60 - key), -12000, 8000) * (1 - mod_sus)).round(6),
              mod_sustain: mod_sus.round(6),
              mod_release: t.(g[:release_mod_env], -12000, 8000),
              mod_env_to_pitch: g[:mod_env_to_pitch].clamp(-12000, 12000),
              mod_env_to_filter: g[:mod_env_to_filter_fc].clamp(-12000, 12000),
              mod_lfo_freq: SF2.hz(g[:freq_mod_lfo].clamp(-16000, 4500)).round(6),
              mod_lfo_delay: t.(g[:delay_mod_lfo], -12000, 5000, zero: true),
              mod_lfo_to_pitch: g[:mod_lfo_to_pitch].clamp(-12000, 12000),
              mod_lfo_to_filter: g[:mod_lfo_to_filter_fc].clamp(-12000, 12000),
              mod_lfo_to_volume: g[:mod_lfo_to_volume].clamp(-960, 960),
              vib_lfo_freq: SF2.hz(g[:freq_vib_lfo].clamp(-16000, 4500)).round(6),
              vib_lfo_delay: t.(g[:delay_vib_lfo], -12000, 5000, zero: true),
              vib_lfo_to_pitch: g[:vib_lfo_to_pitch].clamp(-12000, 12000),
              quality: (10.0**((g[:initial_filter_q].clamp(0, 960) / 10.0 - 3.01) / 20.0)).round(6),
            }
          end

          # Warns once per preset about what it leaves out (#skipped).
          def warn_skipped(p)
            notes = skipped(p).map { |k, n| "#{k} (#{n} zone#{'s' if n != 1})" }
            return if notes.empty?
            @mutex.synchronize {
              return if @warned[p.index]
              @warned[p.index] = true
            }
            warn "SF2 #{File.basename(@path)} #{p}: not mapped: #{notes.join(', ')}"
          end
        end
      end
    end
  end
end
