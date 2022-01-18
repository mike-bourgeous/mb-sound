RSpec.describe(MB::Sound::Filter::Smoothstep) do
  it 'can be created' do
    f = 120.hz.square.smooth(samples: 60)
    expect(f).to be_a(MB::Sound::Filter::SampleWrapper)
    expect(f.filter).to be_a(MB::Sound::Filter::Smoothstep)
  end

  it 'smooths samples' do
    f = MB::Sound::Filter::Smoothstep.new(rate: 100, samples: 100)
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
    f = MB::Sound::Filter::Smoothstep.new(rate: 100, samples: 5)
    d = f.process(Numo::SFloat[1, 1, 2, -1, -1, -1, -1, -1])

    p1 = Numo::SFloat.linspace(0, 1, 6)[1..2].map { |v| MB::M.smoothstep(v) }
    p2 = Numo::SFloat.linspace(0, 1, 6)[1..1].map { |v| MB::M.interp(p1[-1], 2, v, func: MB::M.method(:smoothstep)) }
    p3 = Numo::SFloat.linspace(0, 1, 6)[1..5].map { |v| MB::M.interp(p2[-1], -1, v, func: MB::M.method(:smoothstep)) }
    expected = p1.concatenate(p2).concatenate(p3)

    expect(MB::M.round(d, 4)).to eq(MB::M.round(expected, 4))
  end

  pending 'follows the expected smoothstep curve'
end
