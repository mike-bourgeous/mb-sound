require_relative '../../../../support/synthetic_sounds'

RSpec.describe(MB::Sound::Analysis::ImpulseResponse, :aggregate_failures) do
  let(:t60s) { { 125 => 1.2, 250 => 1.1, 500 => 1.0, 1000 => 0.9, 2000 => 0.7, 4000 => 0.5, 8000 => 0.3 } }

  it 'recovers per-octave T60s of decaying noise within 10%, under a noise floor too' do
    [0.0, 1e-4].each do |floor|
      ir = described_class.new(SyntheticSounds.impulse_response(t60s, seconds: 2, seed: 2, floor: floor))
      t60s.each do |band, want|
        expect(ir.t60[band]).to be_within(want * 0.1).of(want), "#{band} Hz, floor #{floor}: #{ir.t60[band]}"
      end
      expect(ir.t60_broadband).to be_between(0.5, 1.2)
    end
  end

  it 'finds the onset, the late correlation, and the clarity' do
    ir = described_class.new(SyntheticSounds.impulse_response(t60s, predelay: 0.025, correlation: 0.5, seed: 3))
    expect(ir.onset).to be_within(0.001).of(0.025)
    expect(ir.correlation).to be_within(0.1).of(0.5)
    expect(described_class.new(SyntheticSounds.impulse_response(t60s, seed: 4)).correlation.abs).to be < 0.1
    # shorter decays put more energy early
    short = described_class.new(SyntheticSounds.impulse_response(t60s.transform_values { |v| v / 3 }, seed: 5))
    expect(short.c80).to be > ir.c80 + 5
    expect(ir.edt[1000]).to be_within(0.2).of(0.9)
  end

  it 'reads the late tail tilt' do
    flat = described_class.new(SyntheticSounds.impulse_response(t60s, seed: 6)).tail_levels
    dark = described_class.new(SyntheticSounds.impulse_response(t60s, seed: 6, tilt_db: -3)).tail_levels
    # 6 octaves from 125 Hz to 8 kHz: 18 dB more fall
    expect((flat[8000] - flat[125]) - (dark[8000] - dark[125])).to be_within(1.5).of(18)
  end

  it 'reads Samples, files, and 2D arrays, and prints a summary' do
    chans = SyntheticSounds.impulse_response(t60s, seconds: 1, seed: 7)
    path = tmp_path('ir.wav')
    MB::Sound.write(path, chans.map { |c| c * 0.5 }, sample_rate: 48000)
    a = described_class.new(path)
    b = described_class.new(Numo::DFloat[*chans.map(&:to_a)])
    expect(a.channels.length).to eq(2)
    expect(a.t60[1000]).to be_within(0.02).of(b.t60[1000])
    expect(a.to_s).to match(/Impulse: 2 ch, 1\.00 s.*\nT60 s  125: [0-9.]+/)
    expect(a.to_h).to include(:t60, :c80, :tail_levels, :correlation)
  end
end
