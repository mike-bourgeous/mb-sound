# GraphNode#within (note-within-1): a node of frequencies moved into a note
# or frequency range by octaves, sample by sample (GraphNode::Within,
# kernel FastControl.octave_fold).
RSpec.describe(MB::Sound::GraphNode::Within, :aggregate_failures) do
  let(:s) { MB::Sound }

  # +node+'s output joined over +buffers+ reads of +size+ samples.
  def render(node, size, total)
    out = []
    n = 0
    while n < total
      count = [size, total - n].min
      out << node.sample(count).dup
      n += count
    end
    SpecBuffers.join(out)
  end

  it 'gives exactly the fold of each constant, as float32 signals carry it' do
    [0.3, 2.0, 3.7, 8.0, 8.5, 110.0, 440.0, 19_000.0, 1e-6].each do |f|
      out = f.constant.within(2.hz..8.hz).sample(64)
      expect(out.to_a.uniq).to eq([s::OctaveFold.fold_hz(Numo::SFloat[f][0], 2.0, 8.0, false)]), "#{f} Hz"
    end
    expect(110.constant.within(2.hz..8.hz).sample(4).to_a).to eq([6.875] * 4)
  end

  it 'keeps a note at either edge of a note range, at its frequency' do
    [s::E1, s::E2].each do |note|
      expect(note.number.constant.freq.within(s::E1..s::E2).sample(8).to_a.uniq).to eq(note.number.constant.freq.sample(8).to_a.uniq)
    end
    # every note lands on the frequency of its note fold
    fold = s::OctaveFold[s::E1..s::E2]
    (20..100).each do |n|
      expect(n.constant.freq.within(s::E1..s::E2).sample(4)[0]).to eq(fold.note(n).constant.freq.sample(4)[0]), "note #{n}"
    end
  end

  it 'gives the same samples at 800- and 367-frame buffers, and matches its Ruby mirror' do
    build = -> { 3.hz.lfo.at(30..90).freq.within(s::E2...s::E3) + 0.7.hz.lfo.at(50..900).within(2.hz..8.hz) }
    a = render(build.(), 800, 4800)
    b = render(build.(), 367, 4800)
    expect(a).to eq(b)
    c = MB::Sound::Kernels.with(:check) { render(build.(), 800, 4800) }
    expect(c).to eq(a)
  end

  it 'jumps exactly one octave on the sample where a glide crosses an edge' do
    ramp = (Numo::SFloat.linspace(6, 10, 401)).to_a
    node = MB::Sound::ArrayInput.new(data: [Numo::SFloat.cast(ramp)]).within(2.hz..8.hz)
    out = node.sample(401).to_a
    cross = ramp.index { |x| x > 8 }
    expect(out[0...cross]).to eq(ramp[0...cross])
    expect(out[cross..]).to eq(ramp[cross..].map { |x| x / 2 })
    ratios = out.each_cons(2).map { |p, q| q / p }
    expect(ratios.count { |r| r < 0.75 }).to eq(1)
  end

  it 'follows tuning changes for note ranges' do
    node = 80.constant.within(s::E1..s::E2) # E1..E2 is 41.2..82.4 Hz
    expect(node.sample(4)[0]).to eq(80.0)
    MB::Sound.tuning.set(note: 69, frequency: 400.0)
    # E1..E2 is now 37.5..75 Hz: 80 Hz moves down an octave
    expect(node.sample(4)[0]).to eq(40.0)
  ensure
    MB::Sound.tuning.reset
  end

  it 'is tagged as a frequency, prints back as Ruby, and refuses complex signals' do
    node = 110.hz.saw.at(0).within(2.hz..8.hz)
    expect(MB::Sound::ArgTypes.frequency?(node)).to eq(true)
    expect(110.constant.within(s::E1...s::E2).to_ruby).to eq('110.constant.within(E1...E2)')
    expect { (1.constant * 1i).within(2.hz..8.hz).sample(4) }.to raise_error(ArgumentError, /real signals/)
  end
end
