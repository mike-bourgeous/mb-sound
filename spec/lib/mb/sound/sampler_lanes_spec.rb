# Sampler voices following a clip's lanes (Sampler::Instrument#play
# lanes:, tracker-1): bend, CC 7 volume, CC 10 pan, CC 20 start, stepping
# on their exact samples.
RSpec.describe('sampler lanes', :aggregate_failures) do
  let(:m) { MB::Sound }
  let(:seq) { MB::Sound::Sequence }
  let(:ramp) { m::Sample.new(Numo::SFloat.new(48_000).seq / 48_000, sample_rate: 48_000.0) }
  let(:inst) { r = ramp; m::Sampler::Instrument.new { |i| i.region r, keys: 1, keytrack: 0 } }

  def clip(lanes, notes: [[0r, 1/2r]], length: 1r)
    events = notes.map { |s, l| seq::Event.new(start: s, length: l, value: 1, velocity: 1.0) }
    seq::Clip.new(events, length: length, loop: true, align: :launch, controls: lanes)
  end

  def bufs(node, buffers)
    outs = node.outputs
    Array.new(buffers) { outs.map { |o| o.sample(800).dup } }.transpose.map { |c| SpecBuffers.join(c) }
  end

  it 'scales by the volume lane on its exact sample, and pans by the pan lane' do
    lanes = [seq::ControlLane.new(:cc, 7, [[0r, 1.0], [1/8r, 0.25]]), seq::ControlLane.new(:cc, 10, [[0r, 0.0], [1/4r, 1.0]])]
    l, r = bufs(clip(lanes).sampler(inst, lanes: true), 40)
    plain = bufs(clip([]).sampler(inst), 40)[0]
    # (120 BPM: 1/8 whole note is 12000 frames)
    expect(l[0...12_000]).to eq(plain[0...12_000])
    expect(r[0...12_000].abs.max).to eq(0)
    expect((l[12_000...24_000] - plain[12_000...24_000] * 0.25).abs.max).to be < 1e-6
    expect(l[24_000...24_100].abs.max).to be < 1e-6
    expect((r[24_000...24_100] - plain[24_000...24_100] * 0.25).abs.max).to be < 1e-6
  end

  it 'bends by the bend lane in semitones at its range' do
    lanes = [seq::ControlLane.new(:bend, nil, [[0r, 12 / 48.0]], range: 48)]
    bent = bufs(clip(lanes).sampler(inst, lanes: { volume: false, pan: false }), 6)[0]
    up = bufs(clip([]).sampler(inst, transpose: 12), 6)[0]
    expect((bent - up).abs.max).to be < 1e-4
    expect(bent[1000]).to be_within(1e-3).of(2000 / 48_000.0)
  end

  it 'starts notes where the start lane says, read at each note-on' do
    lanes = [seq::ControlLane.new(:cc, 20, [[0r, 0.5], [1/4r, 0.0]])]
    out = bufs(clip(lanes, notes: [[0r, 1/4r], [1/4r, 1/4r]]).sampler(inst, lanes: { pan: false, volume: false }), 40)[0]
    expect(out[10]).to be_within(1e-3).of(0.5 + 10 / 48_000.0)
    expect(out[24_010]).to be_within(1e-3).of(10 / 48_000.0)
  end

  it 'smooths steps over a length' do
    lanes = [seq::ControlLane.new(:cc, 7, [[0r, 1.0], [1/8r, 0.0]])]
    out = bufs(clip(lanes).sampler(inst, lanes: { pan: false, smooth: 0.002 }), 20)[0]
    expect(out[12_000 + 48]).to be > 0.01
    expect(out[12_000 + 200]).to eq(0)
  end

  it 'keeps a lane in step while the synth lane sleeps (a volume lane rising with the next note)' do
    lanes = [seq::ControlLane.new(:cc, 7, [[0r, 0.0], [1/4r, 1.0]])]
    out = bufs(clip(lanes, notes: [[1/4r, 1/4r]]).sampler(inst, lanes: { pan: false }), 40)[0]
    expect(out[0...24_000].abs.max).to eq(0)
    expect(out[24_000 + 100]).to be_within(1e-3).of(100 / 48_000.0)
  end

  it 'checks its options' do
    v = clip([]).notes
    expect { inst.play(v, lanes: { wobble: 1 }) }.to raise_error(ArgumentError, /unknown keys :wobble/)
    expect { inst.play(v, lanes: { volume: 300 }) }.to raise_error(ArgumentError, /CC number/)
    expect { inst.play(trigger: 1, number: 1, lanes: true) }.to raise_error(ArgumentError, /synth voice/)
  end
end
