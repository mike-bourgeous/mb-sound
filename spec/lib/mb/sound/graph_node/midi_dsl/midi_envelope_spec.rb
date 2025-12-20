RSpec.describe(MB::Sound::GraphNode::MidiDsl::MidiEnvelope) do
  context 'when a MIDI file has ended' do
    it 'does not cause duplicated envelopes to return nil when sampled' do
      clock = MB::Sound::MIDI::MIDIFile::ConstantClock.new
      env = MB::Sound.midi_file('spec/test_data/empty.mid', clock: clock).env

      expect(env.sample(10)).to be_a(Numo::NArray)

      clock.clock_now = 100

      expect(env.sample(10)).to eq(nil)

      expect(env.dup.sample(10)).to be_a(Numo::NArray)
      expect(env.dup.at_rate(10).sample_all).to be_a(Numo::NArray)
    end
  end
end
