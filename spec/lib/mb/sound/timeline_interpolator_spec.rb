RSpec.describe(MB::Sound::TimelineInterpolator) do
  let(:ti) {
    MB::Sound::TimelineInterpolator.new([
      { time: 0.0, data: [ 0, 0, 0 ], blend: :linear },
      { time: 1.0, data: [ 1, -1, 0 ], blend: :smoothstep },
      { time: 3.5, data: [ -1, 1, -1 ], blend: :smootherstep },
      { time: 5.0, data: [ 0, 0, 1 ], blend: :catmull_rom, alpha: 0.5 },
      { time: 8.0, data: [ 1, 2, 3 ] },
    ])
  }

  tests = {
    -0.1 => [0, 0, 0],
    0 => [0, 0, 0],
    0.0 => [0, 0, 0],
    0.25 => [0.25, -0.25, 0],
    0.5 => [0.5, -0.5, 0],
    0.75 => [0.75, -0.75, 0],
    1 => [1, -1, 0],
    1.0 => [1, -1, 0],
    2 => [0.296, -0.296, -0.352],
    2.25 => [0, 0, -0.5],
    3 => [-0.792, 0.792, -0.896],
    3.5 => [-1, 1, -1],
    4.0 => [-0.7901234567901235, 0.7901234567901235, -0.580246913580247],
    4.25 => [-0.5, 0.5, 0],
    5.0 => [0, 0, 1],
    6.5 => [0.45745284272752385, 0.7993272315586744, 2.052165211874212],
    8.0 => [1, 2, 3],
    8.1 => [1, 2, 3],
  }

  tests.each do |t, v|
    it "produces expected data for a simple example at time #{t}" do
      expect(MB::M.round(ti.value(t), 9)).to eq(MB::M.round(v, 9))
    end
  end

  it 'can interpolate at an Array of times' do
    expect(ti.value([0, 1, 5])).to eq([[0, 0, 0], [1, -1, 0], [0, 0, 1]])
  end

  MB::Sound::TimelineInterpolator::INTERPOLATORS.each do |i|
    it "can interpolate numerics with #{i}" do
      t2 = MB::Sound::TimelineInterpolator.new(
        [
          { time: 0.5, data: 1 },
          { time: 1.5, data: 3 },
        ],
        default_blend: i
      )

      expect(t2.value(0)).to eq(1)
      expect(t2.value(2)).to eq(3)
      expect(t2.value(1.0)).to eq(2)
      expect(t2.value(0.75)).to be_between(1, 2).exclusive
      expect(t2.value(1.25)).to be_between(2, 3).exclusive
    end
  end
end
