RSpec.describe(MB::Sound::ModMethods) do
  let(:ev) { MB::Sound::MIDI::Event }

  def notes_for(*events)
    MB::Sound::Notes.new(MIDIListSource.new(events, [ev.cc(99, 0, time: 1000r)]))
  end

  describe '#mod_sum' do
    it 'adds sources times amounts to a base' do
      out = MB::Sound.mod_sum(1, 2.constant => 0.5, 3.constant => 2).sample(10)
      expect(out.to_a.uniq).to eq([8.0])
    end

    it 'counts Interval amounts in semitones and takes node amounts' do
      out = MB::Sound.mod_sum(0.5.constant => 1.oct, 1.constant => 0.25.constant).sample(4)
      expect(out[0]).to eq(6.25)
    end

    it 'rejects Symbols outside a voice and bad amounts' do
      expect { MB::Sound.mod_sum(:velocity => 1) }.to raise_error(ArgumentError, /Notes/)
      expect { MB::Sound.mod_sum(1.constant => 'x') }.to raise_error(ArgumentError, /amounts/)
    end
  end

  describe '#mod_scale' do
    it 'scales a base by octaves' do
      out = MB::Sound.mod_scale(100, 1.constant => 1.oct, 0.5.constant => 12.st).sample(4)
      expect(out[0]).to be_within(1e-3).of(100 * 2**1.5)
    end
  end

  describe 'voice sources' do
    it 'resolves Symbols to the voice controls' do
      v = notes_for(ev.note_on(72, 0.5), ev.cc(1, 127), ev.cc(4, 127), ev.channel_pressure(0.25))
      {
        velocity: 0.5, vel_x: 0.25, key: 1.0, wheel: 1.0, pedal: 1.0, pressure: 0.25, aftertouch: 0.25, poly_pressure: 0.0, gate: 1.0,
      }.then { |expected|
        # Make every node before sampling (as a graph is built before it plays)
        nodes = expected.keys.to_h { |src| [src, v.mod_sum(src => 1)] }
        expected.each do |src, value|
          expect(nodes[src].sample(480)[-1]).to be_within(1e-6).of(value), src.to_s
        end
      }
      expect { v.mod_sum(:nope => 1) }.to raise_error(ArgumentError, /nope/)
    end

    it 'key-tracks a cutoff with :key in octaves' do
      v = notes_for(ev.note_on(48, 1.0))
      expect(v.mod_scale(800, :key => 0.5).sample(480)[-1]).to be_within(1e-3).of(800 / Math.sqrt(2))
    end
  end
end
