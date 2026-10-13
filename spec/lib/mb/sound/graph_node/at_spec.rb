# GraphNode#at on any node (ArithmeticMethods): numbers and nodes multiply,
# Ranges map -1..1 onto them as Tone#at does for full-scale signals.
RSpec.describe(MB::Sound::GraphNode::ArithmeticMethods, '#at') do
  let(:src) { PlanSpecHelpers::Source }

  # A non-Tone node with known samples.
  def input(values)
    MB::Sound::ArrayInput.new(data: [Numo::DFloat.cast(values)])
  end

  let(:values) { [-1.0, -0.5, 0.0, 0.5, 1.0] }

  it 'multiplies by a number' do
    out = input(values).at(-6.db).sample(5)
    expect(out.to_a).to eq(values.map { |v| v * -6.db })
  end

  it 'multiplies by a graph node' do
    g = input(values).at(input([2, 2, 3, 3, 4]))
    expect(g).to be_a(MB::Sound::GraphNode::Multiplier)
    expect(g.sample(5).to_a).to eq([-2.0, -1.0, 0.0, 1.5, 4.0])
  end

  it 'maps -1..1 onto a Range' do
    expect(input(values).at(0..1).sample(5).to_a).to eq([0.0, 0.25, 0.5, 0.75, 1.0])
    expect(input(values).at(400..2000).sample(5).to_a).to eq([400.0, 800.0, 1200.0, 1600.0, 2000.0])
    expect(input(values).at(1..-1).sample(5).to_a).to eq([1.0, 0.5, 0.0, -0.5, -1.0])
  end

  it 'makes only a Multiplier for a Range centered on zero' do
    expect(input(values).at(-0.5..0.5)).to be_a(MB::Sound::GraphNode::Multiplier)
    expect(input(values).at(0..1)).to be_a(MB::Sound::GraphNode::Mixer)
  end

  it 'matches Tone#at for a full-scale signal' do
    tone = 110.hz.ramp.at(200..600)
    node = (110.hz.ramp * 1).at(200..600)
    expect(node).not_to be_a(MB::Sound::Tone)
    # Tones output float32, rounded after their own scale and offset
    expect((node.sample(800) - tone.sample(800)).abs.max).to be < 1e-4
  end

  it 'works on envelopes and filters (nodes without their own #at)' do
    env = MB::Sound.adsr(0, 0.01, 1, 0.1, hold: 1).at(0.5)
    expect(env.sample(4800).max).to be_within(1e-6).of(0.5)

    expect { 220.hz.ramp.lp4(800).at(-20.db) }.not_to raise_error
  end

  it 'keeps Tone#at for numbers and Ranges (inside the oscillator)' do
    expect(220.hz.ramp.at(0.5)).to be_a(MB::Sound::Tone)
    expect(220.hz.ramp.at(0..1)).to be_a(MB::Sound::Tone)
    expect(220.hz.at(0.5)).to be_a(MB::Sound::Tone)
  end

  it "makes a node a Tone's output gain (the same samples as tone * node)" do
    a = 220.hz.ramp.at(input(values))
    expect(a).to be_a(MB::Sound::Tone)
    expect(a.output_gain).to be_a(MB::Sound::GraphNode)
    ref = 220.hz.ramp.sample(5).dup
    expect(a.sample(5).to_a).to eq((ref * Numo::SFloat.cast(values)).to_a)
  end

  it 'merges with a Tone\'s numeric gain into one gain input' do
    a = 220.hz.ramp.gain(0.5).at(input(values))
    expect(a).to be_a(MB::Sound::Tone)
    ref = (220.hz.ramp * 0.5).sample(5).dup
    expect(a.sample(5).to_a).to eq((ref * Numo::SFloat.cast(values)).to_a)
  end

  context 'with bad values' do
    it 'raises for Ranges of Durations outside Tone' do
      expect { input(values).at(3.n16..5.n16) }.to raise_error(ArgumentError, /Only Tones take a Range of Durations/)
    end

    it 'raises for a Duration, endless Ranges, and other objects' do
      expect { input(values).at(1.n4) }.to raise_error(ArgumentError, /not a Duration/)
      expect { input(values).at(0..) }.to raise_error(ArgumentError, /two real numbers/)
      expect { input(values).at('loud') }.to raise_error(ArgumentError, /takes a number/)
    end

    it 'warns and returns the node unchanged in live mode' do
      allow(MB::Sound).to receive(:live?).and_return(true)
      node = input(values)
      expect { expect(node.at(3.n16..5.n16)).to equal(node) }.to output(/Range of Durations/).to_stderr
    end
  end

  context 'on Channels bundles' do
    it 'runs per channel' do
      b = MB::Sound.stereo(input(values), input(values)).at(MB::Sound.per_channel([0..1, 0.5]))
      expect(b).to be_a(MB::Sound::GraphNode::Channels)
      expect(b.channel_count).to eq(2)
      expect(b[0].sample(5).to_a).to eq([0.0, 0.25, 0.5, 0.75, 1.0])
      expect(b[1].sample(5).to_a).to eq(values.map { |v| v * 0.5 })
    end

    it 'takes one Range for all channels' do
      b = MB::Sound.stereo(input(values), input(values.reverse)).at(-2..2)
      expect(b[0].sample(5).to_a).to eq(values.map { |v| v * 2 })
      expect(b[1].sample(5).to_a).to eq(values.reverse.map { |v| v * 2 })
    end
  end

  context 'recipes and graph documents' do
    [
      ['220.hz.ramp.lp4(800).at(0.1)', -> { 220.hz.ramp.lp4(800).at(0.1) }],
      ['220.hz.ramp.lp4(800).at(0.25..0.75)', -> { 220.hz.ramp.lp4(800).at(0.25..0.75) }],
      ['220.hz.ramp.at(3.hz.lfo)', -> { 220.hz.ramp.at(3.hz.lfo) }],
      ['stereo(220.hz.ramp.lp4(800), 330.hz.ramp.lp4(900)).at(0..1)', -> { MB::Sound.stereo(220.hz.ramp.lp4(800), 330.hz.ramp.lp4(900)).at(0..1) }],
      ['adsr(0.01, 0.2, 0.5, 0.3).at(0.5)', -> { MB::Sound.adsr(0.01, 0.2, 0.5, 0.3).at(0.5) }],
    ].each do |(text, build)|
      it "prints #{text} back and loads it bit-identically" do
        g = build.call
        expect(g.to_ruby.strip).to eq(text)

        doc = MB::Sound::GraphIO.dump(build.call, name: 'at')
        loaded = MB::Sound::GraphIO.load(doc)
        3.times do
          g.outputs.zip(loaded.outputs).each do |(a, b)|
            expect(b.sample(800)).to eq(a.sample(800).dup)
          end
        end
      end
    end
  end

  context 'plans' do
    it 'fuses #at with a number, a Range, and a node into planned regions' do
      r = plan_compare(check: :raise) {
        sig = src.new(seed: 1).at(0.8)
        sig.at(-0.3..0.9).filter(:lowpass, cutoff: src.new(seed: 2).at(500..3000), quality: 1).at(src.new(seed: 3))
      }
      expect(plan_op_names(r)).to include(:FilterSvf)
      expect(r.regions.length).to eq(1)
    end

    it 'fuses #at on envelopes and four-pole filters' do
      plan_compare(check: :raise) {
        env = MB::Sound.adsr(0.001, 0.01, 0.5, 0.01, hold: 0.02).at(0.5..1)
        (src.new(seed: 4) * env).lp4(src.new(seed: 5).at(300..1200)).at(-6.db)
      }
    end
  end
end
