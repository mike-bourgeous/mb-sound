RSpec.describe(MB::Sound::GraphNode::Sounding) do
  # 0.1 s of a 0.5 amplitude square, 0.3 s of silence, 0.1 s more, then the end
  let(:data) {
    x = Numo::SFloat.zeros(24000)
    x[0...4800] = 0.5
    x[19200...24000] = 0.5
    x
  }

  def gate(data, buffer, **opts)
    g = MB::Sound::ArrayInput.new(data: [data]).sounding(**opts)
    out = []
    while (b = g.sample(buffer))
      out << b.dup
    end
    Numo::SFloat.zeros(0).concatenate(*out)
  end

  it 'is open while its source sounds, holds, fades out, reopens, and ends after its source once faded' do
    g = gate(data, 800, hold: 0.1, fade: 0.05)
    expect(g[0...4800].to_a.uniq).to eq([1])
    expect(g[4799 + 4800]).to eq(1)                 # held 4800 samples after the last loud one
    expect(g[4799 + 4800 + 1200]).to be_within(1e-6).of(0.5) # half way through the fade
    expect(g[(4799 + 4800 + 2400)...19200].to_a.uniq).to eq([0])
    expect(g[19200]).to eq(1)
    # The source ends at 24000, loud; the gate holds and fades past it
    expect(g.length).to eq(23999 + 4800 + 2400 + 1)
    expect(g[-1]).to eq(0)
  end

  it 'gives the same samples and length at any buffer size' do
    ref = gate(data, 800, hold: 0.05, fade: 0.02)
    [1, 7, 128, 1000, 30000].each do |bs|
      expect(gate(data, bs, hold: 0.05, fade: 0.02)).to eq(ref)
    end
  end

  it 'starts closed, takes Lengths, and ends at once if closed when its source ends' do
    x = Numo::SFloat.zeros(9600)
    x[100] = 1
    g = gate(x, 800, hold: 10.ms, fade: 0.ms)
    expect(g[0...100].to_a.uniq).to eq([0])
    expect(g[100..580].to_a.uniq).to eq([1])
    expect(g[581]).to eq(0)
    expect(g.length).to eq(9600)
  end

  it 'refuses negative or musical lengths' do
    src = 0.constant
    expect { src.sounding(hold: -1) }.to raise_error(ArgumentError, /hold/)
    expect { src.sounding(fade: 1.beat) }.to raise_error(ArgumentError, /fade/)
  end
end
