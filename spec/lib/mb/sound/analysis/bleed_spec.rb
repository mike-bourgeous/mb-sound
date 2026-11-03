require_relative '../../../../support/synthetic_sounds'

RSpec.describe(MB::Sound::Analysis::Bleed) do
  let(:bleed) { MB::Sound::Analysis::Bleed }

  it 'passes a clean kick, with or without its own click' do
    [SyntheticSounds.kick, SyntheticSounds.kick(click: true)].each do |k|
      b = bleed.new(k)
      expect(b.clean?).to eq(true)
      expect(b.masks).to eq([])
      expect(b.to_s).to start_with('bleed screen: clean')
    end
  end

  it 'finds a hat 120 ms into a kick, with or without the kick click' do
    [false, true].each do |click|
      b = bleed.new(SyntheticSounds.add_at(SyntheticSounds.kick(click: click), SyntheticSounds.hat, 0.12))
      flag = b.flags.find { |f| f.kind == :second_onset }
      expect(flag).not_to be_nil, "click: #{click}: #{b.flags.map(&:text)}"
      expect(flag.mask[:above_hz]).to eq(2000.0)
      expect(flag.mask[:from]).to be_within(0.012).of(0.115)
      expect(b.to_s).to include('another hit', 'a reason to look, not a verdict')
    end
  end

  it 'finds a sustained top over a short body (an open hat over a tom)' do
    t = SyntheticSounds.times(0.4)
    tom = Numo::NMath.sin(t * 2 * Math::PI * 150) * Numo::NMath.exp(-t * 40) * 0.7
    n = SyntheticSounds.noise(0.4, seed: 5)
    open_hat = MB::Sound::Analysis::DSP.brickwall(n, 48000, nil, low: 4000.0) * Numo::NMath.exp(-t * 3) * 0.1
    b = bleed.new(SyntheticSounds.fade_in(tom + open_hat))
    expect(b.flags.map(&:kind)).to include(:sustained_top)
  end

  it 'finds low energy under a steady note (a kick under a chopped note)' do
    note = SyntheticSounds.tone(330, 1, harmonics: 8, level: 0.3)
    kicks = [0.0, 0.25, 0.5, 0.75].reduce(Numo::DFloat.zeros(note.length)) { |a, s| SyntheticSounds.add_at(a, SyntheticSounds.kick(0.2) * 0.3, s) }
    clean = bleed.new(note)
    expect(clean.clean?).to eq(true)
    expect(clean.f0).to be_within(2).of(330)

    b = bleed.new(note + kicks)
    flag = b.flags.find { |f| f.kind == :low_energy }
    expect(flag).not_to be_nil, b.flags.map(&:text).inspect
    expect(flag.mask[:below_hz]).to be_within(2).of(0.7 * 330)
  end

  it 'finds noise between the harmonics of a note' do
    note = SyntheticSounds.tone(220, 1, harmonics: 40, level: 0.3)
    grit = MB::Sound::Analysis::DSP.brickwall(SyntheticSounds.noise(1, seed: 9), 48000, nil, low: 2000.0) * 0.15
    expect(bleed.new(note).flags.map(&:kind)).not_to include(:between_harmonics)
    expect(bleed.new(note + grit).flags.map(&:kind)).to include(:between_harmonics)
  end
end
