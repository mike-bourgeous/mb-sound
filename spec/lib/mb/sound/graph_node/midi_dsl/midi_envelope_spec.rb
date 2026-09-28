RSpec.describe(MB::Sound::GraphNode::MidiDsl::MidiEnvelope) do
  let (:clock) { MB::Sound::MIDI::MIDIFile::ConstantClock.new }
  let (:midi_in) { MB::Sound.midi_file('spec/test_data/empty.mid', clock: clock) }
  let (:env) { midi_in.env }

  context 'when a MIDI file has ended' do
    describe '#dup' do
      it 'does not cause duplicated envelopes to return nil when sampled for display' do
        expect(env.sample(10)).to be_a(Numo::NArray)

        clock.clock_now = 100

        expect(env.sample(10)).to eq(nil)

        expect(env.dup(10).sample_all).to be_a(Numo::NArray)
        expect(env.dup.at_rate(10).sample_all).to be_a(Numo::NArray)
      end
    end
  end

  describe '#note_cb' do
    it 'delays envelope start if given a positive timestamp' do
      env.note_cb(0, 127, true, 0.01)
      d = env.sample(4800)
      expect(d[0...480].minmax).to eq([0, 0])
      expect(d[480...].mean).to be > 0.3
    end
  end
end
