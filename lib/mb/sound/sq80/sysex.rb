module MB
  module Sound
    module SQ80
      # Ensoniq ESQ-1 / SQ-80 program SysEx (a parser and writer only: the
      # mapping onto SQ80::Voice is designed in design/notes/sq80.md, not
      # built).  Format: research/sq80-sysex/README.md (the SQ-80 Musician's
      # Manual MIDI implementation, checked against three open-source code
      # bases and local bank dumps).
      #
      # Messages start F0 0F 02 0n (Ensoniq, ESQ family, MIDI channel n),
      # then 01 (one program, 204 nybbles) or 02 (40 programs, 8160
      # nybbles), then F7.  Each 102-byte program travels as nybbles, low
      # first.
      #
      #     programs = SQ80::SysEx.read('bank.syx')   # Programs
      #     programs[3].name                          # => "BRASS " style 6 characters
      #     SQ80::SysEx.write('copy.syx', programs)
      module SysEx
        ENSONIQ = 0x0F
        FAMILY = 0x02
        ONE_PROGRAM = 0x01
        ALL_PROGRAMS = 0x02
        PROGRAM_BYTES = 102
        BANK_PROGRAMS = 40

        # Modulation source numbers (4 bits each).
        MOD_SOURCES = %i[lfo1 lfo2 lfo3 env1 env2 env3 env4 vel vel2 kybd kybd2 wheel pedal xctrl press off].freeze

        # LFO waves (2 bits).
        LFO_WAVES = %i[tri saw square noise].freeze

        # The SQ-80's 75 wave names by number (0..31 are the ESQ-1's).
        WAVES = %w[
          SAW BELL SINE SQUARE PULSE NOISE1 NOISE2 NOISE3 BASS PIANO EL\ PNO VOICE1 VOICE2 KICK REED ORGAN
          SYNTH1 SYNTH2 SYNTH3 FORMT1 FORMT2 FORMT3 FORMT4 FORMT5 PULSE2 SQR\ 2 4\ OCTS PRIME BASS\ 2 E\ PNO2 OCTAVE OCT+5
          SAW\ 2 TRIANG REED\ 2 REED\ 3 GRIT\ 1 GRIT\ 2 GRIT\ 3 GLINT1 GLINT2 GLINT3 CLAV BRASS STRING DIGIT1 DIGIT2 BELL\ 2
          ALIEN BREATH VOICE3 STEAM METAL CHIME BOWING PICK\ 1 PICK\ 2 MALLET SLAP PLINK PLUCK PLUNK CLICK CHIFF THUMP
          LOGDRM KICK\ 2 SNARE TOMTOM HI-HAT DRUMS1 DRUMS2 DRUMS3 DRUMS4 DRUMS5
        ].freeze

        class FormatError < ArgumentError; end

        module_function

        # The Programs in SysEx +source+ (a file name, a binary String, or
        # an Array of bytes): every one- and all-program message in it, in
        # order; other ESQ messages are skipped.  Raises FormatError for
        # malformed data.
        def read(source)
          bytes = case source
                  when Array then source
                  when String then source.encoding == Encoding::BINARY || !File.file?(source) ? source.bytes : File.binread(source).bytes
                  else raise ArgumentError, "SQ-80 SysEx comes from a file name, a binary String, or bytes (got #{source.class})"
                  end

          programs = []
          i = 0
          found = false
          while (start = (i...bytes.length).find { |j| bytes[j] == 0xF0 })
            stop = (start...bytes.length).find { |j| bytes[j] == 0xF7 } or raise FormatError, "SysEx message at byte #{start} has no F7"
            msg = bytes[start..stop]
            i = stop + 1
            next unless msg[1] == ENSONIQ && msg[2] == FAMILY

            count = { ONE_PROGRAM => 1, ALL_PROGRAMS => BANK_PROGRAMS }[msg[4]]
            next unless count

            found = true
            nybbles = msg[5...-1]
            expected = count * PROGRAM_BYTES * 2
            raise FormatError, "SQ-80 #{count == 1 ? 'program' : 'bank'} dump at byte #{start} has #{nybbles.length} data bytes (expected #{expected})" unless nybbles.length == expected
            raise FormatError, "SQ-80 dump at byte #{start} has data bytes over 0x0F (not nybbles)" if nybbles.any? { |n| n > 0x0F }

            nybbles.each_slice(2).map { |lo, hi| lo | (hi << 4) }.each_slice(PROGRAM_BYTES) { |p| programs << Program.decode(p) }
          end
          raise FormatError, 'No ESQ-1/SQ-80 program dump found' unless found

          programs
        end

        # The SysEx bytes (an Array) of +programs+: one all-program message
        # for exactly 40 Programs, else one single-program message each, on
        # MIDI +channel+ (0..15).
        def dump(programs, channel: 0)
          programs = Array(programs)
          head = [0xF0, ENSONIQ, FAMILY, channel & 0x0F]
          nyb = ->(ps) { ps.flat_map(&:to_bytes).flat_map { |b| [b & 0x0F, b >> 4] } }
          if programs.length == BANK_PROGRAMS
            head + [ALL_PROGRAMS] + nyb.(programs) + [0xF7]
          else
            programs.flat_map { |p| head + [ONE_PROGRAM] + nyb.([p]) + [0xF7] }
          end
        end

        # Writes +programs+ to +path+ (see .dump).
        def write(path, programs, channel: 0)
          File.binwrite(path, dump(programs, channel: channel).pack('C*'))
        end
      end

      # One ESQ-1/SQ-80 program in panel units: +name+ (6 characters), +envs+
      # (4 Hashes: l1..l3 -63..63, t1..t4 0..63, second_release, lv 0..63,
      # lv_bits (the LV byte's low two bits, kept as found: the SQ-80's
      # linear/exponential flag is one of them, UNVERIFIED which), t1v,
      # tk), +lfos+ (3: freq, wave, l1, l2, delay, human, reset, mod),
      # +oscs+ (3: octave -3..5, semitone 0..11, fine 0..31, fine_bits (the
      # FINE byte's low three bits, kept as found), mods (two
      # [source, amount]), wave 0..74, level 0..63, on, dca_mods), +dca4+
      # (the final level 0..63), +filter+ (fc 0..127, q 0..31, keyboard
      # 0..63, mods), +flags+ (am sync mono restart_voice restart_env
      # restart_osc cyc), +glide+ 0..63, +pan+ 0..15 (8 center), +pan_mod+
      # ([source, amount]), +split+ (the four split/layer bytes, raw).
      # Every bit the four local test banks set survives #decode and
      # #to_bytes (research/sq80-sysex/README.md); other unused bits are
      # dropped (#to_bytes writes 0).
      Program = Data.define(:name, :envs, :lfos, :oscs, :dca4, :filter, :flags, :glide, :pan, :pan_mod, :split) do
        # A Program from its 102 bytes.
        def self.decode(b)
          raise ArgumentError, "SQ-80 programs are #{SysEx::PROGRAM_BYTES} bytes (got #{b.length})" unless b.length == SysEx::PROGRAM_BYTES

          src = ->(n) { SysEx::MOD_SOURCES[n & 0x0F] }
          s8 = ->(x) { (x >= 128 ? x - 256 : x) >> 1 }
          s7 = ->(x) { x &= 0x7F; x >= 64 ? x - 128 : x }

          envs = Array.new(4) { |e|
            o = 6 + 10 * e
            {
              l1: s8.(b[o]), l2: s8.(b[o + 1]), l3: s8.(b[o + 2]),
              t1: b[o + 3] & 0x3F, t2: b[o + 4] & 0x3F, t3: b[o + 5] & 0x3F, t4: b[o + 6] & 0x3F,
              second_release: b[o + 6] & 0x80 != 0,
              lv: b[o + 7] >> 2, lv_bits: b[o + 7] & 3, t1v: b[o + 8] & 0x3F, tk: b[o + 9] & 0x3F,
            }
          }
          lfos = Array.new(3) { |l|
            o = 0x2E + 4 * l
            {
              freq: b[o] & 0x3F, wave: SysEx::LFO_WAVES[b[o] >> 6], l1: b[o + 1] & 0x3F, l2: b[o + 2] & 0x3F,
              delay: b[o + 3] & 0x3F, human: b[o + 3] & 0x40 != 0, reset: b[o + 3] & 0x80 != 0,
              mod: src.(((b[o + 1] >> 6) << 2) | (b[o + 2] >> 6)),
            }
          }
          oscs = Array.new(3) { |n|
            o = 0x3A + 10 * n
            pitch = b[o] & 0x7F
            {
              octave: pitch / 12 - 3, semitone: pitch % 12, fine: b[o + 1] >> 3, fine_bits: b[o + 1] & 7,
              mods: [[src.(b[o + 2]), s8.(b[o + 3])], [src.(b[o + 2] >> 4), s8.(b[o + 4])]],
              wave: b[o + 5], level: (b[o + 6] & 0x7F) >> 1, on: b[o + 6] & 0x80 != 0,
              dca_mods: [[src.(b[o + 7]), s8.(b[o + 8])], [src.(b[o + 7] >> 4), s8.(b[o + 9])]],
            }
          }
          new(
            name: b[0, 6].pack('C*'),
            envs: envs, lfos: lfos, oscs: oscs,
            dca4: (b[88] >> 1) & 0x3F,
            filter: {
              fc: b[89] & 0x7F, q: b[90] & 0x1F, keyboard: (b[94] >> 1) & 0x3F,
              mods: [[src.(b[91]), s7.(b[92])], [src.(b[91] >> 4), s7.(b[93])]],
            },
            flags: {
              am: b[88] & 0x80 != 0, sync: b[89] & 0x80 != 0, restart_voice: b[92] & 0x80 != 0, mono: b[93] & 0x80 != 0,
              restart_env: b[94] & 0x80 != 0, restart_osc: b[95] & 0x80 != 0, cyc: b[101] & 0x80 != 0,
            },
            glide: b[95] & 0x3F,
            pan: b[100] >> 4, pan_mod: [src.(b[100]), s7.(b[101])],
            split: b[96, 4],
          )
        end

        # The program's 102 bytes.
        def to_bytes
          srcn = ->(s) { SysEx::MOD_SOURCES.index(s) or raise ArgumentError, "Unknown SQ-80 mod source #{s.inspect}" }
          s8 = ->(v) { (v.to_i << 1) & 0xFF }
          s7 = ->(v) { v.to_i & 0x7F }
          bit = ->(f, n) { f ? 1 << n : 0 }
          b = Array.new(SysEx::PROGRAM_BYTES, 0)

          n = name.to_s.ljust(6)[0, 6].bytes
          b[0, 6] = n
          envs.each_with_index do |e, i|
            o = 6 + 10 * i
            b[o], b[o + 1], b[o + 2] = s8.(e[:l1]), s8.(e[:l2]), s8.(e[:l3])
            b[o + 3], b[o + 4], b[o + 5] = e[:t1], e[:t2], e[:t3]
            b[o + 6] = e[:t4] | bit.(e[:second_release], 7)
            b[o + 7] = (e[:lv] << 2) | (e[:lv_bits] || 0)
            b[o + 8], b[o + 9] = e[:t1v], e[:tk]
          end
          lfos.each_with_index do |l, i|
            o = 0x2E + 4 * i
            m = srcn.(l[:mod])
            b[o] = l[:freq] | (SysEx::LFO_WAVES.index(l[:wave]) << 6)
            b[o + 1] = l[:l1] | ((m >> 2) << 6)
            b[o + 2] = l[:l2] | ((m & 3) << 6)
            b[o + 3] = l[:delay] | bit.(l[:human], 6) | bit.(l[:reset], 7)
          end
          oscs.each_with_index do |s, i|
            o = 0x3A + 10 * i
            b[o] = (s[:octave] + 3) * 12 + s[:semitone]
            b[o + 1] = (s[:fine] << 3) | (s[:fine_bits] || 0)
            b[o + 2] = srcn.(s[:mods][0][0]) | (srcn.(s[:mods][1][0]) << 4)
            b[o + 3], b[o + 4] = s8.(s[:mods][0][1]), s8.(s[:mods][1][1])
            b[o + 5] = s[:wave]
            b[o + 6] = (s[:level] << 1) | bit.(s[:on], 7)
            b[o + 7] = srcn.(s[:dca_mods][0][0]) | (srcn.(s[:dca_mods][1][0]) << 4)
            b[o + 8], b[o + 9] = s8.(s[:dca_mods][0][1]), s8.(s[:dca_mods][1][1])
          end
          b[88] = (dca4 << 1) | bit.(flags[:am], 7)
          b[89] = filter[:fc] | bit.(flags[:sync], 7)
          b[90] = filter[:q]
          b[91] = srcn.(filter[:mods][0][0]) | (srcn.(filter[:mods][1][0]) << 4)
          b[92] = s7.(filter[:mods][0][1]) | bit.(flags[:restart_voice], 7)
          b[93] = s7.(filter[:mods][1][1]) | bit.(flags[:mono], 7)
          b[94] = (filter[:keyboard] << 1) | bit.(flags[:restart_env], 7)
          b[95] = glide | bit.(flags[:restart_osc], 7)
          b[96, 4] = split
          b[100] = (pan << 4) | srcn.(pan_mod[0])
          b[101] = s7.(pan_mod[1]) | bit.(flags[:cyc], 7)
          b
        end

        # Oscillator +i+'s (0..2) wave name ("SAW", "FORMT1", ...).
        def wave_name(i)
          SysEx::WAVES.fetch(oscs[i][:wave], "WAVE #{oscs[i][:wave]}")
        end

        # True if the program uses anything only an SQ-80 has (waves 32..74,
        # a second release).
        def sq80_only?
          oscs.any? { |o| o[:wave] >= 32 } || envs.any? { |e| e[:second_release] }
        end

        # A program with every field at its init value (a SAW on OSC1,
        # ENV4 a gate), for building synthetic dumps.
        def self.init(name = 'INIT')
          env = { l1: 0, l2: 0, l3: 0, t1: 0, t2: 0, t3: 0, t4: 0, second_release: false, lv: 0, lv_bits: 0, t1v: 0, tk: 0 }
          off = [[:off, 0], [:off, 0]]
          new(
            name: name,
            envs: [env, env, env, env.merge(l1: 63, l2: 63, l3: 63)],
            lfos: Array.new(3) { { freq: 20, wave: :tri, l1: 0, l2: 0, delay: 0, human: false, reset: false, mod: :off } },
            oscs: Array.new(3) { |i| { octave: 0, semitone: 0, fine: 0, fine_bits: 0, mods: off, wave: 0, level: i == 0 ? 63 : 0, on: i == 0, dca_mods: off } },
            dca4: 63,
            filter: { fc: 127, q: 0, keyboard: 0, mods: off },
            flags: { am: false, sync: false, mono: false, restart_voice: false, restart_env: false, restart_osc: false, cyc: false },
            glide: 0, pan: 8, pan_mod: [:off, 0], split: [0, 0, 0, 0],
          )
        end
      end
    end
  end
end
