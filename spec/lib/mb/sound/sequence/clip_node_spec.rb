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

    it 'converts to seconds per cycle with Clip#period' do
      data = render(two_notes.loop.period(transport: transport), max: 24000)
      expect(data[0]).to be_within(1e-6).of(1.0 / MB::Sound::C3.frequency)
      expect(data[12000]).to be_within(1e-6).of(1.0 / MB::Sound::E3.frequency)
    end

    it 'drives a delay that resonates at each note with Clip#period' do
      notes = MB::Sound.seq(MB::Sound::A2, MB::Sound::E3).n4.loop
      excite = MB::Sound.noise.at(1).forever * notes.env(0, 0.004, 0, 0.001, transport: transport)
      string = excite.delay(notes.period(transport: transport), feedback: 0.98, dry: 1, wet: 1, smoothing: false)
      data = render(string, max: 24000).to_a[4000...20000]

      # The strongest repetition matches A2's period (48000 / 110 = 436.4 samples)
      best = (300..600).max_by { |lag| (0...(data.length - lag)).sum { |i| data[i] * data[i + lag] } }
      expect(best).to eq(436)
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

  describe '#swap_clip' do
    let(:sixteenths) { MB::Sound.grid(16, 'x').loop }

    it 'switches clips on the exact sample, across buffer sizes' do
      [1, 441, 800, 1000].each do |buffer|
        node = two_notes.loop.trigger(transport: transport)
        node.swap_clip(sixteenths, time: 1/4r)
        data = render(node, buffer: buffer, max: 48000)[0...48000]
        expect(nonzero_indices(data)).to eq([0, 12000, 24000, 30000, 36000, 42000]), "failed with buffer size #{buffer}"
      end
    end

    it 'plays a looping clip in phase with the timeline' do
      node = two_notes.loop.trigger(transport: transport)
      node.swap_clip(MB::Sound.grid(4, '.x').loop, time: 1/8r) # a hit on the second beat of every half note
      data = render(node, max: 96000)
      expect(nonzero_indices(data)).to eq([0, 24000, 72000])
    end

    it 'plays a non-looping clip from its start, then ends' do
      node = two_notes.loop.gate(transport: transport)
      node.swap_clip(MB::Sound::C3.n8, time: 24000.5r / 96000)
      data = render(node)
      expect(data.length).to eq(36800)

      # The old loop's next note starts on sample 24000, half a sample before
      # the swap, and the new clip's note plays from sample 24001 to 36000
      expect(nonzero_indices(data)).to eq((0...36001).to_a)
      expect(node.clip).to be_a(MB::Sound::Sequence::Clip).and(satisfy { |c| !c.looping? })
    end

    it 'jumps held values to the new clip at the swap, even mid-note' do
      node = two_notes.loop.number(transport: transport)
      node.swap_clip(MB::Sound.seq(MB::Sound::G3).n4.loop, time: 1/16r)
      data = render(node, max: 12000)
      expect(data[5999]).to eq(MB::Sound::C3.number)
      expect(data[6000]).to eq(MB::Sound::G3.number)
    end

    it 'releases envelopes at the swap' do
      node = MB::Sound::C3.n1.loop.env(0, 0, 1, 0.01, velocity: 1..1, transport: transport)
      node.swap_clip(MB::Sound.seq(nil).n1.loop, time: 1/8r)
      data = render(node, max: 24000)
      expect(data[11999]).to eq(1)
      expect(data[12000 + 1000].abs).to be < 0.01
    end

    it 'swaps at the next buffer without a time, and replaces a pending swap' do
      node = two_notes.loop.trigger(transport: transport)
      node.swap_clip(sixteenths, time: 1)
      expect(node.pending_clip).to equal(sixteenths)

      other = MB::Sound.grid(4, 'x').loop
      node.swap_clip(other)
      data = render(node, max: 48000)
      expect(node.pending_clip).to be_nil
      expect(node.clip).to equal(other)
      expect(nonzero_indices(data)).to eq([0, 24000])
    end

    it 'rejects things that are not clips' do
      expect { two_notes.gate.swap_clip(5) }.to raise_error(ArgumentError, /Clip/)
    end
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
