# Filters that can change their sample rate after construction (so whole
# graphs can be retuned; see Session#add and GraphNode#at_rate): a filter
# built at 44.1 kHz and set to 48 kHz must process exactly like one built
# at 48 kHz.
RSpec.describe('Filter#sample_rate=', :aggregate_failures) do
  let(:noise) { Numo::SFloat.new(2000).rand(-1, 1) }

  def expect_retuned_like_new(make)
    retuned = make.call(44100)
    retuned.sample_rate = 48000
    fresh = make.call(48000)

    expect(retuned.sample_rate).to eq(48000)
    retuned.reset(0) if retuned.respond_to?(:reset)
    fresh.reset(0) if fresh.respond_to?(:reset)
    expect(retuned.process(noise.dup)).to eq(fresh.process(noise.dup))
  end

  [:lowpass, :highpass, :lowpass1p, :highpass1p].each do |type|
    it "redesigns FirstOrder #{type}" do
      expect_retuned_like_new(->(rate) { MB::Sound::Filter::FirstOrder.new(type, rate, 1500) })
    end
  end

  it 'keeps FirstOrder below Nyquist' do
    f = MB::Sound::Filter::FirstOrder.new(:lowpass1p, 48000, 20000)
    f.sample_rate = 16000
    expect(f.center_frequency).to be < 8000
  end

  [[:lowpass, 4], [:highpass, 5]].each do |type, order|
    it "redesigns Butterworth #{type} order #{order}" do
      expect_retuned_like_new(->(rate) { MB::Sound::Filter::Butterworth.new(type, order, rate, 2000) })
    end
  end

  it 'redesigns HilbertIIR' do
    retuned = MB::Sound::Filter::HilbertIIR.new(sample_rate: 44100)
    retuned.sample_rate = 48000
    fresh = MB::Sound::Filter::HilbertIIR.new(sample_rate: 48000)
    retuned.reset(0)
    fresh.reset(0)
    expect(retuned.process(noise.dup)).to eq(fresh.process(noise.dup))
  end

  it 'redesigns FIR filters made from frequency gains' do
    gains = { 0 => 1, 1000 => 1, 2000 => 0, 22050 => 0 }
    expect_retuned_like_new(->(rate) { MB::Sound::Filter::FIR.new(gains.select { |f, _| f <= rate / 2 }, sample_rate: rate) })
  end

  it 'keeps per-bin FIR gains, which are relative to the rate already' do
    f = MB::Sound::Filter::FIR.new(Numo::DComplex[1, 1, 0.5, 0, 0], sample_rate: 44100)
    impulse = f.impulse.dup
    f.sample_rate = 48000
    expect(f.sample_rate).to eq(48000)
    expect(f.impulse).to eq(impulse)
  end

  it 'keeps Gain' do
    g = MB::Sound::Filter::Gain.new(0.5, sample_rate: 44100)
    g.sample_rate = 48000
    expect(g.sample_rate).to eq(48000)
    expect(g.process(noise)).to eq(noise * 0.5)
  end

  it 'keeps SimpleEnvelopeFollower decay times in seconds' do
    expect_retuned_like_new(->(rate) { MB::Sound::Filter::SimpleEnvelopeFollower.new(sample_rate: rate, decay_s: 0.01) })
  end

  it 'sets every filter in a FilterBank' do
    make = ->(rate) { MB::Sound::Filter::FilterBank.new(3) { |i| MB::Sound::Filter::Cookbook.new(:bandpass, rate, 500 * (i + 1), quality: 2) } }
    retuned = make.call(44100)
    retuned.sample_rate = 48000
    fresh = make.call(48000)
    expect(retuned.sample_rate).to eq(48000)
    expect(retuned.filters.map(&:sample_rate)).to eq([48000] * 3)

    # A bank processes one sample per filter per call
    300.times do |i|
      frame = noise[(i * 3)...(i * 3 + 3)]
      expect(retuned.process(frame.dup)).to eq(fresh.process(frame.dup))
    end
  end

  it 'retunes an Envelope' do
    make = ->(rate) {
      MB::Sound::Envelope.new(attack: 0.01, decay: 0.05, sustain: 0.5, release: 0.1, hold: 0.06, sample_rate: rate)
    }
    retuned = make.call(44100)
    retuned.sample_rate = 48000
    fresh = make.call(48000)
    expect(retuned.sample(9600)).to eq(fresh.sample(9600))
  end

  it 'keeps the Hilbert stage of a complex ChannelMixer at the new rate' do
    l = 440.hz.sine
    mixer = MB::Sound::GraphNode::ChannelMixer::Matrix.new([l], matrix: [[Complex(0, 1)]])
    mixer.outputs.first.sample(100)
    mixer.sample_rate = 44100
    expect(mixer.sample_rate).to eq(44100)
    expect { mixer.outputs.first.sample(100) }.not_to raise_error
  end
end
