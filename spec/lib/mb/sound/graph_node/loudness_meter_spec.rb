RSpec.describe(MB::Sound::GraphNode::LoudnessMeter, :aggregate_failures) do
  let(:tone) { 1000.hz.sine.at(-23.db) }

  it 'passes a mono node through unchanged and measures it' do
    expected = 1000.hz.sine.at(-23.db).sample(48000).dup
    m = tone.loudness_meter
    expect(m).to be_a(MB::Sound::GraphNode::Channels)
    expect(m.channel_count).to eq(1)

    out = Numo::SFloat.zeros(0)
    10.times { out = out.concatenate(m[0].sample(4800)) }
    expect(out).to eq(expected)

    # Mono weighs 1.0, 3 LU under the same sine on two channels
    expect(m.momentary).to be_within(0.1).of(-26)
    expect(m.short_term).to be_within(0.1).of(-26 + 10 * Math.log10(1 / 3.0))
    expect(m.integrated).to be_within(0.1).of(-26)
    expect(m.true_peak).to be_within(0.05).of(-23)
  end

  it 'measures every channel of a bundle together' do
    m = MB::Sound.stereo(tone, 1000.hz.sine.at(-23.db)).loudness_meter
    expect(m.channel_count).to eq(2)
    40.times { m.each { |o| o.sample(4800) } }
    expect(m.short_term).to be_within(0.1).of(-23)
    expect(m.lufs).to be_within(0.1).of(-23)
    # Short programmes have a wide range: the windows padded with silence
    # at the start and Tech 3342's 1.5 s of silence after the end count
    expect(m.range).to eq(m.result.range)
    expect(m.result.short_term_max).to be_within(0.1).of(-23)
    expect(m.to_s).to match(/\AM -23\.0  S -23\.0  I -23\.0 LUFS  LRA \d+\.\d LU  TP -23\.0 dBTP\z/)
    expect(m.readings.keys).to eq([:momentary, :short_term, :integrated, :range, :true_peak])
  end

  it 'starts over on reset' do
    m = tone.loudness_meter
    5.times { m[0].sample(4800) }
    expect(m.integrated).to be_finite
    m.reset
    expect(m.integrated).to eq(-Float::INFINITY)
    expect(m.momentary).to eq(-Float::INFINITY)
  end

  it 'chains like a bundle (lufs_meter alias)' do
    m = MB::Sound.stereo(tone, tone).lufs_meter
    chain = m.softclip
    expect(chain).to be_a(MB::Sound::GraphNode::Channels)
    expect(chain.channel_count).to eq(2)
    expect(m.graph).to include(tone)
  end

  it 'renders in a Session, measuring the input' do
    m = MB::Sound.stereo(tone, tone).loudness_meter
    path = tmp_path('meter.flac')
    MB::Sound.render(path, m, seconds: 4, gain: 1)
    expect(m.integrated).to be_within(0.1).of(-23)
    expect(MB::Sound.loudness(path).integrated).to be_within(0.1).of(-23)
  end

  it 'returns nil for ended channels and keeps measuring the others' do
    m = MB::Sound::GraphNode::LoudnessMeter.new([tone, 1000.hz.sine.at(-23.db).until(0.1)])
    expect(m[0].sample(4800)).not_to be_nil
    expect(m[1].sample(4800)).not_to be_nil
    expect(m[0].sample(4800)).not_to be_nil
    expect(m[1].sample(4800)).to be_nil
    expect(m.analyzer.samples).to eq(9600)
  end

  it 'restarts at a new sample rate' do
    m = MB::Sound.stereo(tone, tone).loudness_meter
    m.sample_rate = 44100
    expect(m.analyzer.sample_rate).to eq(44100)
    expect(tone.sample_rate).to eq(44100)
  end

  it 'refuses non-node inputs' do
    expect { MB::Sound::GraphNode::LoudnessMeter.new([1]) }.to raise_error(ArgumentError, /graph nodes/)
  end
end
