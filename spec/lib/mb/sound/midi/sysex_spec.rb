# SysEx messages, files, and readers (MIDI::SysEx), with synthetic dumps
# only: never real patch dumps.
RSpec.describe(MB::Sound::MIDI::SysEx, :aggregate_failures) do
  let(:sq80) { MB::Sound::SQ80 }
  let(:program) { sq80::Program.init('REESE ') }
  let(:single) { sq80::SysEx.dump([program], channel: 2).pack('C*') }
  let(:bank) { sq80::SysEx.dump(Array.new(40) { |i| sq80::Program.init(format('P%02d', i)) }).pack('C*') }
  let(:korg) { [0xF0, 0x42, 0x30, 0x68, 0x01, 0x02, 0xF7].pack('C*') }

  describe described_class::Assembler do
    let(:asm) { described_class.new }

    it 'passes whole messages through and ignores other MIDI messages' do
      expect(asm.push(single)).to eq([[single, true]])
      expect(asm.push([0x90, 60, 100].pack('C*'))).to eq([])
      expect(asm.receiving?).to eq(false)
    end

    it 'joins a dump split into pieces, skipping real-time bytes inside it' do
      pieces = bank.bytes.each_slice(300).map { |s| s.pack('C*') }
      got = []
      pieces.each_with_index do |p, i|
        got.concat(asm.push(p))
        got.concat(asm.push("\xF8".b)) if i == 2
        expect(asm.pending_bytes).to eq(300 * (i + 1)) if i < pieces.length - 1
      end
      expect(got).to eq([[bank, true]])
      expect(asm.receiving?).to eq(false)
    end

    it 'ends a dump cut short by another status byte, a new F0, or the size limit as incomplete' do
      expect(asm.push([0xF0, 0x0F, 1, 2].pack('C*'))).to eq([])
      expect(asm.push([0x90, 60, 100].pack('C*'))).to eq([[[0xF0, 0x0F, 1, 2].pack('C*'), false]])

      asm.push([0xF0, 1, 2].pack('C*'))
      expect(asm.push(korg)).to eq([[[0xF0, 1, 2].pack('C*'), false], [korg, true]])

      small = described_class.new(max_bytes: 4)
      expect(small.push([0xF0, 1, 2, 3, 4, 5, 0xF7].pack('C*'))).to eq([[[0xF0, 1, 2, 3].pack('C*'), false]])
      expect(small.receiving?).to eq(false)
    end

    it 'flushes a dump in progress as incomplete' do
      asm.push([0xF0, 0x7D, 1].pack('C*'))
      expect(asm.flush).to eq([[[0xF0, 0x7D, 1].pack('C*'), false]])
      expect(asm.flush).to eq([])
    end
  end

  describe '.describe' do
    it 'describes SQ-80 programs, banks, and requests with 1-based channels' do
      expect(described_class.describe(single)).to eq('Ensoniq ESQ-1/SQ-80 program "REESE" (channel 3)')
      expect(described_class.describe(bank)).to eq('Ensoniq ESQ-1/SQ-80 bank of 40 programs: "P00", "P01", "P02", "P03", ... (channel 1)')
      expect(described_class.describe(sq80::SysEx.request(:program, channel: 16))).to eq('Ensoniq ESQ-1/SQ-80 current program dump request (channel 16)')
      expect(described_class.describe(sq80::SysEx.request(:all))).to eq('Ensoniq ESQ-1/SQ-80 all programs dump request (channel 1)')
    end

    it 'says what is wrong with a malformed SQ-80 dump' do
      broken = single.bytes
      broken.delete_at(10)
      expect(described_class.describe(broken)).to match(/program dump \(channel 3; unreadable: .*203 data bytes/)
    end

    it 'names other manufacturers (one- and three-byte IDs), else gives the ID in hex' do
      expect(described_class.describe(korg)).to eq('Korg')
      expect(described_class.describe([0xF0, 0x00, 0x20, 0x29, 1, 0xF7])).to eq('Novation')
      expect(described_class.describe([0xF0, 0x00, 0x7F, 0x01, 1, 0xF7])).to eq('manufacturer 00 7F 01')
      expect(described_class.describe([0xF0, 0x55, 1, 0xF7])).to eq('manufacturer 55')
    end

    it 'falls back to the manufacturer when a registered reader raises' do
      described_class.register(0x55, 'broken', describe: ->(_) { raise 'oops' }, decode: ->(_) { raise 'oops' }, slug: ->(_) { raise 'oops' })
      expect(described_class.describe([0xF0, 0x55, 1, 0xF7])).to eq('manufacturer 55')
      expect(described_class.decode([0xF0, 0x55, 1, 0xF7])).to eq([])
      expect(described_class.slug([0xF0, 0x55, 1, 0xF7])).to eq('manufacturer-55')
    ensure
      described_class.instance_variable_get(:@readers).delete([0x55])
    end
  end

  it 'makes file-name parts' do
    expect(described_class.slug(single)).to eq('sq80-program-reese')
    expect(described_class.slug(bank)).to eq('sq80-bank')
    expect(described_class.slug(korg)).to eq('korg')
    expect(described_class.clean_slug('  ')).to eq('sysex')
  end

  describe '.messages and Message' do
    it 'splits data into messages, skipping bytes outside them, and keeps incomplete ones' do
      data = "\x00\x01".b + single + [0x90, 60, 1].pack('C*') + korg + [0xF0, 0x7D, 5].pack('C*')
      list = described_class.messages(data, port: 'here')
      expect(list.map(&:bytes)).to eq([single, korg, [0xF0, 0x7D, 5].pack('C*')])
      expect(list.map(&:complete?)).to eq([true, true, false])
      expect(list.map(&:port).uniq).to eq(['here'])
      expect(list.first.to_s).to eq('Ensoniq ESQ-1/SQ-80 program "REESE" (channel 3), 210 bytes from here')
      expect(list.last.to_s).to include('INCOMPLETE')
      expect(list.first.bytes).to be_frozen
      expect(list.first.decode).to eq([program])
      expect(list.first.to_event.type).to eq(:sysex)
    end

    it 'takes Arrays of bytes, Messages, and Dumps' do
      m = described_class.messages(korg.bytes)
      expect(m.map(&:bytes)).to eq([korg])
      expect(described_class.messages(m.first)).to eq(m)
      expect(described_class.messages(m)).to eq(m)
      expect { described_class.messages(42) }.to raise_error(ArgumentError, /file name/)
    end
  end

  describe '.save and .load' do
    it 'writes raw bytes and never replaces a file' do
      path = tmp_path('patch.syx')
      expect(described_class.save(path, single)).to eq(path)
      expect(described_class.save(path, korg)).to eq(path.sub('.syx', '-2.syx'))
      expect(described_class.save(path, bank)).to eq(path.sub('.syx', '-3.syx'))
      expect(File.binread(path)).to eq(single)
      expect(File.binread(path.sub('.syx', '-2.syx'))).to eq(korg)
    end

    it 'creates the folder' do
      path = File.join(File.dirname(tmp_path('x')), 'deeper', 'dump.syx')
      expect(described_class.save(path, korg)).to eq(path)
    end

    it 'loads a file as a Dump that decodes programs and prints one line per message' do
      path = tmp_path('two.syx')
      File.binwrite(path, single + korg)
      dump = described_class.load(path)
      expect(dump.size).to eq(2)
      expect(dump.programs).to eq([program])
      expect(dump.bytes).to eq(single + korg)
      expect(dump.to_s).to eq("#{path}: 2 SysEx messages, #{single.bytesize + korg.bytesize} bytes\n" \
                              "  1. Ensoniq ESQ-1/SQ-80 program \"REESE\" (channel 3), 210 bytes\n  2. Korg, 7 bytes")
      expect(dump.first.port).to eq(path)
      expect(dump.save(path)).to eq(path.sub('.syx', '-2.syx'))
    end

    it 'raises for a file without SysEx' do
      path = tmp_path('empty.syx')
      File.binwrite(path, [0x90, 60, 100].pack('C*'))
      expect { described_class.load(path) }.to raise_error(described_class::FormatError, /no SysEx/)
    end
  end

  describe 'SQ80::SysEx.request' do
    it 'makes dump requests on 1-based channels and refuses channel 0' do
      expect(sq80::SysEx.request).to eq([0xF0, 0x0F, 0x02, 0x00, 0x09, 0xF7])
      expect(sq80::SysEx.request(:all, channel: 3)).to eq([0xF0, 0x0F, 0x02, 0x02, 0x0A, 0xF7])
      expect { sq80::SysEx.request(:program, channel: 0) }.to raise_error(ArgumentError, /channels count from 1/)
      expect { sq80::SysEx.request(:bank) }.to raise_error(ArgumentError, /:program and :all/)
    end
  end

  it 'prints SQ-80 programs as panel values' do
    text = program.pretty_inspect
    expect(text).to start_with('SQ-80 program "REESE"')
    expect(text).to include('OSC1 SAW', 'FILTER fc 127', 'ENV4 L1 63', 'LFO3 tri')
  end
end
