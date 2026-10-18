RSpec.describe('MIDI transforms with moving parameters (MIDI::Param)', :midi_transforms) do
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }

  # Sixteen notes, an eighth second (a 16th at 120 BPM) apart, a 32nd long.
  def run_stream(*extra)
    list_stream(*(16.times.flat_map { |i| [ev.note_on(60 + i % 12, 0.5, time: i / 8r), ev.note_off(60 + i % 12, time: i / 8r + 1/16r)] } + extra).sort_by(&:time))
  end

  describe MB::Sound::MIDI::Param do
    it 'lets plain values answer themselves' do
      expect(described_class.value_at(0.5, 3r)).to eq(0.5)
      expect(described_class.value_at(1.n16, 3r)).to eq(1.n16)
      expect(described_class.wrap(0.5)).to eq(0.5)
      expect(described_class.wrap(0.25.constant)).to eq(0.25)
    end

    it 'reads tempo LFOs from the position' do
      p = described_class.wrap(2.bars.lfo.triangle.at(0.5..0.7))
      expect((0..8).map { |i| p.value_at(i / 4r).round(9) }).to eq([0.6, 0.65, 0.7, 0.65, 0.6, 0.55, 0.5, 0.55, 0.6])
      sine = described_class.wrap(0.6 + 0.3 * 2.bars.lfo)
      expect(sine.value_at(1/2r)).to be_within(1e-12).of(0.9)
    end

    it 'reads clips at the position' do
      p = described_class.wrap(MB::Sound.seq(0, -4, 3, -2).n1.loop)
      expect((0..5).map { |b| p.value_at(b.to_r) }).to eq([0, -4, 3, -2, 0, -4])
    end

    it 'refuses audio-rate nodes with a hint' do
      expect { described_class.wrap(123.hz.saw) }.to raise_error(described_class::NotAParam, /tempo LFO/)
      expect { described_class.wrap(123.hz.saw.softclip) }.to raise_error(described_class::NotAParam, /follow/)
    end

    it 'combines with numbers and prints back as Ruby' do
      c = MB::Sound.cc(1, 0.3..0.95)
      expect(c.value_at(0r)).to eq(0.3)
      e = 0.5 + c * 2
      expect(e.to_s).to eq('0.5 + cc(1, 0.3..0.95) * 2')
      expect(e.value_at(0r)).to be_within(1e-12).of(1.1)
      expect(MB::Sound.cc(7, 1..10, curve: :exponential, default: 64, channel: 2).to_s).to eq('cc(7, 1..10, curve: :exponential, default: 64, channel: 2)')
      expect { c + 'x' }.to raise_error(described_class::NotAParam)
    end
  end

  describe 'cc params' do
    it 'read the transform input, exactly at each note' do
      s = run_stream(ev.cc(1, 0.0, time: 0r), ev.cc(1, 1.0, time: 1/2r - 1/1000r))
      out = ons(read_all(s.chance(MB::Sound.cc(1), seed: 1)))
      expect(out.map { |e| e[2] }).to eq((4...16).map { |i| i / 8r })
    end

    it 'fall back to the default without a controller' do
      expect(ons(read_all(run_stream.chance(MB::Sound.cc(1, default: 127), seed: 1))).length).to eq(16)
      expect(ons(read_all(run_stream.chance(MB::Sound.cc(1), seed: 1))).length).to eq(0)
    end

    it 'are listed for controller maps' do
      notes = run_stream.swing(MB::Sound.cc(21, 0.5..0.7)).notes
      expect(MB::Sound::MIDI::ControlMap.new(notes).numbers).to include(21)
    end
  end

  describe 'feel transforms' do
    it 'swing by a moving amount, keeping lengths in step' do
      out = read_all(run_stream.swing(4.bars.lfo.triangle.at(0.5..0.7), transport: transport))
      expect_balanced(out)
      delays = ons(out).each_with_index.map { |e, i| e[2] - i / 8r }
      expect(delays.values_at(0, 2, 4)).to eq([0, 0, 0])
      expect(delays[1]).to be > 0
      expect(delays[15]).to be > delays[1] # (the LFO rises over the bar)
    end

    it 'humanize by a moving time and velocity' do
      out = read_all(run_stream.humanize(MB::Sound.cc(1, 0..0.03, default: 127), velocity: MB::Sound.knob(:hv, 0.2), seed: 3))
      expect_balanced(out)
      expect(ons(out).map { |e| e[3] }.uniq.length).to be > 4
      expect(ons(out).each_with_index.map { |e, i| e[2] - i / 8r }.max).to be_between(0.001, 0.03)
    end

    it 'quantize by a moving amount' do
      s = list_stream(ev.note_on(60, time: 1/100r), ev.note_off(60, time: 1/10r), ev.note_on(62, time: 1r + 1/100r), ev.note_off(62, time: 1r + 1/10r))
      out = ons(read_all(s.quantize(16, amount: MB::Sound.seq(1, 0).n2.loop, transport: transport)))
      expect(out.map { |e| e[2] }).to eq([1/8r, 1r + 1/100r])
    end

    it 'every reads n at each bar start' do
      notes = 32.times.flat_map { |i| [ev.note_on(60, time: i / 2r), ev.note_off(60, time: i / 2r + 1/8r)] }
      out = ons(read_all(list_stream(*notes).every(MB::Sound.seq(1, 2).n1.loop, transport: transport), seconds: 20))
      # Odd bars read n = 1 (play), even bars n = 2 (bars 2, 4, ... don't
      # play every 2 from 1)
      expect(out.map { |e| (e[2] / 2).floor + 1 }.uniq).to eq([1, 3, 5, 7])
    end
  end

  describe 'transpose by a param' do
    it 'moves each note by the step at its note-on, note-offs following' do
      s = list_stream(ev.note_on(60, time: 0r), ev.note_on(64, time: 1r), ev.note_off(60, time: 5/2r), ev.note_off(64, time: 5/2r))
      out = read_all(s.transpose(MB::Sound.seq(0, 5, 7).n2.loop, transport: transport))
      expect_balanced(out)
      expect(out.map { |e| e.first(2) }).to eq([[:note_on, 60], [:note_on, 69], [:note_off, 60], [:note_off, 69]])
    end

    it 'moves by scale degrees' do
      s = list_stream(ev.note_on(57, time: 0r), ev.note_off(57, time: 1/4r))
      out = read_all(s.transpose(MB::Sound.knob(:deg, 2, range: -7..7), scale: :minor, root: :a))
      expect(ons(out).map { |e| e[1] }).to eq([60])
    end
  end

  describe 'per step' do
    it 'arp reads its rate at each step' do
      s = list_stream(ev.note_on(60, time: 0r), ev.note_on(64, time: 0r), ev.note_off(60, time: 2r), ev.note_off(64, time: 2r))
      out = ons(read_all(s.arp(:up, MB::Sound.seq(8, 16).n2.loop, transport: transport), seconds: 2))
      times = out.map { |e| e[2] }
      expect(times.take(4)).to eq([0r, 1/4r, 1/2r, 3/4r])     # 8ths in the first half bar
      expect(times[4..7]).to eq([1r, 9/8r, 5/4r, 11/8r])       # 16ths in the second
    end

    it 'ratchet spaces hits by its rate at each hit' do
      s = list_stream(ev.note_on(60, time: 0r), ev.note_off(60, time: 1r))
      out = read_all(s.ratchet(MB::Sound.cc(1, 1..4, default: 127), rate: MB::Sound.seq(16, 32).n8.loop, transport: transport))
      expect_balanced(out)
      expect(ons(out).map { |e| e[2] }).to eq([0r, 1/8r, 1/4r, 5/16r]) # (16ths for the first 8th note, then 32nds)
    end
  end

  describe 'Notes and recipes' do
    it 'print transforms with params as Ruby' do
      k = MB::Sound.knob(:sw, 0.5, range: 0.5..0.75)
      st = run_stream.swing(k * 0.5 + 0.25)
      expect(st.to_s).to include('swing(knob(:sw) * 0.5 + 0.25)')
      expect(run_stream.chance(MB::Sound.cc(2)).to_s).to include('chance(cc(2))')
    end
  end
  describe 'clip operations with params' do
    let(:riff) { MB::Sound.seq(60, 64, 67, 72).n8.loop }

    it 'transpose by the step at each event, per cycle' do
      c = riff.transpose(MB::Sound.seq(0, 5).n2.loop)
      expect(c.events_for(0).map(&:value)).to eq([60, 64, 67, 72])
      expect(c.events_for(1).map(&:value)).to eq([65, 69, 72, 77])
      expect(c.to_ruby).to eq('seq(60, 64, 67, 72).n8.loop.transpose(seq(0, 5).n2.loop)')
    end

    it 'swing, chance, quantize, and humanize by params' do
      k = MB::Sound.knob(:cp, 0.25)
      expect(riff.chance(k).events_for(3).map(&:probability)).to eq([0.25] * 4)
      sw = MB::Sound.seq(60, 62, 64, 65).n16.loop.swing(MB::Sound.seq(0.5, 2/3r).n8.loop)
      expect(sw.events_for(0).map(&:start)).to eq([0r, 1/16r, 1/8r, 1/8r + 1/12r])
      q = MB::Sound::Sequence::Clip.new([MB::Sound::Sequence::Event.new(start: 1/100r, length: 1/16r, value: 60)], length: 1, loop: true)
      expect(q.quantize(16, amount: MB::Sound.seq(1, 0).n1.loop).events_for(0).map(&:start)).to eq([0r])
      expect(q.quantize(16, amount: MB::Sound.seq(1, 0).n1.loop).events_for(1).map(&:start)).to eq([1/100r])
      h = riff.humanize(0.01 + 0 * 2.bars.lfo, seed: 3)
      expect(h.events_for(2)).to eq(h.events_for(2))
      expect(h.events_for(2).map(&:start)).not_to eq(riff.events.map(&:start))
    end

    it 'every reads n at each cycle start' do
      c = riff.every(MB::Sound.seq(1, 2).n2.loop)
      expect(c.events_for(0).map(&:condition).uniq).to eq([[1, 1]])
      expect(c.events_for(1).map(&:condition).uniq).to eq([[2, 1]])
    end

    it 'leaves plain values to the original operations' do
      expect(riff.chance(0.5).events).to eq(riff.chance(0.5).events)
      expect(riff.transpose(2).class).to eq(MB::Sound::Sequence::Seq)
    end
  end
end
