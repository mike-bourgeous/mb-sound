RSpec.describe(MB::Sound::Sequence::ClipNode) do
  # 120 BPM: an eighth note is 0.25 seconds, or 12000 samples at 48kHz
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:two_notes) { (MB::Sound::C3.n8 | MB::Sound::E3.n8) }

  # Samples +node+ in +buffer+-sized chunks until it ends or +max+ samples.
  def render(node, buffer: 800, max: 48000 * 10)
    bufs = []
    total = 0
    while total < max && (b = node.sample(buffer))
      bufs << b.dup
      total += b.length
    end
    bufs.empty? ? Numo::SFloat[] : bufs.reduce { |a, b| a.concatenate(b) }
  end

  def nonzero_indices(data)
    data.to_a.each_with_index.reject { |v, _| v == 0 }.map(&:last)
  end

  describe MB::Sound::Sequence::ClipNode::Trigger do
    it 'outputs an impulse on the exact sample of each note, across buffer sizes' do
      [1, 441, 800, 1000].each do |buffer|
        data = render(two_notes.loop.trigger(transport: transport), buffer: buffer, max: 48000)[0...48000]
        expect(nonzero_indices(data)).to eq([0, 12000, 24000, 36000]), "failed with buffer size #{buffer}"
      end
    end

    it 'scales velocity to the range' do
      data = render(MB::Sound.grid(8, 'xX').trigger(range: 0..2, transport: transport))
      expect(data[0]).to eq(1.5)
      expect(data[12000]).to eq(2)
    end

    it 'ends with a non-looping clip' do
      expect(render(two_notes.trigger(transport: transport)).length).to eq(24000)
    end
  end

  describe MB::Sound::Sequence::ClipNode::Gate do
    it 'is on during notes and off during rests' do
      data = render(MB::Sound.seq(MB::Sound::C3, nil, MB::Sound::E3).n8.gate(transport: transport))
      expect(data.length).to eq(36000)
      expect(data[0...12000].to_a.uniq).to eq([1])
      expect(data[12000...24000].to_a.uniq).to eq([0])
      expect(data[24000...36000].to_a.uniq).to eq([1])
    end

    it 'stays on between legato notes' do
      data = render(two_notes.gate(transport: transport))
      expect(data.to_a.uniq).to eq([1])
    end
  end

  describe MB::Sound::Sequence::ClipNode::Number do
    it 'outputs the current note, starting with the first note' do
      data = render(two_notes.number(transport: transport), max: 30000)
      expect(data[0]).to eq(48)
      expect(data[11999]).to eq(48)
      expect(data[12000]).to eq(52)
    end

    it 'keeps holding the last value after a non-looping clip ends' do
      data = render(two_notes.number(transport: transport), max: 48000)
      expect(data.length).to eq(48000)
      expect(data[-1]).to eq(52)
    end

    it 'converts to frequency with #hz' do
      data = render(two_notes.hz(transport: transport), max: 800)
      expect(data[0]).to be_within(0.01).of(MB::Sound::C3.frequency)
    end
  end

  describe MB::Sound::Sequence::ClipNode::Velocity do
    it 'holds the velocity of the latest note' do
      data = render(MB::Sound.grid(8, '9x').velocity(transport: transport), max: 24000)
      expect(data[0]).to eq(1)
      expect(data[12000]).to eq(0.75)
    end
  end

  describe MB::Sound::Sequence::ClipNode::Envelope do
    it 'triggers at each note, releases at the end, and ends after the release' do
      node = MB::Sound.seq(MB::Sound::C3, nil).n8.env(0.001, 0.01, 0.5, 0.1, velocity: 1..1, transport: transport)
      data = render(node)

      # 0.25s rest + 0.11s tail after the note
      expect(data.length).to be_within(800).of(12000 + 12000 + 0.11 * 48000)
      expect(data[0...10].max).to be < 0.5
      expect(data[2000...11000].to_a.map { |v| v.round(2) }.uniq).to eq([0.5])
      expect(data[12000 + 9600]).to be < 0.01
    end

    it 'retriggers on repeated notes' do
      node = (MB::Sound::C3.n8 * 2).loop.env(0.001, 0.05, 0, 0.01, velocity: 1..1, transport: transport)
      data = render(node, max: 24000)
      expect(data[11000]).to be < 0.01
      expect(data[12000 + 48]).to be > 0.9
    end

    it 'scales the peak by velocity' do
      node = MB::Sound.grid(8, '1').loop.env(0.001, 0.05, 1, 0.01, velocity: 0..1, transport: transport)
      expect(render(node, max: 4800).max).to be_within(0.02).of(1 / 9.0)
    end
  end

  it 'follows tempo changes while playing' do
    node = two_notes.loop.trigger(transport: transport)
    first = render(node, max: 12000)
    transport.bpm = 240
    second = render(node, max: 12000)
    expect(nonzero_indices(first)).to eq([0])
    expect(nonzero_indices(second)).to eq([0, 6000])
  end

  it 'uses the default transport' do
    node = two_notes.trigger
    expect(node.transport).to equal(MB::Sound.transport)
  end

  it 'can restart' do
    node = two_notes.trigger(transport: transport)
    render(node)
    expect(node.sample(800)).to be_nil
    node.restart
    expect(node.sample(800)[0]).to eq(0.75)
  end

  it 'works in a synth graph' do
    bass = (MB::Sound::C2.n8 | MB::Sound::G1.n8).loop
    graph = bass.tone.ramp.at(1).filter(:lowpass, cutoff: 1000, quality: 2) * bass.env(0.005, 0.1, 0.5, 0.05, transport: transport)
    data = render(graph, max: 48000)
    expect(data.length).to eq(48000)
    expect(data.abs.max).to be_between(0.1, 2)
  end
end

RSpec.describe(MB::Sound::SequenceMethods) do
  describe '#bpm' do
    after { MB::Sound.bpm(120) }

    it 'sets and returns the default tempo' do
      expect(MB::Sound.bpm).to eq(120)
      expect(MB::Sound.bpm(90)).to eq(90)
      expect(MB::Sound.transport.bpm).to eq(90)
    end

    it 'rejects invalid tempos' do
      expect { MB::Sound.bpm(0) }.to raise_error(ArgumentError)
    end
  end
end
