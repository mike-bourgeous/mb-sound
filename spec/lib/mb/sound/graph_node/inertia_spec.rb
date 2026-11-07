RSpec.describe(MB::Sound::GraphNode::Inertia) do
  include BufferSizeHelpers

  INERTIA = MB::Sound::GraphNode::Inertia unless defined?(INERTIA)

  def input(data) = MB::Sound::ArrayInput.new(data: [data])

  def sine(f, amp, n = 9600)
    t = Numo::DFloat.new(n).seq
    Numo::SFloat.cast(Numo::NMath.sin(t * 2 * Math::PI * f / 48000) * amp)
  end

  def click(n = 64)
    x = Numo::SFloat.zeros(n)
    x[0] = 0.5
    x
  end

  # The follower written out on an interleaved stereo stream, as the
  # plug-in runs it: each substep pair is (the stream's previous sample,
  # this channel's sample), state per channel, double precision.
  def interleaved_reference(l, r, rate)
    st = [[0.0, 0.0], [0.0, 0.0]]
    prev = 0.0
    out = [[], []]
    l.length.times do |i|
      [l[i].to_f, r[i].to_f].each_with_index do |xn, c|
        y, v = st[c]
        [prev, xn].each do |u|
          d = ((u - y) - v).clamp(-rate, rate)
          v += d
          y += v
        end
        st[c] = [y, v]
        prev = xn
        out[c] << y
      end
    end
    out.map { |o| Numo::SFloat.cast(o) }
  end

  it 'turns a click into rate * [1, 4, 3] and then silence' do
    [0.05, 0.0045, 0.0005].each do |rate|
      out = input(click).inertia(rate).sample(64)
      expect(out[0...3]).to eq(Numo::SFloat.cast([rate, 4 * rate, 3 * rate]))
      # (silence within double rounding of the follower's state)
      expect(out[3..].abs.max).to be < 1e-17
    end
  end

  it 'reads the interleaved stream in :hardware mode (mono material differs left and right)' do
    b = MB::Sound.stereo(input(click), input(click)).inertia(0.05, mode: :hardware)
    l, r = b.outputs.map { |o| o.sample(64) }
    expect(l[0...4].to_a.map { |v| v.round(7) }).to eq([0.05, 0.2, 0.15, 0])
    expect(r[0...4].to_a.map { |v| v.round(7) }).to eq([0.15, 0.2, 0.05, 0])
    expect(l[4..].abs.max).to eq(0)
    expect(r[4..].abs.max).to eq(0)
  end

  it 'matches the interleaved reference sample for sample, chirps included' do
    # (a loud 1 kHz sine at slew 10 is deep in its limit cycles, a chaotic
    # regime where any change in the arithmetic would show)
    l = sine(1000, 0.89) + sine(3100, 0.1)
    r = sine(700, 0.5) + sine(5000, 0.3)
    ref_l, ref_r = interleaved_reference(l, r, 0.005)
    b = MB::Sound.stereo(input(l), input(r)).inertia(0.005, mode: :hardware)
    out = b.outputs.map { |o| SpecBuffers.join(Array.new(12) { o.sample(800).dup }) }
    expect(out[0]).to eq(ref_l)
    expect(out[1]).to eq(ref_r)
  end

  # (exact while each sample moves at most +-rate from the last: the first
  # substep then stops the velocity within the limit; a 1 kHz sine at 0.1
  # moves 0.013 a sample and comes out bent at rate 0.005)
  it 'passes signals whose per-sample change stays within the rate (within float32 rounding)' do
    [[100, 0.0316, 0.005], [100, 0.9, 0.045], [1000, 0.03, 0.005]].each do |f, amp, rate|
      s = sine(f, amp)
      out = input(s).inertia(rate).sample(s.length)
      # (after the start: a sine starting at full slope from rest needs a
      # few samples of acceleration first)
      expect((out[4800..] - s[4800..]).abs.max).to be < 1e-9, "#{f} Hz at #{amp}"
    end
  end

  it 'breaks fast loud signals into louder limit cycles (chirps)' do
    s = sine(1000, 0.89)
    out = input(s).inertia(0.005).sample(s.length)
    expect(out[4800..].abs.max).to be > 1.5
  end

  it 'matches its Ruby mirror sample for sample (number and node rates, both modes, split buffers)' do
    l = sine(1000, 0.89) + sine(3100, 0.1)
    r = sine(5000, 0.5)
    rate = Numo::SFloat.cast(Numo::DFloat.new(9600).seq.map { |i| 0.003 + 0.004 * Math.sin(i * 0.001) })
    [[0.005, 1, nil], [rate, 1, nil], [0.0125, 0, r], [rate, 1, r]].each do |rt, lag, first|
      [1, 2, 3, 5].each do |substeps|
        sc = Numo::DFloat.zeros(3)
        sr = Numo::DFloat.zeros(3)
        c = []
        rb = []
        [0...800, 800...801, 801...9600].each do |range|
          x = l[range].dup
          f = first && first[range].dup
          rr = rt.is_a?(Numo::NArray) ? rt[range].dup : rt
          c << MB::Sound::FastControl.inertia(x, Numo::SFloat.zeros(x.length), f, lag, rr, substeps, sc).dup
          rb << INERTIA.process_ruby(x, Numo::SFloat.zeros(x.length), f, lag, rr, substeps, sr).dup
        end
        expect(SpecBuffers.join(c)).to eq(SpecBuffers.join(rb)), "lag #{lag}, substeps #{substeps}"
        expect(sc).to eq(sr)
      end
    end
  end

  it 'gives the same output at any buffer size' do
    expect_invariant(-> { (110.hz.saw.at(0.9) + 2300.hz.sine.at(0.3)).inertia(0.004) }, seconds: 0.5)
    expect_invariant(-> {
      b = MB::Sound.stereo(220.hz.square.at(0.8), 330.hz.saw.at(0.7)).inertia(0.2.hz.lfo.at(0.002..0.01), mode: :hardware)
      b.outputs[0] + b.outputs[1]
    }, seconds: 0.5)
  end

  it 'takes a node rate as its values (read as float32, like every signal input)' do
    s = sine(1000, 0.89)
    a = input(s).inertia(0.00390625).sample(s.length)
    b = input(s).inertia(0.00390625.constant).sample(s.length)
    expect(b).to eq(a)
  end

  it 'prints and loads as Ruby' do
    g = (110.hz.saw.at(0.9) + 2300.hz.sine.at(0.3)).inertia(0.004, substeps: 3)
    expect(g.to_ruby).to eq('(110.hz.saw.at(0.9) + 2300.hz.sine.at(0.3)).inertia(0.004, substeps: 3)')
    loaded = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(g))
    expect(SpecBuffers.join(Array.new(3) { loaded.sample(800).dup })).to eq(SpecBuffers.join(Array.new(3) { g.sample(800).dup }))
    h = MB::Sound.stereo(110.hz.saw, 220.hz.saw).inertia(0.005, mode: :hardware)
    expect(h.to_ruby).to eq('stereo(110.hz.saw, 220.hz.saw).inertia(0.005, mode: :hardware)')
  end

  it 'rejects bad settings' do
    expect { 1.constant.inertia(-0.1) }.to raise_error(ArgumentError, /negative/)
    expect { 1.constant.inertia(0.1, substeps: 0) }.to raise_error(ArgumentError, /Substeps/)
    expect { 1.constant.inertia(0.1, mode: :plugin) }.to raise_error(ArgumentError, /modes/)
    expect { MB::Sound.stereo(1.constant, 1.constant).inertia(0.1, substeps: 3, mode: :hardware) }.to raise_error(ArgumentError, /2 substeps/)
  end
end
