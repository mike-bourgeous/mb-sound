RSpec.describe(MB::Sound::GraphNode::MidiDsl, aggregate_failures: true) do
  let(:midi) { MB::Sound.midi_file('spec/test_data/all_notes.mid') }
  let(:cc) { midi.cc(1) }
  let(:number) { midi.number }
  let(:note) { midi.tone }
  let(:freq) { midi.frequency }
  let(:bend) { midi.bend }
  let(:velocity) { midi.velocity }
  let(:env) { midi.env }
  let(:gate) { midi.gate }
  let(:click) { midi.click }

  it 'can be created' do
    expect(midi).to be_a(MB::Sound::GraphNode::MidiDsl)
  end

  it 'can create a CC node' do
    expect(cc).to be_a(MB::Sound::GraphNode::MidiDsl::MidiCc)
    expect(cc.sample(1)).to eq(Numo::SFloat[0])
  end

  it 'can create a note number node' do
    expect(number).to be_a(MB::Sound::GraphNode::MidiDsl::MidiNumber)
    expect(number.sample(1)).to eq(Numo::SFloat[69])
  end

  it 'can create a note frequency node' do
    expect(freq).to be_a(MB::Sound::GraphNode::MidiDsl::MidiFrequency)
    expect(freq.sample(1)).to eq(Numo::SFloat[440])
  end

  it 'can create a MIDI-controlled tone' do
    expect(note).to be_a(MB::Sound::GraphNode::MidiDsl::MidiTone)
    expect(note.sample(1)).to be_a(Numo::SFloat)
  end

  it 'can create a pitch bend node' do
    expect(bend).to be_a(MB::Sound::GraphNode::MidiDsl::MidiBend)
    expect(bend.sample(1)).to eq(Numo::SFloat[0])
  end

  it 'can create a velocity node' do
    expect(velocity).to be_a(MB::Sound::GraphNode::MidiDsl::MidiVelocity)
    expect(velocity.sample(1)).to eq(Numo::SFloat[0])
  end

  it 'can create a MIDI-controlled envelope' do
    expect(env).to be_a(MB::Sound::GraphNode::MidiDsl::MidiEnvelope)
    expect(env.sample(1)).to eq(Numo::SFloat[0])
  end

  it 'can create a gate node' do
    expect(gate).to be_a(MB::Sound::GraphNode::MidiDsl::MidiGate)
    expect(gate.sample(1)).to eq(Numo::SFloat[0])
  end

  it 'can create a click node' do
    expect(click).to be_a(MB::Sound::GraphNode::MidiDsl::MidiClick)
    expect(click.sample(1)).to eq(Numo::SFloat[0])
    click.note_cb(127, 127, true)
    expect(click.sample(1)).to eq(Numo::SFloat[1])
  end

  it 'can operate on a MIDI file' do
    graph = MB::Sound.midi_file('spec/test_data/mod_wheel.mid') { |midi|
      midi.tone.ramp.filter(:lowpass, cutoff: midi.frequency * midi.velocity(range: 2..10), quality: 4) * midi.env
    }
    expect(graph.sample(1)).to be_a(Numo::SFloat)
  end

  pending 'can filter events by channel'

  pending 'cache invalidation'

  pending 'source names'

  pending 'more tests'
end
