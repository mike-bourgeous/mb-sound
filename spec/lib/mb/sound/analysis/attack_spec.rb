require_relative '../../../../support/synthetic_sounds'

RSpec.describe(MB::Sound::Analysis::Attack) do
  let(:attack) { MB::Sound::Analysis::Attack }

  it 'measures the onset and rise of a ramped tone' do
    x = SyntheticSounds.tone(1000, 0.3)
    ramp = (Numo::DFloat.new(x.length).seq / 480.0).clip(0, 1) # 10 ms linear rise
    x = Numo::DFloat.zeros(2400).concatenate(x * ramp)
    a = attack.new(x)
    expect(a.onset).to be_a(MB::Sound::Length::Seconds)
    expect(a.onset.to_f).to be_within(0.001).of(0.05)
    expect(a.rise.to_f).to be_within(0.0015).of(0.008)
    expect(a.attack_peak).to be_a(MB::Sound::Decibels)
    expect(a.clicks).to eq([])
    expect(a.clip).to be_nil
    expect(a.to_s).to include('onset 5', 'no clicks', 'no flat tops')
  end

  it 'finds a click on a smooth tone' do
    x = SyntheticSounds.sine(110, 0.3)
    x[960] += 0.6
    a = attack.new(x)
    expect(a.clicks.length).to eq(1)
    expect(a.clicks.first.to_f).to be_within(0.0015).of(0.02)
    expect(a.to_s).to include('clicks at +20 ms')
  end

  it 'does not call a waveform edge a click (a saw has one every cycle)' do
    t = SyntheticSounds.times(0.3)
    saw = SyntheticSounds.fade_in((t * 110 % 1) * 2 - 1) * 0.4
    expect(attack.new(saw).clicks).to eq([])
  end

  it 'finds flat tops on a clipped sine and not on clean sines' do
    clipped = (SyntheticSounds.sine(110, 0.3) * 4).clip(-0.5, 0.5)
    c = attack.new(clipped).clip
    expect(c).not_to be_nil
    expect(c.level.decibels).to be_within(0.01).of(20 * Math.log10(0.5))
    expect(c.share).to be > 0.5
    [40, 110, 1000].each do |hz|
      expect(attack.new(SyntheticSounds.sine(hz, 0.3)).clip).to be_nil
    end
  end

  it 'reads brightness falling over a closing filter' do
    t = SyntheticSounds.times(0.2)
    x = Numo::DFloat.zeros(t.length)
    (1..30).each { |k| x += Numo::NMath.sin(t * 2 * Math::PI * 110 * k) * Numo::NMath.exp(-t * (k - 1) * 3) / k }
    a = attack.new(SyntheticSounds.fade_in(x * 0.3))
    expect(a.brightness[0]).to be > 1.4 * a.brightness[2]
    expect(a.to_s).to include('darkening')
    steady = attack.new(SyntheticSounds.tone(110, 0.2, harmonics: 30)).brightness
    expect(steady.max / steady.min).to be < 1.15
  end

  it 'reads perceived pitch over the attack and the body' do
    x = SyntheticSounds.tone(440, 0.03).concatenate(SyntheticSounds.tone(220, 0.4))
    a = attack.new(x)
    expect(a.pitch.note_label).to start_with('A4')
    expect(a.body_pitch.note_label).to start_with('A3')
  end

  it 'measures round 3 attack distance: 0 for the same sound, more for a slower attack' do
    x = MB::Sound::Analysis::Signal.from(SyntheticSounds.tone(220, 0.3)).aligned
    slow = x.data * (Numo::DFloat.new(x.length).seq / 1440.0).clip(0, 1)
    expect(attack.distance(x, x)).to eq(0)
    expect(attack.distance(x, MB::Sound::Analysis::Signal.new(slow))).to be > 0.5
  end
end
