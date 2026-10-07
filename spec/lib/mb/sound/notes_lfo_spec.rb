RSpec.describe(MB::Sound::Notes, '#lfo') do
  let(:ev) { MB::Sound::MIDI::Event }

  # A Notes on +events+, with a late CC so the source doesn't end.
  def notes_for(*events)
    MB::Sound::Notes.new(MIDIListSource.new(events, [ev.cc(99, 0, time: 1000r)]))
  end

  def run(node, seconds, buffer: 480)
    (seconds * 48000 / buffer).ceil.times.map { node.sample(buffer).dup }.reduce(:concatenate)
  end

  let(:held) { notes_for(ev.note_on(60, 1.0)) }

  it 'makes triangle, saw, square, and sine LFOs over -1..1' do
    { triangle: [-1, 1], saw: [-1, 1], square: [-1, 1], sine: [-1, 1] }.each do |shape, (lo, hi)|
      out = run(held.lfo(4, shape: shape), 1)
      expect(out.min).to be_within(0.01).of(lo), shape.to_s
      expect(out.max).to be_within(0.01).of(hi), shape.to_s
    end
    sq = run(held.lfo(4, shape: :sqr), 1)
    expect(sq.to_a.uniq.sort).to eq([-1.0, 1.0])
  end

  it 'makes a rising saw' do
    out = run(held.lfo(2, shape: :saw), 0.25)
    expect(out[100]).to be < out[5000]
  end

  it 'holds a random value for each cycle with :noise' do
    out = run(held.lfo(10, shape: :noise, seed: 3), 1)
    steps = out.to_a.chunk_while { |a, b| a == b }.map(&:length)
    expect(steps.length).to be_between(10, 11)
    expect(steps[1..-2].uniq).to eq([4800])
    expect(out.min).to be >= -1
    expect(out.max).to be <= 1
    again = run(held.lfo(10, shape: :noise, seed: 3), 1)
    expect(again.to_a).to eq(out.to_a)
  end

  it 'makes unipolar LFOs' do
    expect(run(held.lfo(4, shape: :square, unipolar: true), 1).to_a.uniq.sort).to eq([0.0, 1.0])
    noise = run(held.lfo(10, shape: :noise, unipolar: true), 1)
    expect(noise.min).to be >= 0
  end

  it 'restarts at each note-on with sync: :key, and runs free with :free' do
    events = [ev.note_on(60, 1.0), ev.note_on(64, 1.0).at(Rational(4321, 48000))]
    key = run(notes_for(*events).lfo(3.1, shape: :saw), 0.3)
    free = run(notes_for(*events).lfo(3.1, shape: :saw, sync: :free), 0.3)
    expect(key[4321...(4321 + 4000)].to_a).to eq(key[0...4000].to_a)
    expect(free[4321...(4321 + 4000)].to_a).not_to eq(free[0...4000].to_a)
  end

  it 'starts at random phases with sync: :random' do
    events = [ev.note_on(60, 1.0), ev.note_on(64, 1.0).at(Rational(4800, 48000))]
    out = run(notes_for(*events).lfo(1, shape: :saw, sync: :random, seed: 5), 0.2)
    expect(out[4800]).not_to be_within(0.01).of(out[0])
  end

  it 'fades the depth in over the delay after each note-on, from :from' do
    out = run(held.lfo(10, shape: :square, delay: 0.5), 1)
    expect(out[0...2400].abs.max).to be < 0.11
    expect(out[24000..].abs.min).to eq(1)
    half = run(notes_for(ev.note_on(60, 1.0)).lfo(10, shape: :square, delay: 0.5, from: 0.5), 1)
    expect(half[0...240].abs.max).to be_within(0.01).of(0.5)
  end

  it 'adds mod wheel and aftertouch depth' do
    v = notes_for(ev.note_on(60, 1.0), ev.cc(1, 127), ev.channel_pressure(0.5).at(Rational(1, 10)))
    out = run(v.lfo(5, shape: :square, depth: 0.1, wheel: 0.4, pressure: 1.st), 0.2)
    expect(out[0...2400].abs.max).to be_within(1e-6).of(0.5)
    expect(out[6000..].abs.max).to be_within(1e-6).of(1.0)
  end

  it 'follows the tempo with a Duration rate' do
    MB::Sound.bpm(120)
    out = run(held.lfo(1.n4, shape: :square), 1)
    flips = (1...out.length).count { |i| out[i] != out[i - 1] }
    expect(flips).to be_between(3, 4) # 2 Hz
  ensure
    MB::Sound.rewind
  end

  it 'varies the rate with :human' do
    a = run(held.lfo(10, shape: :square), 1)
    b = run(notes_for(ev.note_on(60, 1.0)).lfo(10, shape: :square, human: 0.5, seed: 9), 1)
    expect(b.to_a).not_to eq(a.to_a)
  end

  it 'gives vibrato the same samples as before (a delayed sine LFO)' do
    a = notes_for(ev.note_on(60, 1.0)).vibrato(6, depth: 0.5, delay: 0.2)
    lfo = MB::Sound::Tone.new(frequency: 6).lfo.reset((v = notes_for(ev.note_on(60, 1.0))).trigger)
    b = MB::Sound::GraphNode::Multiplier.new([lfo, 0.5, MB::Sound::Notes::FadeIn.new(v.note_stream, delay: 0.2, notes: v)])
    expect(run(a, 0.5).to_a).to eq(run(b, 0.5).to_a)
    expect(a.graph_node_name).to eq('vibrato')
  end

  it 'rejects unknown shapes and sync modes' do
    expect { held.lfo(1, shape: :wobble) }.to raise_error(ArgumentError, /shape/)
    expect { held.lfo(1, sync: :maybe) }.to raise_error(ArgumentError, /sync/)
  end
end

RSpec.describe(MB::Sound::GraphNode::SampleHold) do
  it 'holds the source at rising edges of the trigger' do
    src = MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(100).seq])
    trig = MB::Sound::ArrayInput.new(data: [Numo::SFloat.cast([0] * 10 + [1] * 5 + [-1] * 25 + [1] * 60)])
    out = described_class.new(src, trig).sample(100)
    expect(out[0...10].to_a.uniq).to eq([0])
    expect(out[10...40].to_a.uniq).to eq([10])
    expect(out[40..].to_a.uniq).to eq([40])
  end

  it 'holds random values with #sample_hold and no source' do
    out = 10.hz.lfo.square.sample_hold(range: 2.0..3.0, seed: 1).sample(48000)
    expect(out.to_a.uniq.length).to eq(10)
    expect(out.min).to be >= 2
    expect(out.max).to be <= 3
  end

  it 'decimates with #sah' do
    out = 997.hz.ramp.sah(2000.hz.lfo.asquare).sample(4800)
    expect(out.to_a.chunk_while { |a, b| a == b }.map(&:length).uniq.sort).to eq([24])
  end
end
