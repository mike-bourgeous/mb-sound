RSpec.describe(MB::Sound::Filter::Smoothstep) do
  it 'can be created' do
    f = 120.hz.square.smooth(60.samples)
    expect(f).to be_a(MB::Sound::Filter::SampleWrapper)
    expect(f.base_filter).to be_a(MB::Sound::Filter::Smoothstep)
  end

  it 'smooths samples' do
    f = MB::Sound::Filter::Smoothstep.new(sample_rate: 100, samples: 100)
    f.reset(1)
    d = f.process(Numo::SFloat.zeros(100))
    expect(d.max.round(3)).to eq(1)
    expect(d.min.round(3)).to eq(0)
    expect(d[0].round(3)).to eq(1)
    expect(d[-1].round(3)).to eq(0)
    expect(d[1]).to be < d[0]
    expect(d[-2]).to be > d[-1]
  end

  it "doesn't jump if a new value comes in before the end of a transition" do
    f = MB::Sound::Filter::Smoothstep.new(sample_rate: 100, samples: 5)
    d = f.process(Numo::SFloat[1, 1, 2, -1, -1, -1, -1, -1])

    p1 = Numo::SFloat.linspace(0, 1, 6)[1..2].map { |v| MB::M.smoothstep(v) }
    p2 = Numo::SFloat.linspace(0, 1, 6)[1..1].map { |v| MB::M.interp(p1[-1], 2, v, func: MB::M.method(:smoothstep)) }
    p3 = Numo::SFloat.linspace(0, 1, 6)[1..5].map { |v| MB::M.interp(p2[-1], -1, v, func: MB::M.method(:smoothstep)) }
    expected = p1.concatenate(p2).concatenate(p3)

    expect(MB::M.round(d, 4)).to eq(MB::M.round(expected, 4))
  end

  pending 'follows the expected smoothstep curve'

  def arr(data) = MB::Sound::ArrayInput.new(data: [data])
  def trig(count, *indices) = Numo::SFloat.zeros(count).tap { |t| indices.each { |i| t[i] = 1 } }

  describe 'GraphNode#smooth with reset:' do
    let(:data) { Numo::SFloat.zeros(400).tap { |d| d[0...100] = 1; d[100...200] = 2; d[200..] = 3 } }

    it 'jumps to the input on a reset and glides otherwise' do
      out = arr(data).smooth(50.samples, reset: arr(trig(400, 0, 200))).sample(400)

      expect(out[0]).to eq(1)
      expect(out[101]).to be > 1
      expect(out[101]).to be < 1.1
      expect(out[149]).to be_within(1e-6).of(2)
      expect(out[199]).to eq(2)
      expect(out[200]).to eq(3)
    end

    it 'stops a glide in progress' do
      out = arr(data).smooth(200.samples, reset: arr(trig(400, 150))).sample(400)
      expect(out[149]).to be < 2
      expect(out[150]).to eq(2)
      expect(out[200]).to be < 2.01
    end

    it 'matches plain #smooth without resets' do
      a = arr(data).smooth(30.samples, reset: arr(trig(400))).sample(400)
      b = arr(data).smooth(30.samples).sample(400)
      expect(a).to eq(b)
    end

    it 'rejects a non-node reset' do
      expect { arr(data).smooth(0.1, reset: 1) }.to raise_error(ArgumentError)
    end
  end
end
