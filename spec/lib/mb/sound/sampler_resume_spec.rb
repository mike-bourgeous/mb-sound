# One-shot samples across content jumps (regions-1, "forward-seek
# one-shots"): a sampler voice whose note sounded before a seek (or a
# render(from:, preroll: false), a backward seek) starts that note's sample
# where an uninterrupted run would be (Notes#resume, MIDI::Source::Chase#resume),
# instead of staying silent while the old content's sample rings on.
RSpec.describe('sampler voices resuming one-shots at content jumps', :aggregate_failures) do
  let(:m) { MB::Sound }
  let(:seq) { MB::Sound::Sequence }
  let(:sr) { 48_000 }
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  def session(buffer: 800)
    m::Session.new(
      master_gain: 1, output: m::NullOutput.new(channels: 2, sleep: false), transport: seq::Transport.new(bpm: 120),
      channels: 2, buffer_size: buffer, realtime: false, raise_errors: true
    ).tap { |s| sessions << s }
  end

  # A 4 s one-shot whose every sample says where it is in the source: a ramp
  # plus a quiet sine (so a misplaced read shows in the sine too), faded
  # out over its last 10 ms (an uninterrupted voice drifts by a few
  # thousandths of a sample over seconds, its speed read through a float32
  # frequency, which an abrupt end would show as 1e-3 differences).
  def marked(seconds: 4, **opts)
    n = sr * seconds
    i = Numo::DFloat.new(n).seq
    fade = ((n - i) / 480.0).clip(0, 1)
    data = Numo::SFloat.cast((i / n * 0.5 + Numo::NMath.sin(i * 2 * Math::PI * 330 / sr) * 0.1) * fade)
    m::Sample.new(data, sample_rate: sr, root: 60, name: 'marked', **opts)
  end

  def clip(events, length: 4r)
    seq::Clip.new(events.map { |start, key| seq::Event.new(start: start, length: 1/16r, value: key, velocity: 1.0) }, length: length, loop: true)
  end

  # Mono samples of the session from bar 1 for +buffers+ buffers of
  # +size+, running +jump+ in the session before buffer +at+.
  def run(patch, c, buffers:, size: 800, at: nil, jump: nil)
    s = session(buffer: size)
    m::Session.with_context(session: s) {
      m.track(:t, &patch)
      m.scene(:a, t: c)
      m.go(:a, at: :now)
    }
    bufs = Array.new(buffers) { |k|
      m::Session.with_context(session: s) { jump.call } if jump && k == at
      s.process_buffer(size)[0].dup
    }
    s.close
    SpecBuffers.join(bufs)
  end

  # Expects +x+ from frame +from+ (plus the 64-sample declick of the old
  # note) to be +ref+ from frame +ref_from+, for +n+ frames.
  def expect_resumed(x, from, ref, ref_from, n, what)
    d = MB::Sound::Sampler::DECLICK
    got = x[(from + d)...(from + n)]
    want = ref[(ref_from + d)...(ref_from + n)]
    expect((got - want).abs.max).to be < 1e-4, "#{what}: plays the uninterrupted run (max error #{(got - want).abs.max})"
  end

  it 'starts the note sounding at a forward seek where the uninterrupted run is, at any buffer size' do
    smp = marked
    patch = proc { |c| c.sampler(smp) }
    c = clip([[0r, 60]])
    plain = run(patch, c, buffers: 260)
    [800, 367].each do |size|
      at = 24_000 / size + 1
      x = run(patch, c, buffers: 260 * 800 / size, size: size, at: at, jump: -> { m.seek(2, 1) })
      # (lands at the start of buffer +at+, on bar 2 = 2 s)
      expect_resumed(x, at * size, plain, sr * 2, sr, "seek at #{size}-frame buffers")
    end
  end

  it 'resumes at a backward seek and plays nothing old with resume: false' do
    smp = marked
    c = clip([[0r, 60]])
    plain = run(proc { |cl| cl.sampler(smp) }, c, buffers: 220)
    # (from 3 s back to bar 1 beat 2: 0.5 s into the note)
    x = run(proc { |cl| cl.sampler(smp) }, c, buffers: 220, at: 180, jump: -> { m.seek(1, 2) })
    expect_resumed(x, 180 * 800, plain, sr / 2, sr / 2, 'backward seek')

    old = run(proc { |cl| cl.sampler(smp, resume: false) }, c, buffers: 120, at: 30, jump: -> { m.seek(2, 1) })
    # (the old note rings on from where it was: the jump changes nothing)
    expect(old[24_000...72_000]).to eq(plain[24_000...72_000])
  end

  it 'resumes the newest note on its own lane of a polyphonic synth, leaving later notes their lanes' do
    smp = marked
    hit = m::Sample.new(Numo::SFloat.new(2400).fill(0.25), sample_rate: sr, root: 62, name: 'hit')
    inst = m::Sampler::Instrument.new(name: 'two') { |i|
      i.region(smp, keys: 60, keytrack: 0)
      i.region(hit, keys: 62, keytrack: 0)
    }
    patch = proc { |cl| cl.sampler(inst, voices: 3) }
    # (the long note, then hits on beats 3 and 4 of bar 2 ring over it; the
    # resumed note takes the lane that last played its key, cutting the old
    # content's sample there)
    c = clip([[0r, 60], [5/4r + 1/4r, 62], [7/4r, 62]])
    plain = run(patch, c, buffers: 260)
    x = run(patch, c, buffers: 260, at: 30, jump: -> { m.seek(2, 2) })
    # (seek lands on bar 2 beat 2 = 2.5 s; the hits come 0.5 s and 1 s later)
    expect_resumed(x, 24_000, plain, sr * 5 / 2, sr * 3 / 2, 'polyphonic seek')
  end

  it 'renders from: mid-note the same with and without a pre-roll (a form seeking mid-section)' do
    smp = marked
    song = proc {
      MB::Sound.bpm 120
      set = MB::Sound::Session.current.arrangement
      set.track(:t) { |cl| cl.sampler(smp) }
      set.scene(:a, t: clip([[0r, 60]]))
      MB::Sound.flow(on: :now) { a 4 }
    }
    a = tmp_path('preroll.flac')
    MB::Sound.render(a, overwrite: true, gain: 1, from: 2, bars: 1, &song)
    MB::Sound.rewind
    b = tmp_path('seek.flac')
    MB::Sound.render(b, overwrite: true, gain: 1, from: 2, bars: 1, preroll: false, &song)
    MB::Sound.rewind
    x = MB::Sound.read(a)[0]
    y = MB::Sound.read(b)[0]
    expect(x.abs.max).to be > 0.3
    expect_resumed(y, 0, x, 0, sr * 2, 'render(from:, preroll: false)')
  end

  it 'wraps a forward loop and resumes slices of a chop' do
    smp = marked(loop: (sr / 2)...(sr * 3 / 2))
    c = clip([[0r, 60]], length: 8r)
    patch = proc { |cl| cl.sampler(smp, resume: true) }
    plain = run(patch, c, buffers: 420)
    # (5 s into the note: inside the loop's fourth pass)
    x = run(patch, c, buffers: 420, at: 30, jump: -> { m.seek(3, 3) })
    expect_resumed(x, 24_000, plain, sr * 5, sr / 2, 'looped sample')

    brk = marked.slices(4)
    chop = brk.chop(0, 1, 2, 3, per: 1/4r).loop
    plain = run(proc { |cl| cl.sampler(brk) }, chop, buffers: 120)
    # (the chop's hits are quarter notes: bar 1 beat 3 lands 0.25 s into
    # the third slice)
    x = run(proc { |cl| cl.sampler(brk) }, chop, buffers: 120, at: 3, jump: -> { m.seek(1, 3.5) })
    expect_resumed(x, 2400, plain, sr * 5 / 4, sr / 4, 'chop slice')
  end
end
