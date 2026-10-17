# ESQ-1/SQ-80 program SysEx (SQ80::SysEx, SQ80::Program), with synthetic
# dumps only: no real banks are in the repository.  Set
# MB_SOUND_SQ80_SYX_DIR to a directory of .syx banks to also check that each
# decodes and writes back byte for byte.
RSpec.describe(MB::Sound::SQ80::SysEx) do
  let(:program) { MB::Sound::SQ80::Program }

  # A synthetic program touching every field.
  def busy_program(name)
    base = MB::Sound::SQ80::Program.init(name)
    base.with(
      envs: Array.new(4) { |e| { l1: 63 - e, l2: -40 + e, l3: 12, t1: 1 + e, t2: 30, t3: 42, t4: 50 + e, second_release: e.odd?, lv: 40 + e, lv_bits: e % 4, t1v: 10, tk: 63 } },
      lfos: [
        { freq: 33, wave: :tri, l1: 0, l2: 63, delay: 20, human: true, reset: false, mod: :wheel },
        { freq: 5, wave: :saw, l1: 10, l2: 20, delay: 0, human: false, reset: true, mod: :press },
        { freq: 63, wave: :noise, l1: 63, l2: 63, delay: 63, human: true, reset: true, mod: :off },
      ],
      oscs: [
        { octave: -3, semitone: 0, fine: 31, fine_bits: 4, mods: [[:lfo1, 3], [:env1, -63]], wave: 0, level: 63, on: true, dca_mods: [[:vel, 20], [:off, 0]] },
        { octave: 0, semitone: 7, fine: 3, fine_bits: 0, mods: [[:kybd2, 63], [:wheel, -1]], wave: 27, level: 40, on: true, dca_mods: [[:env3, -5], [:lfo3, 9]] },
        { octave: 5, semitone: 11, fine: 0, fine_bits: 0, mods: [[:off, 0], [:off, 0]], wave: 74, level: 0, on: false, dca_mods: [[:xctrl, 63], [:vel2, -63]] },
      ],
      dca4: 50,
      filter: { fc: 90, q: 31, keyboard: 63, mods: [[:env2, 63], [:press, -63]] },
      flags: { am: true, sync: true, mono: false, restart_voice: true, restart_env: false, restart_osc: true, cyc: true },
      glide: 12, pan: 15, pan_mod: [:lfo2, -20], split: [0x80 | 60, 0x85, 3, 0],
    )
  end

  it 'writes and reads a 40-program bank (8166 bytes) and single programs (210 bytes)' do
    bank = Array.new(40) { |i| i.even? ? busy_program(format('P%02d   ', i)) : program.init(format('INIT%02d', i)) }
    bytes = described_class.dump(bank, channel: 3)
    expect(bytes.length).to eq(8166)
    expect(bytes.first(5)).to eq([0xF0, 0x0F, 0x02, 0x03, 0x02])
    expect(bytes.last).to eq(0xF7)
    expect(bytes[5...-1].max).to be <= 0x0F

    path = tmp_path('bank.syx')
    described_class.write(path, bank)
    expect(described_class.read(path)).to eq(bank)
    expect(described_class.read(bytes)).to eq(bank)

    one = described_class.dump([busy_program('ONE   ')])
    expect(one.length).to eq(210)
    expect(one[4]).to eq(0x01)
    expect(described_class.read(one)).to eq([busy_program('ONE   ')])
  end

  it 'reads several messages in one file, skipping other ESQ messages' do
    a = described_class.dump([busy_program('A     ')])
    b = described_class.dump([program.init('B     ')])
    request = [0xF0, 0x0F, 0x02, 0x00, 0x0A, 0xF7]
    expect(described_class.read(request + a + b).map(&:name)).to eq(['A     ', 'B     '])
  end

  it 'keeps every field: nybbles low first, doubled signed levels, packed bits' do
    p = busy_program('BITS  ')
    b = p.to_bytes
    expect(b.length).to eq(102)
    expect(b[0, 6].pack('C*')).to eq('BITS  ')
    expect(b[6]).to eq(126)                 # ENV1 L1 63, doubled
    expect(b[7]).to eq((-40 * 2) & 0xFF)    # ENV1 L2 -40
    expect(b[6 + 10 + 6]).to eq(51 | 0x80)  # ENV2 T4 51 with the second release
    expect(b[58]).to eq(0)                  # OSC1 octave -3, semitone 0
    expect(b[58 + 10]).to eq(36 + 7)        # OSC2 octave 0, semitone 7
    expect(b[58 + 10 + 5]).to eq(27)        # OSC2 wave PRIME
    expect(b[89]).to eq(90 | 0x80)          # FC 90, sync
    expect(b[92]).to eq(63 | 0x80)          # filter MOD1 +63 (7-bit, not doubled), voice restart
    expect(b[93]).to eq(0x41)               # filter MOD2 -63 (7-bit two's complement)
    expect(b[100]).to eq((15 << 4) | 1)     # pan 15, pan mod LFO2

    nyb = described_class.dump([p])[5...-1]
    expect(nyb[0] | (nyb[1] << 4)).to eq('B'.ord)
    expect(nyb[0]).to eq('B'.ord & 0x0F)
    expect(program.decode(b)).to eq(p)
  end

  it 'names waves and tells SQ-80-only programs' do
    p = busy_program('WAVES ')
    expect([0, 1, 2].map { |i| p.wave_name(i) }).to eq(%w[SAW PRIME DRUMS5])
    expect(described_class::WAVES.length).to eq(75)
    expect(p.sq80_only?).to eq(true)
    expect(program.init.sq80_only?).to eq(false)
  end

  it 'refuses malformed dumps' do
    good = described_class.dump([program.init])
    expect { described_class.read(good[0...-1]) }.to raise_error(described_class::FormatError, /F7/)
    expect { described_class.read(good[0, 10] + [0xF7]) }.to raise_error(described_class::FormatError, /expected 204/)
    expect { described_class.read(good[0, 5] + [0x10] + good[6..]) }.to raise_error(described_class::FormatError, /nybbles/)
    expect { described_class.read([0xF0, 0x43, 0x00, 0xF7]) }.to raise_error(described_class::FormatError, /No ESQ-1/)
  end

  if (dir = ENV['MB_SOUND_SQ80_SYX_DIR'])
    Dir[File.join(dir, '*.syx')].sort.each do |f|
      it "reads #{File.basename(f)} and writes it back byte for byte (local banks)" do
        programs = described_class.read(f)
        expect(programs.length % 40).to eq(0) if File.size(f) % 8166 == 0
        expect(described_class.dump(programs).pack('C*').b).to eq(File.binread(f)) if programs.length == 40
      end
    end
  end
end
