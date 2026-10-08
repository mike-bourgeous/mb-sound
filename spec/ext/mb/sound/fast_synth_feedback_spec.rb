RSpec.describe('MB::Sound::FastSynth.feedback_sine') do
  let(:adv) { 1.0 / 48000 }

  def run(buf, freq: 440.0, pm: nil, fb: 1.0, level: 1.0, state: [0.0], fb_state: [0.0, 0.0, 0.0], gain: 1.0, offset: 0.0, remove_dc: false)
    MB::Sound::FastSynth.feedback_sine(buf, freq, pm, adv, gain, offset, state, fb_state, fb, level, remove_dc)
  end

  it 'fills an inplace buffer and updates both states' do
    buf = Numo::SFloat.zeros(64).inplace!
    state = [0.25]
    fb_state = [0.0, 0.0, 0.0]
    out = run(buf, state: state, fb_state: fb_state)
    expect(out).to equal(buf)
    expect(buf[0]).to be_within(1e-6).of(1.0) # sin(pi / 2)
    expect(state[0]).to be_within(1e-12).of((0.25 + 440.0 * 64 * adv) % 1)
    expect(fb_state[0]).to be_within(1e-6).of(buf[63])
    expect(fb_state[1]).to be_within(1e-6).of(buf[62])
    expect(fb_state[2]).to eq(0)
  end

  it 'tracks and removes the DC offset when asked, without changing the loop' do
    kept_state = [0.0, 0.0, 0.0]
    removed_state = [0.0, 0.0, 0.0]
    kept = run(Numo::SFloat.zeros(4800).inplace!, fb: 2.0, fb_state: kept_state).not_inplace!
    removed = run(Numo::SFloat.zeros(4800).inplace!, fb: 2.0, fb_state: removed_state, remove_dc: true).not_inplace!
    expect(removed_state[0..1]).to eq(kept_state[0..1])
    expect(removed_state[2]).to be_within(0.03).of(kept[-440..].mean)
    expect((kept - removed - removed_state[2])[-1].abs).to be < 1e-6
    expect(removed[-1100..].mean.abs).to be < 0.01
    expect(kept[-1100..].mean).to be < -0.2
  end

  it 'returns a new buffer for a non-inplace one, leaving it unchanged' do
    buf = Numo::SFloat.zeros(16)
    out = run(buf)
    expect(out).not_to equal(buf)
    expect(buf.abs.max).to eq(0)
  end

  it 'reads every input as an NArray of float32 values, DFloat or SFloat' do
    n = 100
    freq = Numo::DFloat.linspace(100, 300, n)
    pm = Numo::DFloat.linspace(0, 1, n)
    fb = Numo::DFloat.linspace(0, 2, n)
    lvl = Numo::DFloat.linspace(1, 0.2, n)
    a = run(Numo::SFloat.zeros(n).inplace!, freq: freq, pm: pm, fb: fb, level: lvl)
    b = run(Numo::SFloat.zeros(n).inplace!, freq: Numo::SFloat.cast(freq), pm: Numo::SFloat.cast(pm), fb: Numo::SFloat.cast(fb), level: Numo::SFloat.cast(lvl))
    expect(a).to eq(b)
  end

  it 'reads non-contiguous views' do
    n = 50
    fb = Numo::SFloat.linspace(0, 2, n * 2)[(0..) % 2]
    a = run(Numo::SFloat.zeros(n).inplace!, fb: fb)
    b = run(Numo::SFloat.zeros(n).inplace!, fb: fb.dup)
    expect(a).to eq(b)
  end

  it 'handles an empty buffer' do
    state = [0.5]
    expect(run(Numo::SFloat.zeros(0).inplace!, state: state).length).to eq(0)
    expect(state[0]).to eq(0.5)
  end

  it 'rejects bad states and input lengths' do
    buf = Numo::SFloat.zeros(8).inplace!
    expect { run(buf, fb_state: [0.0, 0.0]) }.to raise_error(ArgumentError, /three elements/)
    expect { run(buf, state: [0.0, 1.0]) }.to raise_error(ArgumentError)
    expect { run(buf, fb: Numo::SFloat.zeros(7)) }.to raise_error(ArgumentError, /Feedback/)
    expect { run(buf, level: Numo::SFloat.zeros(9)) }.to raise_error(ArgumentError, /Level/)
    expect { run(buf, fb_state: nil) }.to raise_error(TypeError)
  end
end
