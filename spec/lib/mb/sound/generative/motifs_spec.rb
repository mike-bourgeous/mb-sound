RSpec.describe('MB::Sound#motifs (phrase memory)', :aggregate_failures) do
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:dorian) { MB::Sound.scale(:dorian, :d).weights }
  let(:chords) { dorian + MB::Sound.chord(:min7, root: :d).weights * 1.5 }
  let(:key) { MB::Sound.harmony(0 => MB::Sound.scale(:dorian, :d), 4.bars => MB::Sound.scale(:major, :f), loop: 8.bars) }

  # A Motifs object as MB::Sound#motifs builds it (to read motifs directly).
  def motifs_of(source, steps: 8, step: 1r / 8, form: %i[a a b a], answer: { b: :a }, mutate: 0.3, evolve: 2, seed: 3, range: MB::Sound::A3..MB::Sound::A5, around: MB::Sound::D4)
    field = MB::Sound::Generative.motif_field(source, range: range)
    MB::Sound::Generative::Motifs.new(field, steps: steps, step: step, form: form, answer: answer, density: 0.5, vary: 0.2, mutate: mutate,
      evolve: evolve, leap: 3, around: MB::Sound::Scale.root_number(around), velocity: 0.55..0.85, legato: 9r / 10, seed: seed)
  end

  def notes(clip, cycle)
    clip.events_for(cycle).map { |e| [e.start, e.value] }
  end

  it 'plays the form one phrase per cycle, with silent phrases' do
    c = MB::Sound.motifs(chords, 8, form: [:a, :a, :b, nil], vary: 0, mutate: 0, range: MB::Sound::A3..MB::Sound::A5, seed: 2)
    expect(c.length).to eq(1)
    expect(c.looping?).to eq(true)
    expect(c.to_s).to include('varying motifs(seed: 2)')
    expect(notes(c, 0)).to eq(notes(c, 1)) # no vary: a repeats exactly
    expect(notes(c, 0)).not_to eq(notes(c, 2))
    expect(c.events_for(3)).to eq([])
    expect(notes(c, 4)).to eq(notes(c, 0)) # no mutation: every pass the same
    expect(c.events_for(0).first.start).to eq(0)
    expect(c.values).to eq(MB::Sound::Generative.notes_of(MB::Sound::Generative.motif_field(chords, range: MB::Sound::A3..MB::Sound::A5)))
  end

  it 'answers a call with its rhythm, landing home and held, the call ending open' do
    c = MB::Sound.motifs(chords, 8, form: %i[a b], vary: 0, mutate: 0, range: MB::Sound::A3..MB::Sound::A5, seed: 4)
    f = chords.over(MB::Sound::A3..MB::Sound::A5)
    20.times do |pass|
      call = c.events_for(pass * 2)
      ans = c.events_for(pass * 2 + 1)
      expect(ans.map(&:start)).to eq(call.map(&:start))
      expect(f.home(ans.last.value)).to eq(ans.last.value)
      expect(ans.last.length).to eq((1 - ans.last.start) * 9r / 10)
      expect(f.home(call.last.value)).not_to eq(call.last.value) if call.length > 1
      expect(f.home(call.first.value)).to eq(call.first.value)
    end

    # different seeds give different motifs
    d = MB::Sound.motifs(chords, 8, form: %i[a b], seed: 5)
    expect((0..8).map { |i| notes(d, i) }).not_to eq((0..8).map { |i| notes(c, i) })
  end

  it 'mutates every evolve passes, within one change per step of the first motif' do
    m = motifs_of(chords, steps: 16, mutate: 0.4, evolve: 2)
    base = m.base(:a)
    changed = 0
    (1..200).each do |g|
      x = m.motif(:a, g)
      expect(x.on[0]).to eq(true)
      16.times do |s|
        if x.on[s] && base.on[s]
          expect((x.contour[s] - base.contour[s]).abs).to be <= 1
        elsif x.on[s]
          expect(x.contour[s]).to be_a(Integer)
        end
      end
      changed += 1 if x != m.motif(:a, g - 1)
    end
    expect(changed).to be > 150

    c = MB::Sound.motifs(chords, 16, step: 1.n16, vary: 0, mutate: 0.4, evolve: 2, seed: 3)
    # a's statements: cycles 0, 1, 3 (pass 0), 4, 5, 7 (pass 1) share generation 0
    expect(notes(c, 4)).to eq(notes(c, 0))
    expect(notes(c, 7)).to eq(notes(c, 3))
    expect((8..40).step(8).map { |i| notes(c, i) }.uniq.length).to be > 2
  end

  it 'computes any cycle cold, the same as in order, at a bounded cost' do
    mk = -> { MB::Sound.motifs(key.blur(0.2) + chords, 16, step: 1.n16, mutate: 0.3, evolve: 1, seed: 5) }
    a = mk.()
    seq = (0...120).map { |i| a.events_for(i) }
    b = mk.()
    order = (0...120).to_a.shuffle(random: Random.new(1))
    cold = order.to_h { |i| [i, b.events_for(i)] }
    expect(seq.each_with_index.all? { |e, i| e == cold[i] }).to eq(true)

    far = mk.()
    t0 = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
    e = far.events_for(1_000_000)
    expect(Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID) - t0).to be < 0.05
    expect(e).to eq(mk.().events_for(1_000_000))
    expect(e).not_to be_empty
  end

  it 'stays in its range, around the given note, on the scale where each note starts' do
    low = MB::Sound.motifs(key, 8, range: MB::Sound::A3..MB::Sound::A5, around: MB::Sound::C4, seed: 1)
    high = MB::Sound.motifs(key, 8, range: MB::Sound::A3..MB::Sound::A5, around: MB::Sound::G5, seed: 1)
    lows = (0...32).flat_map { |i| low.events_for(i).map(&:value) }
    highs = (0...32).flat_map { |i| high.events_for(i).map(&:value) }
    expect((lows + highs).minmax.then { |lo, hi| lo >= MB::Sound::A3.number && hi <= MB::Sound::A5.number }).to eq(true)
    expect(highs.sum / highs.length.to_f).to be > lows.sum / lows.length.to_f + 7

    # unblurred: every note is in the key where it starts (D dorian, then F major)
    (0...32).each do |i|
      low.events_for(i).each do |e|
        expect(key.at(i + e.start)[e.value]).to be > 0
      end
    end
  end

  it 'lets blurred wrong notes pass in the middle of phrases only' do
    plain = MB::Sound.motifs(dorian, 8, seed: 6)
    blurred = MB::Sound.motifs(dorian.blur(0.5), 8, seed: 6)
    plain_notes = (0...64).flat_map { |i| plain.events_for(i).map(&:value) }
    expect(plain_notes.all? { |n| dorian[n] > 0 }).to eq(true)
    wrong = 0
    (0...64).each do |i|
      ev = blurred.events_for(i)
      [ev.first, ev.last].each { |e| expect(dorian[e.value]).to be > 0 }
      wrong += ev.count { |e| dorian[e.value] == 0 }
    end
    expect(wrong).to be > 0
  end

  it 'checks its arguments' do
    expect { MB::Sound.motifs(dorian, 0) }.to raise_error(ArgumentError, /steps/)
    expect { MB::Sound.motifs(dorian, form: 'aaba') }.to raise_error(ArgumentError, /form/)
    expect { MB::Sound.motifs(dorian, form: [nil]) }.to raise_error(ArgumentError, /form/)
    expect { MB::Sound.motifs(dorian, form: %i[a b c], answer: { b: :a, c: :b }) }.to raise_error(ArgumentError, /answer to an answer/)
    expect { MB::Sound.motifs(dorian, form: %i[a b], answer: { b: :b }) }.to raise_error(ArgumentError, /itself/)
    expect { MB::Sound.motifs(dorian, mutate: 2) }.to raise_error(ArgumentError, /mutate/)
    expect { MB::Sound.motifs(dorian, evolve: 0) }.to raise_error(ArgumentError, /evolve/)
    expect { MB::Sound.motifs(dorian.over(48..60), range: 40..50) }.to raise_error(ArgumentError, /own range/)
    expect(MB::Sound.motifs(dorian, step: 16, seed: 1).length).to eq(1r / 2) # 8 sixteenths
    expect(MB::Sound.motifs(dorian, form: %i[a a], seed: 1).events_for(1)).not_to be_empty # answer: { b: :a } without b is fine
  end

  describe 'takes' do
    let(:session) { MB::Sound::Session.new(master_gain: 0.5, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: transport, channels: 2, buffer_size: 800, realtime: false, raise_errors: true) }

    after { session.close }

    it 'replay motifs bit for bit at any buffer size, through seeks and drawn seeds' do
      lines = {
        0 => [
          'h = harmony(0 => scale(:dorian, :d), 2.bars => scale(:major, :f), loop: 4.bars).blur(0.1)',
          'lead = motifs(h, 8, form: %i[a a b a], range: A3..A5, mutate: 0.4, evolve: 1)',
          "track(:lead, q: 1) { |c| c.number * 0.01 + c.velocity * 0.1 }",
          'scene :a, lead: lead',
          'scene :b, lead: lead.transpose(-12)',
          'go :a, at: :now',
        ],
        170 => ['go :b'],
        300 => ['seek 9'],
        420 => ['go :a'],
      }
      bnd = MB::Sound::Take.console_binding
      MB::Sound.seed(5)
      t = MB::Sound::Take.new(session: session)
      live = Array.new(480) { |i|
        lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: session) { t.line(code, bnd) } }
        session.process_buffer[0].dup
      }.reduce(:concatenate)
      expect(live.abs.max).to be > 0.3

      path = tmp_path('take.rb')
      expect { t.save(path) }.to output(/Saved/).to_stdout
      load path
      r = MB::Sound::Take::Replay.last
      [[800], [367, 368]].each do |sizes|
        MB::Sound.seed(5)
        out = []
        r.render(MB::Sound::NullOutput.new(channels: 2, sleep: false), buffer_sizes: sizes, tail: 0) { |mix| out << mix[0].dup }
        data = out.reduce(:concatenate)
        expect(data.length).to be >= live.length
        expect(data[0...live.length]).to eq(live), "buffer sizes #{sizes}"
      end
    end
  end

  describe 'recipes and graph documents' do
    it 'prints motifs back and loads them' do
      MB::Sound.rewind
      m = MB::Sound.motifs(key.blur(0.1) + MB::Sound.chord(:min7, root: :d).weights, 8, step: 1.n8, form: [:a, :a, :b, nil], answer: { b: :a },
        range: MB::Sound::A3..MB::Sound::A5, around: MB::Sound::D4, mutate: 0.3, seed: 4).synth(voices: 2) { |v| v.hz.sine * v.env(0.005, 0.3, 0, 0.1) }
      text = m.to_ruby
      expect(text).to start_with('motifs(harmony(0 => scale(:dorian, D4), 4.bars => scale(:major, F4), loop: 8.bars).blur(0.1) + chord(:min7, root: :d).weights, 8, step: 1.n8, form: [:a, :a, :b, nil], answer: { b: :a }, range: A3..A5, around: D4, mutate: 0.3, seed: 4).synth(voices: 2)')
      loaded = MB::Sound::GraphIO.load(text)
      expect(loaded.to_ruby).to eq(text)
      60.times { expect(loaded.sample(800)).to eq(m.sample(800)) }
    end

    it 'limits what documents may generate' do
      expect { MB::Sound::GraphIO.load('motifs(scale(:minor, A4).weights, 100000)') }.to raise_error(MB::Sound::GraphIO::LoadError, /steps/)
      expect { MB::Sound::GraphIO.load('motifs(scale(:minor, A4).weights, 1000)') }.to raise_error(MB::Sound::GraphIO::LoadError, /256/)
    end
  end
end
