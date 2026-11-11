# (omnibus19; Kez, persona panel 3: the mastering report should say what the
# chain did to the music, e.g. the sub ducking under the snare)
RSpec.describe(MB::Sound::Mastering::ChainEffect) do
  RATE = 48000 unless defined?(RATE)

  # 8 seconds: a held 50 Hz sub and a 4 kHz burst every half second; +duck+
  # dB off the sub for 0.15 s after each burst in the output, which is the
  # input +trim+ dB louder and +extra+ dB off everything in seconds 4-6.
  def signals(duck:, trim: 6.0, extra: 0.0)
    t = Numo::DFloat.new(8 * RATE).seq / RATE
    sub = Numo::NMath.sin(t * 2 * Math::PI * 50) * 0.5
    burst = Numo::NMath.sin(t * 2 * Math::PI * 4000) * 0.3 * ((t % 0.5) < 0.05)
    gain = Numo::DFloat.ones(t.length)
    gain[(t % 0.5).lt(0.15).where] = 10**(-duck / 20.0)
    loud = 10**(trim / 20.0)
    spot = Numo::DFloat.ones(t.length)
    spot[(t.ge(4) & t.lt(6)).where] = 10**(-extra / 20.0)
    input = sub + burst
    output = (sub * gain + burst) * loud * spot
    [[Numo::SFloat.cast(input)] * 2, [Numo::SFloat.cast(output)] * 2]
  end

  def bars = (0...4).map { |i| [i * 2.0, (i + 1) * 2.0] }

  it 'finds the low end ducking under the hits (pumping) and names it' do
    input, output = signals(duck: 6)
    e = described_class.measure(input, output, 6.0, sample_rate: RATE, bars: bars, labels: [1, 2, 3, 4], low_hz: 120)
    expect(e.low_swing).to be_within(1.0).of(6)
    expect(e.to_s).to include('below 120 Hz the gain swings').and include('pumping')
    # (the trim isn't counted as the chain's doing)
    expect(e.typical).to be > -3
  end

  it 'says nothing of pumping for a steady chain, and names the bars it took the most off' do
    input, output = signals(duck: 0, extra: 4)
    e = described_class.measure(input, output, 6.0, sample_rate: RATE, bars: bars, labels: [9, 10, 11, 12], low_hz: 120)
    expect(e.low_swing).to be < 1
    expect(e.to_s).not_to include('pumping')
    expect(e.typical).to be_within(0.5).of(0)
    expect(e.most).to be_within(0.5).of(-4)
    expect(e.bars).to eq([11])
    expect(e.to_s).to match(/\Awhat the chain did: [-+]0\.0 dB typical, at most -4\.0 dB \(bar 11\)/)
  end

  it 'gives nil for silence' do
    z = [Numo::SFloat.zeros(48000)] * 2
    expect(described_class.measure(z, z, 0.0, sample_rate: RATE, bars: [[0.0, 1.0]], labels: [1])).to be_nil
  end

  it 'reports in a mastered render' do
    MB::Sound.render(tmp_path('m.wav'), bars: 2, report: :tracks) {
      MB::Sound.master :club
      MB::Sound.bg :drums, MB::Sound.tr808(MB::Sound.grid(16, bd: 'x...x...x...x...', snare: '....x.......x...')) * 2
      MB::Sound.bg :sub, MB::Sound.seq(MB::Sound::C1.n1).loop.tone.sine.at(-6.db)
    }
    r = MB::Sound::Mastering::Targeting.last
    expect(r.chain_effect).to be_a(described_class)
    expect(r.to_s).to include('what the chain did:')
    expect(MB::Sound::MixReport.last.to_h[:mastering][:chain_effect]).to include(:typical, :low_swing)
  ensure
    MB::Sound.rewind
  end
end
