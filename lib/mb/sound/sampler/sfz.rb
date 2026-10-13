require 'pathname'

module MB
  module Sound
    module Sampler
      # Reads SFZ instruments (the text format of sfzformat.com) into a
      # Sampler::Instrument: `sfz('piano/piano.sfz')`.
      #
      # Headers <control> (default_path, note_offset, octave_offset),
      # <global>, <master>, <group>, and <region> nest as usual (a region
      # gets every opcode of the headers above it).  Opcodes read: sample,
      # key, lokey, hikey, pitch_keycenter, lovel, hivel, pitch_keytrack
      # (cents per key), tune (cents), transpose, volume (dB), amplitude (%),
      # offset, end, loop_mode (no_loop, one_shot, loop_continuous,
      # loop_sustain), loop_start/loop_end (also loopstart/loopend),
      # loop_type (forward, alternate), direction (reverse), seq_length,
      # seq_position, lorand, hirand, amp_veltrack (%), and ampeg_attack,
      # ampeg_decay, ampeg_sustain (%), ampeg_release from the first region
      # that has them (one envelope per instrument).  #define $NAME values
      # are substituted.  Other opcodes are counted and listed once in a
      # warning; regions triggered on release are skipped.
      #
      # Sample paths are relative to the SFZ file (and default_path).  In a
      # graph document they must stay inside the document's directory, like
      # every file a document reads (GraphIO::FileGuard).
      module SFZ
        # The opcodes read (others are ignored with one warning).
        OPCODES = %w[
          sample key lokey hikey pitch_keycenter lovel hivel pitch_keytrack tune transpose volume amplitude offset end
          loop_mode loopmode loop_start loop_end loopstart loopend loop_type direction seq_length seq_position lorand hirand amp_veltrack
          ampeg_attack ampeg_decay ampeg_sustain ampeg_release trigger default_path note_offset octave_offset
        ].freeze

        # Opcodes that may be ignored without a warning (mixing, panning,
        # metadata).
        QUIET = %w[pan width position group off_by polyphony note_polyphony label_cc set_cc label_key].freeze

        LOOP_MODES = {
          'no_loop' => :no_loop, 'one_shot' => :one_shot, 'loop_continuous' => :forward, 'loop_sustain' => :release,
        }.freeze

        NOTE_CLASSES = { 'c' => 0, 'd' => 2, 'e' => 4, 'f' => 5, 'g' => 7, 'a' => 9, 'b' => 11 }.freeze

        module_function

        # Reads the SFZ file at +path+ into an Instrument (+mips+ goes to
        # the samples' playback tables; see GraphNode::SamplerVoice).
        def load(path, name: nil)
          path = path.to_s
          real = defined?(GraphIO::FileGuard) ? GraphIO::FileGuard.resolve(path, 'reading an SFZ file') : path
          text = File.read(real)
          parse(text, base: path, name: name || File.basename(path, '.*'))
        end

        # Parses SFZ +text+; sample paths are relative to the directory of
        # +base+ (a file name; a document String keeps its file rules).
        def parse(text, base: nil, name: nil)
          headers = tokenize(text)
          control = {}
          global = {}
          master = {}
          group = {}
          regions = []
          headers.each do |header, ops|
            case header
            when 'control' then control = ops
            when 'global' then global = ops; master = {}; group = {}
            when 'master' then master = ops; group = {}
            when 'group' then group = ops
            when 'region' then regions << global.merge(master).merge(group).merge(ops)
            end
          end

          ignored = Hash.new(0)
          (headers.flat_map { |_, ops| ops.keys } - OPCODES - QUIET).each { |k| ignored[k] += 1 unless k.match?(/\A(?:hi|lo)?cc\d*|_oncc|_curvecc|label/) }
          warn "SFZ #{name}: ignoring opcodes #{ignored.keys.sort.join(', ')}" unless ignored.empty?

          offset = Integer(control['note_offset'] || 0) + 12 * Integer(control['octave_offset'] || 0)
          prefix = control['default_path'].to_s.tr('\\', '/')
          cache = {}
          envelope = nil
          skipped = 0

          inst = Instrument.new(name: name, lineage: nil) { |i|
            regions.each do |r|
              if r['trigger'] && r['trigger'] != 'attack' && r['trigger'] != 'first' && r['trigger'] != 'legato'
                skipped += 1
                next
              end
              raise ArgumentError, "SFZ #{name}: a region has no sample= opcode" unless r['sample']

              file = sample_path(base, prefix + r['sample'].tr('\\', '/'))
              sample = cache[file] ||= Sample.from_file(file)

              key = r['key'] && note(r['key'], offset)
              lo = r['lokey'] ? note(r['lokey'], offset) : key || 0
              hi = r['hikey'] ? note(r['hikey'], offset) : key || 127
              root = r['pitch_keycenter'] ? note(r['pitch_keycenter'], offset) : key || 60
              start = Integer(r['offset'] || 0)
              stop = r['end'] ? Integer(r['end']) + 1 : sample.length
              s = sample.with(start: start.clamp(0, sample.length - 1), stop: stop.clamp(start + 1, sample.length), root: root)

              mode = LOOP_MODES[r['loop_mode'] || r['loopmode']]
              ls = r['loop_start'] || r['loopstart']
              le = r['loop_end'] || r['loopend']
              if ls && le && mode != :one_shot && mode != :no_loop
                range = (Integer(ls) - s.start)..(Integer(le) - s.start)
                loop_mode = r['loop_type'] == 'alternate' ? :ping_pong : (mode || :forward)
                s = s.looped(range, mode: loop_mode)
              elsif mode == :one_shot || mode.nil?
                s = s.with(loop: nil, loop_mode: mode == :one_shot ? :one_shot : :no_loop)
              else
                s = s.with(loop: nil, loop_mode: :no_loop)
              end
              s = s.reverse if r['direction'] == 'reverse'

              gain = 10.0**(Float(r['volume'] || 0) / 20.0) * Float(r['amplitude'] || 100) / 100.0
              seq_len = Integer(r['seq_length'] || 1)
              seq = seq_len > 1 ? [Integer(r['seq_position'] || 1), seq_len] : nil
              rand = r['lorand'] || r['hirand'] ? Float(r['lorand'] || 0)..Float(r['hirand'] || 1) : nil

              envelope ||= envelope_of(r)
              i.region(
                s, keys: lo..hi, vel: Integer(r['lovel'] || 0)..Integer(r['hivel'] || 127), seq: seq, rand: rand, root: root,
                keytrack: Float(r['pitch_keytrack'] || 100) / 100.0, veltrack: Float(r['amp_veltrack'] || 100) / 100.0,
                tune: Float(r['tune'] || 0) / 100.0 + Float(r['transpose'] || 0), gain: gain
              )
            end
          }
          warn "SFZ #{name}: skipped #{skipped} release-triggered region#{'s' if skipped != 1}" if skipped > 0
          envelope ? Instrument.new(inst.regions, chops: inst.chops, envelope: envelope, name: name) : inst
        end

        # [header, { opcode => value }] pairs of +text+ (comments removed,
        # #define substituted).
        def tokenize(text)
          text = text.gsub(%r{/\*.*?\*/}m, ' ')
          defines = {}
          lines = text.each_line.map { |l|
            l = l.sub(%r{//.*}, '')
            if (m = l.match(/\A\s*#define\s+(\$\w+)\s+(\S+)/))
              defines[m[1]] = m[2]
              next ''
            end
            warn "SFZ: #include is not supported (#{l.strip})" if l.match?(/\A\s*#include/)
            next '' if l.match?(/\A\s*#/)
            l
          }
          text = lines.join("\n")
          defines.sort_by { |k, _| -k.length }.each { |k, v| text = text.gsub(k, v) }

          out = []
          text.scan(/<(\w+)>([^<]*)/m) do |header, body|
            ops = {}
            # Values run to the next opcode (sample paths may hold spaces)
            body.scan(/(\w+)=(.*?)(?=\s+\w+=|\s*\z)/m) { |k, v| ops[k] = v.strip }
            out << [header, ops]
          end
          out
        end

        # A note number from an SFZ key value: a number or a name like c#4
        # or eb3 (c4 = 60).
        def note(v, offset = 0)
          n = if v.match?(/\A-?\d+\z/)
                Integer(v)
              elsif (m = v.match(/\A([a-gA-G])([#b]?)(-?\d+)\z/))
                NOTE_CLASSES[m[1].downcase] + { '#' => 1, 'b' => -1 }.fetch(m[2], 0) + 12 * (Integer(m[3]) + 1)
              else
                raise ArgumentError, "SFZ: #{v.inspect} isn't a key"
              end
          n + offset
        end

        # The path of sample +name+ for an SFZ read from +base+ (keeping a
        # graph document's file rules: a name inside the document's
        # directory).
        def sample_path(base, name)
          return name if base.nil?
          joined = Pathname.new(File.dirname(base)).join(name).cleanpath.to_s
          return joined unless GraphIO::FileGuard.document_string?(base)
          GraphIO::FileGuard.register(+joined, base.instance_variable_get(:@graph_io_file_context))
        end

        # [attack, decay, sustain, release] from a region's ampeg_*, or nil.
        def envelope_of(r)
          return nil unless r.keys.any? { |k| k.start_with?('ampeg_') }
          [Float(r['ampeg_attack'] || 0), Float(r['ampeg_decay'] || 0), Float(r['ampeg_sustain'] || 100) / 100.0, Float(r['ampeg_release'] || 0.001)]
        end
      end
    end
  end
end
