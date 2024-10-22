RSpec.describe(MB::Sound::Filter::HilbertIIR, :aggregate_failures) do
  let(:sample_rate) { 48000.0 }
  let(:nyquist) { sample_rate * 0.5 }
  let(:log100_15k) { Numo::SFloat.logspace(Math.log10(100 * Math::PI / nyquist), Math.log10(15000 * Math::PI / nyquist), 1000) }
  let(:log20_20k) { Numo::SFloat.logspace(Math.log10(20 * Math::PI / nyquist), Math.log10(20000 * Math::PI / nyquist), 1000) }
  let(:filter) { MB::Sound::Filter::HilbertIIR.new(rate: sample_rate) }

  it 'can be constructed' do
    expect { MB::Sound::Filter::HilbertIIR.new }.not_to raise_error
  end

  it 'can process a signal' do
    result = filter.process(Numo::SFloat[1,2,3])
    expect(result.length).to eq(2)
    expect(result).to all(be_a(Numo::SFloat))
  end

  it 'has a flat magnitude response for the cosine part' do
    result = filter.cosine_response(log20_20k).abs
    expect(result.min).to be >= -0.1.dB
    expect(result.max).to be <= 0.1.dB
  end

  it 'has a flat magnitude response for the sine part' do
    result = filter.sine_response(log20_20k).abs
    expect(result.min).to be >= -0.1.dB
    expect(result.max).to be <= 0.1.dB
  end

  it 'has a phase difference very close to 90deg from 100Hz to 15kHz' do
    cosine = MB::Sound.unwrap_phase(filter.cosine_response(log100_15k))
    sine = MB::Sound.unwrap_phase(filter.sine_response(log100_15k))
    diff = (sine - cosine) * 180.0 / Math::PI

    expect(diff.abs.min).to be > 89
    expect(diff.abs.max).to be < 91
    expect(diff.abs.mean.round(1)).to eq(90)
  end

  it 'has a phase difference reasonably close to 90deg from 20Hz to 20kHz' do
    cosine = MB::Sound.unwrap_phase(filter.cosine_response(log20_20k))
    sine = MB::Sound.unwrap_phase(filter.sine_response(log20_20k))
    diff = (sine - cosine) * 180.0 / Math::PI

    expect(diff.abs.min).to be > 82
    expect(diff.abs.max).to be < 91
    expect(diff.abs.mean.round(0)).to eq(90)
  end

  it 'can be constructed with a different sample rate' do
    frate = MB::Sound::Filter::HilbertIIR.new(rate: 23456)
    expect(MB::M.round(filter.cosine_response(Math::PI / 4.0), 5)).not_to eq(MB::M.round(frate.cosine_response(Math::PI / 4.0), 5))
  end
end
