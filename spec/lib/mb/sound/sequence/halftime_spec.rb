# Clip#halftime / #doubletime (and Seq's, Kit's): panel Kez #16.
RSpec.describe(MB::Sound::Sequence::Clip, '#halftime and #doubletime') do
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) } # a whole note is 96000 samples
  let(:riff) { MB::Sound.seq(MB::Sound::C3, MB::Sound::E3, MB::Sound::G3.n4).n8 }

  def starts(clip) = clip.events.map(&:start)
  def lengths(clip) = clip.events.map(&:length)

  it 'doubles (halftime) or halves (doubletime) every time, length, and the clip length, exactly' do
    h = riff.halftime
    expect(starts(h)).to eq(starts(riff).map { |s| s * 2 })
    expect(lengths(h)).to eq(lengths(riff).map { |l| l * 2 })
    expect(h.length).to eq(riff.length * 2)
    expect(starts(h)).to all(be_a(Rational))

    d = riff.doubletime
    expect(starts(d)).to eq(starts(riff).map { |s| s / 2 })
    expect(d.length).to eq(riff.length / 2)
    expect(riff.halftime.doubletime.events).to eq(riff.events)
  end

  it 'takes other factors, and aliases' do
    expect(riff.halftime(3/2r).length).to eq(riff.length * 3 / 2)
    expect(riff.doubletime(4).length).to eq(riff.length / 4)
    expect(riff.half_time.events).to eq(riff.halftime.events)
    expect(riff.double_time.events).to eq(riff.doubletime.events)
    expect { riff.halftime(0) }.to raise_error(ArgumentError, /factor must be positive/)
    expect { riff.doubletime(-1) }.to raise_error(ArgumentError, /factor must be positive/)
  end

  it 'keeps loops looping, with the loop as long as the stretched clip, on exact samples across loop edges' do
    h = riff.loop.halftime
    expect(h).to be_looping
    expect(h.align).to eq(riff.loop.align)

    [800, 367].each do |size|
      trig = h.trigger(transport: transport)
      data = Array.new((4 * 96000) / size + 1) { trig.sample(size).dup }.reduce(:concatenate)[0...(4 * 96000)]
      hits = data.to_a.each_with_index.reject { |v, _| v == 0 }.map(&:last)
      # The riff is half a bar (eighth, eighth, quarter): in half time a bar
      # of quarter, quarter, half, looping every bar
      expect(hits).to eq((0...4).flat_map { |bar| [0, 24000, 48000].map { |o| bar * 96000 + o } }), "#{size}-sample buffers"
    end
  end

  it 'works on Seqs (kept as Seqs) and grid Kits (each row)' do
    expect(riff.halftime).to be_a(MB::Sound::Sequence::Seq)
    kit = MB::Sound.grid(16, kick: 'x...x...', hat: 'x.x.x.x.').loop
    h = kit.halftime
    expect(h).to be_a(MB::Sound::Sequence::Kit)
    expect(h[:kick].length).to eq(kit[:kick].length * 2)
    expect(starts(h[:hat])).to eq(starts(kit[:hat]).map { |s| s * 2 })
    expect(h[:hat]).to be_looping
    expect(kit.doubletime[:kick].length).to eq(kit[:kick].length / 2)
  end

  it 'prints itself back' do
    expect(riff.loop.halftime.to_ruby).to eq('seq(C3, E3, G3.n4).n8.loop.halftime')
  end
end
