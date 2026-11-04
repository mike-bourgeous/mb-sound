# Region lanes (regions-1): GraphNode::RegionPlayer via `regions(...)`, the
# placement semantics of ACID's audio events (the .acd study's
# research/acd-format/acd/audio_render.rb, read only), checked against a
# small re-implementation of that renderer's placement on synthetic audio.
RSpec.describe(MB::Sound::GraphNode::RegionPlayer, :aggregate_failures) do
  include BufferSizeHelpers

  let(:m) { MB::Sound }
  let(:seq) { MB::Sound::Sequence }
  let(:sr) { 48_000 }
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  # 3 s of three detuned partials (every source sample distinct enough
  # that a misplaced read shows).
  def material(seconds: 3, hz: 220, name: 'tones')
    i = Numo::DFloat.new(sr * seconds).seq
    d = [1, 2.01, 3.03].each_with_index.map { |r, k| Numo::NMath.sin(i * 2 * Math::PI * hz * r / sr) * (0.4 / (k + 1)) }.reduce(:+)
    m::Sample.new(Numo::SFloat.cast(d), sample_rate: sr, name: name)
  end

  # audio_render.rb's curves (CURVES), plus :hold as MB::Sound::Curve
  # defines it.
  ACID = {
    linear: ->(x) { x }, fast: ->(x) { 1 - (1 - x)**2 }, slow: ->(x) { x * x },
    smooth: ->(x) { x * x * (3 - 2 * x) }, sharp: ->(x) { 0.5 + 4 * (x - 0.5)**3 }, hold: ->(x) { x >= 1 ? 1.0 : 0.0 },
  }.freeze

  # The placement of audio_render.rb (#render's event loop and #fades,
  # one-shot takes without stretch or pitch) at 120 BPM (a whole note is
  # 96 000 frames): start and length rounded to frames, the offset to
  # source samples, fade gains curve((k + 0.5) / n) in and 1 - curve(x)
  # out, reads past the source's end silent.
  def oracle(rows, total)
    mix = Numo::DFloat.zeros(total)
    rows.each do |smp, at, len, o|
      o ||= {}
      x = Numo::DFloat.cast(smp.data(0))
      start = (at * 96_000).round
      n = (len * 96_000).round
      off = ((o[:offset] || 0) * sr).round
      g = Numo::DFloat.ones(n) * m::Decibels.gain_of(o[:gain] || 1, 'gain', zero: true, above_one: true)
      nin = ((o[:fade_in] || 0) * 96_000).round
      nout = ((o[:fade_out] || 0) * 96_000).round
      nin.times { |k| g[k] *= ACID.fetch(o[:curve_in] || :linear).((k + 0.5) / nin) }
      nout.times { |k| g[n - nout + k] *= 1 - ACID.fetch(o[:curve_out] || :linear).((k + 0.5) / nout) }
      n.times do |k|
        idx = off + k
        mix[start + k] += x[idx] * g[k] if idx < x.length && start + k < total
      end
    end
    mix
  end

  # Crossfades in every shape (each region fades out over the next one's
  # fade-in), an offset region, and a quieter region over the others.
  def rows
    a = material
    b = material(hz: 330, name: 'other')
    list = ACID.keys.each_with_index.map { |c, i|
      [i.even? ? a : b, i * 1/4r, 3/8r, { offset: i * 0.1, fade_in: 1/8r, fade_out: 1/8r, curve_in: c, curve_out: c }]
    }
    list << [a, 1/16r, 1/2r, { offset: 1.25, gain: -6.db }]
    list << [b, 5/4r, 1r, { offset: 2.5, fade_out: 1/4r, curve_out: :sharp }] # (past the source's end: silent there)
    list
  end

  def session(buffer: 800)
    m::Session.new(
      master_gain: 1, output: m::NullOutput.new(channels: 2, sleep: false), transport: seq::Transport.new(bpm: 120),
      channels: 2, buffer_size: buffer, realtime: false, raise_errors: true
    ).tap { |s| sessions << s }
  end

  # The lane played from bar 1 in a Session for +frames+, buffers of
  # +size+, running +jump+ in the session before buffer +at+.
  def played(lane_rows, frames, size: 800, at: nil, jump: nil)
    s = session(buffer: size)
    m::Session.with_context(session: s) { m.bg(:lane, m.regions(*lane_rows), on: :now) }
    bufs = Array.new((frames + size - 1) / size) { |k|
      m::Session.with_context(session: s) { jump.call } if jump && k == at
      s.process_buffer(size)[0].dup
    }
    s.close
    SpecBuffers.join(bufs)[0...frames]
  end

  it 'places, offsets, gains, fades, and crossfades regions as ACID\'s renderer does, in every curve shape' do
    total = 96_000 * 9 / 4
    want = oracle(rows, total)
    got = played(rows, total)
    expect(want.abs.max).to be > 0.3
    expect((got - want).abs.max).to be < 1e-6
  end

  it 'gives the same samples at any buffer size, transposed and off the frame grid too' do
    smp = material
    list = rows + [[smp, 1/3r + 1/1000000r, 1/2r, { transpose: 3.5, fade_in: 1/16r, curve_in: :smooth }]]
    expect_invariant(-> { m.regions(*list) }, seconds: 4.6)
  end

  it 'starts a seek or a render(from:) inside a region on the sample an uninterrupted run plays' do
    total = 96_000 * 2
    plain = played(rows, total)
    [800, 367].each do |size|
      at = 30_000 / size + 1
      x = played(rows, total, size: size, at: at, jump: -> { m.seek(2, 2) })
      # (the seek lands at the start of buffer +at+, on bar 2 beat 2: 2.5 s
      # into a lane whose regions are crossfading there)
      from = 120_000
      n = MB::M.min(total - at * size, plain.length - from)
      expect(x[(at * size)...(at * size + n)]).to eq(plain[from...(from + n)]), "a seek at #{size}-frame buffers"
    end

    song = proc {
      MB::Sound.bpm 120
      list = rows
      MB::Sound::Session.current.arrangement.track(:lane, MB::Sound.regions(*list))
      MB::Sound::Session.current.arrangement.scene(:a, lane: :on)
      MB::Sound.flow(on: :now) { a 4 }
    }
    a = tmp_path('preroll.flac')
    MB::Sound.render(a, overwrite: true, gain: 0.5, from: 2, bars: 1, &song)
    MB::Sound.rewind
    b = tmp_path('seek.flac')
    MB::Sound.render(b, overwrite: true, gain: 0.5, from: 2, bars: 1, preroll: false, &song)
    MB::Sound.rewind
    x = MB::Sound.read(a)[0]
    y = MB::Sound.read(b)[0]
    expect(x.abs.max).to be > 0.1
    # (FLAC's 24 bits)
    expect((x - y).abs.max).to be < 1e-6
  end

  it 'plays stereo samples per channel and mono ones on every channel' do
    st = m::Sample.new([Numo::SFloat.new(4800).fill(0.5), Numo::SFloat.new(4800).fill(-0.25)], sample_rate: sr, name: 'stereo')
    mono = m::Sample.new(Numo::SFloat.new(4800).fill(0.1), sample_rate: sr, name: 'mono')
    lane = m.regions([st, 0r, nil], [mono, 1/16r, nil])
    expect(lane).to be_a(MB::Sound::GraphNode::Channels)
    l, r = lane.to_a.map { |p| p.sample(12_000).dup }
    expect([l[100], r[100]]).to eq([0.5, -0.25])
    expect(l[6100]).to be_within(1e-7).of(0.1)
    expect(r[6100]).to be_within(1e-7).of(0.1)
    expect(l[11_000]).to eq(0)
  end

  it 'places regions from the launch with align: :launch' do
    smp = m::Sample.new(Numo::SFloat.new(48_000).fill(0.5), sample_rate: sr, name: 'flat')
    s = session
    m::Session.with_context(session: s) {
      m.bg(:a, m.regions([smp, 1/8r, 1/8r]), on: :now)
      m.bg(:b, m.regions([smp, 1/8r, 1/8r], align: :launch) * 0.5, in: 1, on: :now)
    }
    x = SpecBuffers.join(Array.new(300) { s.process_buffer(800)[0].dup })
    # (:a plays 12 000 frames from 0.25 s; :b, launched at bar 2, from bar 2 + 0.25 s)
    expect(x[12_000...24_000].to_a.uniq).to eq([0.5])
    expect(x[24_000...108_000].to_a.uniq).to eq([0.0])
    expect(x[108_000...120_000].to_a.uniq).to eq([0.25])
  end

  it 'prints as regions(...) rows and loads from a graph document to the same samples' do
    brk = m.breakbeat(:jungle)
    lane = m.regions([brk, 0r, 1/2r, { offset: 0.5, fade_out: 1/8r, curve_out: :slow }], [brk.slices(4)[2], 1/4r, nil, { gain: -3.db, transpose: 2 }])
    expect(lane.to_ruby).to eq('regions([breakbeat(:jungle), 0r, 1/2r, { offset: 0.5, fade_out: 1/8r, curve_out: :slow }], [breakbeat(:jungle).slices(4)[2], 1/4r, nil, { gain: -3.db, transpose: 2 }])')
    loaded = m::GraphIO.load(m::GraphIO.dump(lane, name: :lane))
    a = SpecBuffers.join(Array.new(80) { lane.sample(800).dup })
    b = SpecBuffers.join(Array.new(80) { loaded.sample(800).dup })
    expect(a.abs.max).to be > 0.1
    expect(b).to eq(a)
  end

  it 'says what is wrong with a row' do
    smp = material(seconds: 1)
    expect { m.regions([smp, 0.5, 1r]) }.to raise_error(ArgumentError, /at is whole notes/)
    expect { m.regions([smp, 0r, 1r, { fade: 1/8r }]) }.to raise_error(ArgumentError, /Unknown region options :fade/)
    expect { m.regions([smp, -1/4r, 1r]) }.to raise_error(ArgumentError, /can't be negative/)
    expect { m.regions([smp, 0r, 0r]) }.to raise_error(ArgumentError, /above 0/)
    expect { m.regions([:x, 0r, 1r]) }.to raise_error(ArgumentError, /plays a Sample/)
    expect { m.regions([smp, 0r, 1r, { curve_in: :wobbly }]) }.to raise_error(ArgumentError, /Unknown curve/)
  end
end
