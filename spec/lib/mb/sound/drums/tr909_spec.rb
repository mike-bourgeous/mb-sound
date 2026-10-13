RSpec.describe(MB::Sound::Drums::TR909, :aggregate_failures) do
  def collect(node, seconds = 1, buffer = 800)
    out = []
    total = 0
    while total < seconds * 48000 && (buf = node.sample(buffer))
      out << buf.dup
      total += buf.length
    end
    n = (seconds * 48000).round
    x = Numo::SFloat.zeros(n)
    d = Numo::SFloat.hstack(out)
    x[0...MB::M.min(n, d.length)] = d[0...MB::M.min(n, d.length)]
    x
  end

  let(:step) { (MB::Sound::Length.seconds(1.n16) * 48000).round }

  let(:everything) {
    MB::Sound.grid(16,
      kick: 'X...x...', snare: '....X...', clap: '....x..x', rim: '.x......', lt: '......x.', mt: '.......x', ht: '.....x..',
      hat: 'x.x.x.x.', oh: '..x...x.', crash: 'X.......', ride: '..x...x.'
    )
  }

  it 'has every voice, sounding' do
    outs = MB::Sound.tr909(everything, outputs: :separate, seed: 2)
    expect(outs.names).to eq([:kick, :rimshot, :snare, :clap, :low_tom, :mid_tom, :high_tom, :closed_hat, :open_hat, :crash, :ride])
    data = outs.names.to_h { |n| [n, []] }
    60.times { outs.names.each { |n| data[n] << outs[n].sample(800).dup } }
    data.each do |n, bufs|
      x = Numo::SFloat.hstack(bufs)
      expect(x.abs.max).to be_between(0.05, 1.2), "#{n} peaks at #{x.abs.max}"
    end
  end

  it 'plays the same at any buffer size' do
    ref = collect(MB::Sound.tr909(everything.loop, seed: 4, shuffle: 3), 1.5, 800)
    [64, 367].each do |bs|
      expect(collect(MB::Sound.tr909(everything.loop, seed: 4, shuffle: 3), 1.5, bs)).to eq(ref)
    end
  end

  it 'routes General MIDI notes' do
    clip = MB::Sound.seq(36, 38, 42, 46, 49, 51, 39, 37, 41, 47, 50).n16
    expect(MB::Sound.tr909(clip).names).to eq([:kick, :rimshot, :snare, :clap, :low_tom, :mid_tom, :high_tom, :closed_hat, :open_hat, :crash, :ride])
    expect(MB::Sound.tr909(MB::Sound.seq(36, 44).n16).names).to eq([:kick, :closed_hat])
  end

  it 'chokes the open hat with the closed hat' do
    k = MB::Sound.tr909(MB::Sound.grid(16, oh: 'x...', ch: '..x.'), open_hat: { decay: 0.9 })
    x = collect(k[:open_hat], 0.6)
    expect(x[(step + 1000)...(2 * step)].abs.max).to be > 0.01
    expect(x[(2 * step + 200)..].abs.max).to eq(0)
  end

  it 'tunes the kick in Hz and changes its decay' do
    low = collect(MB::Sound.tr909(MB::Sound.grid(4, kick: 'x'), kick: { tune: 40, punch: 0 }), 0.5)
    high = collect(MB::Sound.tr909(MB::Sound.grid(4, kick: 'x'), kick: { tune: 80, punch: 0 }), 0.5)
    crossings = ->(x) { s = x[2400...19200]; (s[1..].gt(0) & s[0...-1].le(0)).count_true }
    expect(crossings.(high)).to be_within(2).of(crossings.(low) * 2)
    long = collect(MB::Sound.tr909(MB::Sound.grid(4, kick: 'x'), kick: { decay: 1.5 }), 0.8)
    short = collect(MB::Sound.tr909(MB::Sound.grid(4, kick: 'x'), kick: { decay: 0.2 }), 0.8)
    expect(long[24000..].abs.max).to be > short[24000..].abs.max * 10
  end

  it 'makes 6-bit ROM samples at 32 kHz, the same each time' do
    MB::Sound::Drums::TR909::ROM.each_key do |name|
      s = MB::Sound::Drums::TR909.rom(name)
      expect(s).to be_a(MB::Sound::Sample)
      expect(MB::Sound::Drums::TR909.rom(name)).to equal(s)
      d = s.data
      expect((d * 32).round - d * 32).to eq(Numo::SFloat.zeros(d.length))
      expect(d.abs.max).to be_within(1 / 32.0).of(1)
      expect(s.seconds).to be_within(0.01).of(MB::Sound::Drums::TR909::ROM[name][:length])
    end
    again = MB::Sound::Drums::TR909.make_rom(:closed_hat, MB::Sound::Drums::TR909::ROM[:closed_hat])
    expect(again.data).to eq(MB::Sound::Drums::TR909.rom(:closed_hat).data)
    expect { MB::Sound::Drums::TR909.rom(:cowbell) }.to raise_error(ArgumentError, /ROM/)
  end

  it 'gives its kick to a bus reader with only: :kick, as tr808 does' do
    out = MB::Sound::NullOutput.new(channels: 1, sleep: false)
    session = MB::Sound::Session.new(master_gain: 1, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1, buffer_size: 800, realtime: false, raise_errors: true)
    MB::Sound.seed(1)
    session.add(MB::Sound.tr909(MB::Sound.grid(4, kick: 'x...', clap: '..x.').loop), name: :drums)
    spy = []
    session.add(session.bus_tap(:drums, only: :kick).spy { |d| spy << d.dup if d } * 0, name: :rd)
    60.times { session.process_buffer(800) }
    kick = spy.reduce(:concatenate)

    MB::Sound.seed(1)
    alone = MB::Sound.tr909(MB::Sound.grid(4, kick: 'x...', clap: '..x.').loop, outputs: :separate)[:kick]
    expected = Array.new(60) { alone.sample(800).dup }.reduce(:concatenate)
    expect(kick).to eq(expected)
    expect(kick.abs.max).to be > 0.1
  ensure
    session&.close
  end

  it 'prints itself and loads back from a graph document' do
    k = MB::Sound.tr909(MB::Sound.grid(16, kick: 'x...', hat: 'x.x.').loop, kick: { tune: 45 }, shuffle: 2, seed: 3)
    expect(k.to_ruby).to eq('tr909(grid(16, kick: "x...", hat: "x.x.").loop, kick: { tune: 45 }, shuffle: 2, seed: 3)')
    loaded = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(k, name: :t))
    expect(collect(loaded, 0.5)).to eq(collect(k, 0.5))
  end
end
