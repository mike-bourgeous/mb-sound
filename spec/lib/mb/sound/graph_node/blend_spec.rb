# sig.blend(mix) { |s| fx } (ux-1 round 2).
RSpec.describe(MB::Sound::GraphNode::BlendMethods, :aggregate_failures) do
  def arr(x) = MB::Sound::ArrayInput.new(data: [Numo::SFloat.cast(x)])

  it 'mixes dry and wet linearly by default, like the effects\' own mix:' do
    x = Numo::SFloat[0.5, -0.25, 1, 0]
    out = arr(x).blend(0.25) { |s| s * 2 }.sample(4)
    expect(out.to_a).to eq((x * 0.75 + x * 2 * 0.25).to_a)
    expect(arr(x).blend(0) { |s| s * 2 }.sample(4).to_a).to eq(x.to_a)
    expect(arr(x).blend(1) { |s| s * 2 }.sample(4).to_a).to eq((x * 2).to_a)
  end

  it 'keeps power with curve: :power, and takes nodes and knob names as the mix' do
    x = Numo::SFloat[1, 1, 1, 1]
    out = arr(x).blend(0.5, curve: :power) { |s| s * 0 }.sample(4)
    expect(out[0]).to be_within(1e-6).of(Math.sqrt(0.5))
    sweep = arr(Numo::SFloat[0, 0.25, 0.75, 1])
    out = arr(x).blend(sweep) { |s| s * 3 }.sample(4)
    expect(out.to_a).to eq([1, 1.5, 2.5, 3].map(&:to_f))
    session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    MB::Sound::Session.with_context(session: session) do
      MB::Sound.knob(:spec_wet, 0.5)
      g = 1.constant.blend(:spec_wet) { |s| s * 3 }
      session.add(g, name: :g, at: :now)
      expect(session.process_buffer[0][-1]).to be_within(1e-6).of(2.0 * MB::Sound.master_gain)
    end
  ensure
    session&.close
    MB::Sound.rewind # (the shared transport)
  end

  it 'delays the dry path by the effect\'s lookahead so the two line up' do
    x = Numo::SFloat.zeros(64)
    x[5] = 0.5
    out = arr(x).blend(0.5) { |s| s.compress(threshold: 0.db, lookahead: 10.samples) }.sample(64)
    expect(out.to_a.each_index.select { |i| out[i].abs > 1e-6 }).to eq([15])
    raw = arr(x).blend(0.5, compensate: false) { |s| s.compress(threshold: 0.db, lookahead: 10.samples) }.sample(64)
    expect(raw.to_a.each_index.select { |i| raw[i].abs > 1e-6 }).to eq([5, 15])
  end

  it 'hands a bundle to the effect whole, records itself, and refuses bad mixes' do
    st = MB::Sound.stereo(110.hz.saw, 111.hz.saw).blend(0.3) { |s| s.reverb(:hall, mix: 1) }
    expect(st.channel_count).to eq(2)
    expect(st.to_ruby).to include('.blend(0.3) { |s|', 'reverb(:hall, mix: 1)')
    expect { 1.constant.blend(1.5) { |s| s } }.to raise_error(ArgumentError, /0\.\.1/)
    expect { 1.constant.blend(0.5) }.to raise_error(ArgumentError, /needs a block/)
    expect { 1.constant.blend(0.5, curve: :log) { |s| s } }.to raise_error(ArgumentError, /linear or :power/)
  end
end
