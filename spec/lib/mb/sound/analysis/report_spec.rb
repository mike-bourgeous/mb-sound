require_relative '../../../../support/synthetic_sounds'

RSpec.describe(MB::Sound::Analysis::Report) do
  it 'reads a tone with vibrato and AM as a report with every section' do
    r = MB::Sound::Analysis.analyze(SyntheticSounds.tone(220, 3, vibrato: [5.5, 18], am: [0.6, 1.5]))
    text = r.to_s
    expect(text).to include('pitch:', 'attack (first 50 ms):', 'modulation:', 'movement:', 'bleed screen:')
    expect(text).to include('vibrato 5.5 Hz (rate ±0.', '), ±1', 'AM 0.60 Hz (rate ±0.0')
    expect(r.pitch.vibrato.rate.frequency).to be_within(0.15).of(5.5)
    expect(r.inspect).to match(/\A#<Analysis::Report 3\.000 s, A3.*, 1 AM peaks, clean/)
  end

  it 'gives plain values in to_h' do
    h = MB::Sound::Analysis.analyze(SyntheticSounds.kick).to_h
    expect(h[:pitch][:sweep][:to_hz]).to be_within(5).of(61)
    expect(h[:attack][:clicks]).to eq([])
    expect(h[:bleed][:clean]).to eq(true)
    plain = ->(v) {
      case v
      when Hash then v.values.all?(&plain)
      when Array then v.all?(&plain)
      else [Float, Integer, String, Symbol, NilClass, TrueClass, FalseClass].any? { |c| v.is_a?(c) }
      end
    }
    expect(plain.(h)).to eq(true)
  end

  it 'is deterministic' do
    x = SyntheticSounds.tone(220, 1, am: [2, 2])
    expect(MB::Sound::Analysis.analyze(x).to_h).to eq(MB::Sound::Analysis.analyze(x).to_h)
  end

  it 'notes a graph cut at GRAPH_SECONDS' do
    stub_const('MB::Sound::Analysis::Signal::GRAPH_SECONDS', 0.5)
    expect(MB::Sound::Analysis.analyze(220.hz.ramp).to_s.lines.first).to include('graph cut at 0.5 s; pass seconds:')
  end
end
