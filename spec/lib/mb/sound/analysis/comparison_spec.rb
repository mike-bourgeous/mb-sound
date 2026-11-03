require_relative '../../../../support/synthetic_sounds'

RSpec.describe(MB::Sound::Analysis::Comparison) do
  let(:cmp) { MB::Sound::Analysis::Comparison }
  let(:target) { SyntheticSounds.tone(220, 1, vibrato: [5, 10]) }

  it 'is zero for the same sound, at any level and onset' do
    c = cmp.new(target, Numo::DFloat.zeros(300).concatenate(target * 0.25))
    expect(c.total).to be_within(1e-6).of(0)
    expect(c.terms.values).to all(be_within(1e-6).of(0))
    expect(c.timbre).to be < -100
  end

  it 'is small for two near-identical renders and grows term by term with the difference' do
    near = cmp.new(target, SyntheticSounds.tone(220.2, 1, vibrato: [5, 10]))
    am = cmp.new(target, SyntheticSounds.tone(220, 1, vibrato: [5, 10], am: [4, 3]))
    dull = cmp.new(target, SyntheticSounds.tone(220, 1, harmonics: 3, vibrato: [5, 10]))
    slow = target * (Numo::DFloat.new(target.length).seq / 2400.0).clip(0, 1)
    soft = cmp.new(target, slow)

    expect(near.total).to be < 0.25
    expect(am.modulation).to be > 3 * near.modulation
    expect(dull.spectral).to be > 3 * near.spectral
    expect(soft.attack).to be > 3 * near.attack
    [am, dull, soft].each { |c| expect(c.total).to be > near.total }
  end

  it 'adds the terms with L3 weights, or given ones' do
    c = cmp.new(target, SyntheticSounds.tone(220, 1, am: [3, 2]))
    expect(c.total).to be_within(1e-12).of(c.spectral + 2 * c.modulation + 0.3 * c.attack)
    expect(c[:total]).to eq(c.total)
    expect(c[:modulation]).to eq(c.modulation)
    expect(c.spectral_parts.keys).to eq(%i[lsd sc env])
    expect(c.to_s).to match(/\AL3 [\d.]+ = spectral [\d.]+ \(lsd .* \+ 2\.0 x modulation [\d.]+ \+ 0\.3 x attack [\d.]+; timbre -?[\d.]+ dB\z/)
    only = cmp.new(target, SyntheticSounds.tone(220, 1, am: [3, 2]), weights: { modulation: 1 })
    expect(only.total).to be_within(1e-12).of(c.modulation)
    expect { c[:nope] }.to raise_error(ArgumentError, /No term :nope/)
  end

  it 'is deterministic' do
    other = SyntheticSounds.tone(220, 1, harmonics: 6)
    expect(cmp.new(target, other).to_h).to eq(cmp.new(target, other).to_h)
  end

  it 'ranks candidates closest first' do
    r = MB::Sound::Analysis.rank(target, {
      'far' => SyntheticSounds.tone(330, 1),
      'near' => SyntheticSounds.tone(220.2, 1, vibrato: [5, 10]),
      'mid' => SyntheticSounds.tone(220, 1, vibrato: [5, 10], am: [4, 3]),
    })
    expect(r.labels).to eq(%w[near mid far])
    expect(r.first.score).to eq(r.first.comparison.total)
    expect(r.to_s.lines.first).to include('label', 'total', 'spectral', 'modul.', 'attack', 'timbre')
    expect(r.to_s.lines[1]).to start_with('1    near')
    by = MB::Sound::Analysis.rank(target, [SyntheticSounds.tone(330, 1), target], by: :modulation)
    expect(by.labels).to eq(%w[2 1])
  end
end
