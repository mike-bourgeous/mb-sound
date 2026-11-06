require_relative '../../../support/synthetic_sounds'

RSpec.describe(MB::Sound::ReverbMatch, :aggregate_failures) do
  T60S = { 125 => 0.8, 250 => 0.75, 500 => 0.7, 1000 => 0.65, 2000 => 0.55, 4000 => 0.45, 8000 => 0.3 }.freeze

  # One fit shared by the examples (each fit renders the reverb ~60 times)
  def self.fitted
    @fitted ||= MB::Sound::ReverbMatch.new(SyntheticSounds.impulse_response(T60S, seconds: 1.2, predelay: 0.03, seed: 11, correlation: 0.3), max_evals: 40)
  end

  let(:m) { self.class.fitted }

  it 'fits per-band decay times, tail tone, predelay, and width' do
    e = m.errors
    T60S.each_key { |b| expect(e[:t60][b].abs).to be < 0.2, "#{b} Hz: #{e[:t60][b]}" }
    expect(Math.exp(e[:t60_rms]) - 1).to be < 0.12
    expect(e[:tail_rms]).to be < 1.5
    expect(e[:onset].abs).to be < 0.002
    expect(m.settings[:predelay]).to be > 0.005
    expect(m.width).to be_between(0.6, 0.85) # (correlation 0.3: sqrt(0.7 / 1.3) = 0.73)
    expect(m.settings).to include(:room_size, :decay, :level, :extra_time)
    expect(m.settings.keys & [:damping, :lowpass]).not_to be_empty
    expect(m.output_channels).to eq(2)
  end

  it 'builds the graph it prints, with unit wet energy for an impulse' do
    x = Numo::SFloat.zeros(48000); x[0] = 1
    a = m.apply(MB::Sound::ArrayInput.new(data: [x]), wet: 1)
    sig = MB::Sound::ArrayInput.new(data: [x])
    b = eval(m.to_ruby('sig'), MB::Sound.instance_eval { binding }.tap { |bd| bd.local_variable_set(:sig, sig) }) # rubocop:disable Security/Eval
    read = ->(g) { Array.new(10) { g.outputs.map { |o| o.sample(4800).dup } }.transpose } # (outputs in turn, each buffer)
    ra = read.(a)
    rb = read.(b)
    expect(ra).to eq(rb)
    energy = ra.map { |bufs| bufs.sum { |v| (Numo::DFloat.cast(v)**2).sum } }
    energy.each { |en| expect(en).to be_within(0.15).of(1.0) }
  end

  it 'mixes dry and wet like convolve' do
    x = Numo::SFloat.new(2000).seq.map { |i| Math.sin(i * 0.05) }
    dry = m.apply(MB::Sound::ArrayInput.new(data: [x]), mix: 0).outputs.map { |o| o.sample(2000).dup }
    expect(dry.map { |d| (d - x).abs.max }.max).to be < 1e-6
  end

  it 'defaults to the wet graph at -10 dB, as convolve' do
    x = Numo::SFloat.zeros(9600); x[0] = 1
    read = ->(g) { Array.new(2) { g.outputs.map { |o| o.sample(4800).dup } }.transpose }
    a = read.(m.apply(MB::Sound::ArrayInput.new(data: [x])))
    b = read.(m.apply(MB::Sound::ArrayInput.new(data: [x]), wet: 1))
    a.flatten.zip(b.flatten).each { |p, q| expect((p - q * 10**-0.5).abs.max).to be < 1e-6 }
    expect { m.apply(MB::Sound::ArrayInput.new(data: [x]), mix: 0.3, dry: 0.5) }.to raise_error(ArgumentError, /crossfade/)
  end

  it 'saves the fit as a library effect preset with a mix param' do
    dir = File.dirname(tmp_path('presets/x'))
    allow(MB::Sound::GraphIO).to receive(:presets_dir).and_return(dir)
    MB::Sound::Library.reload!
    path = nil
    expect { path = m.save(:fitted_test) }.to output(/Saved fitted_test/).to_stdout
    text = File.read(path)
    expect(text).to include('kind: :effect', 'tags: [:fitted]', 'param :mix, (0.0..1.0).at(0.3)', 'input.blend(mix, curve: :power)', '.reverb(room_size:')
    x = Numo::SFloat.zeros(4800); x[0] = 1
    g = MB::Sound::GraphIO.load(path, inputs: { input: MB::Sound::ArrayInput.new(data: [x]) })
    ref = m.apply(MB::Sound::ArrayInput.new(data: [x]), mix: 0.3)
    expect(g.outputs.map { |o| o.sample(4800).dup }).to eq(ref.outputs.map { |o| o.sample(4800).dup })
  ensure
    MB::Sound::Library.reload!
  end

  it 'plots EDC curves and T60 by band' do
    path = m.plot(tmp_path('match.png'))
    expect(File.size(path)).to be > 10_000
    expect(m.to_s).to include('Fitted reverb:', 'T60 RMS error')
  end

  it 'refuses a silent impulse' do
    expect { described_class.new(Numo::DFloat.zeros(48000)) }.to raise_error(ArgumentError, /no T60/)
  end
end
