RSpec.describe('MB::Sound generator steering: when values are read (beats-timing-1)', :aggregate_failures) do
  # The maintainer, 2026-11-22: "Default to 1 beat, but allow changing the
  # granularity, and solve whatever issue required the 1-beat-early read".
  # Steered values are read for the start of the unit they govern (a beat
  # for beats by default), so a square LFO on the energy plays the bars or
  # beats it says, with no phase offset.

  def new_session(bpm: 124, buffer_size: 800)
    MB::Sound::Session.new(
      output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: bpm),
      channels: 1, buffer_size: buffer_size, realtime: false, raise_errors: true, master_gain: 1
    )
  end

  # Renders +frames+ frames at +sizes+ (cycled) in a new Session after
  # running +setup+ in it (with MB::Sound's methods; it returns the node
  # to play), and +lines+ (buffer index => code) between buffers.
  def render(frames, bpm: 124, sizes: [800], lines: {}, &setup)
    s = new_session(bpm: bpm, buffer_size: sizes.max)
    MB::Sound::Session.with_context(session: s) { MB::Sound.bg(:d, setup.call, on: :now) }
    out = []
    n = 0
    i = 0
    while n < frames
      lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: s) { MB::Sound.instance_eval(code) } }
      out << s.process_buffer(sizes[i % sizes.length])[0].dup
      n += out.last.length
      i += 1
    end
    SpecBuffers.join(out)[0...frames]
  ensure
    s&.close
  end

  # A beat whose hats play every step at energy 1 and none at energy 0.
  def hats(energy, **opts)
    MB::Sound.beats(16, energy: energy, humanize: 0, seed: 1, **opts) { hat [1] * 16 }
  end

  # The steps (sixteenths at +bpm+) of +bars+ bars holding a note-on
  # (a trigger sample) in +audio+, as 0/1 per step.
  def steps_of(audio, bars, bpm: 124)
    step = 48000 * 60.0 / bpm / 4
    on = Array.new(bars * 16, 0)
    (audio.gt 0.5).where.to_a.each { |f| s = (f / step).round; on[s] = 1 if s < on.length } # (a step's note lands on its first frame)
    on
  end

  describe 'a square LFO on the energy, for every period and granularity' do
    # Expected: busy where the LFO's first half covers the start of the
    # step's unit (the LFO counted from the timeline's 0, no phase offset)
    def expected(period, unit, bars)
      Array.new(bars * 16) { |s|
        start = (Rational(s, 16) / unit).floor * unit
        ((start / period) % 1) < 1r / 2 ? 1 : 0
      }
    end

    {
      [4r, :beat] => '1111 1111 1111 1111 1111 1111 1111 1111 0000 0000 0000 0000 0000 0000 0000 0000',
      [2r, :beat] => '1111 1111 1111 1111 0000 0000 0000 0000 1111 1111 1111 1111 0000 0000 0000 0000',
      [1r, :beat] => '1111 1111 0000 0000 1111 1111 0000 0000 1111 1111 0000 0000 1111 1111 0000 0000',
      [1r / 2, :beat] => '1111 0000 1111 0000 1111 0000 1111 0000 1111 0000 1111 0000 1111 0000 1111 0000',
      [1r / 4, :beat] => '1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111',
      [1r / 4, :step] => '1100 1100 1100 1100 1100 1100 1100 1100 1100 1100 1100 1100 1100 1100 1100 1100',
      [1r / 2, :step] => '1111 0000 1111 0000 1111 0000 1111 0000 1111 0000 1111 0000 1111 0000 1111 0000',
      [2r, :bar] => '1111 1111 1111 1111 0000 0000 0000 0000 1111 1111 1111 1111 0000 0000 0000 0000',
      [1r, :bar] => '1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111',
    }.each do |(period, decide), want|
      it "plays #{MB::Sound::Sequence::Duration.format(period)} squares read per #{decide} on the LFO's own steps" do
        bars = 4
        unit = { beat: 1r / 4, step: 1r / 16, bar: 1r }.fetch(decide)
        opts = decide == :beat ? {} : { decide: decide }
        audio = render((bars * 48000 * 240.0 / 124).ceil) {
          MB::Sound.knob :e, 0.5, range: 0.0..1.0
          MB::Sound.turn :e, MB::Sound::Sequence::Duration.new(period).lfo.square.at(0.0..1.0)
          hats(MB::Sound.knob(:e), **opts).trigger
        }
        got = steps_of(audio, bars)
        expect(got).to eq(expected(period, unit, bars))
        expect(got.each_slice(4).map(&:join).join(' ')).to eq(want)
      end
    end

    it 'reads a tempo LFO given as the energy itself the same way' do
      bars = 4
      audio = render((bars * 48000 * 240.0 / 124).ceil) { hats(2.bars.lfo.square.at(0.0..1.0)).trigger }
      expect(steps_of(audio, bars)).to eq(expected(2r, 1r / 4, bars))
    end

    it 'plays the same at any buffer size' do
      setup = -> {
        MB::Sound.knob :e, 0.5, range: 0.0..1.0
        MB::Sound.turn :e, 2.beats.lfo.square.at(0.0..1.0)
        b = MB::Sound.beats(16, energy: MB::Sound.knob(:e), swing: 0.56, seed: 2) { kick [1, 0, 0, 0] * 4, keep: [0, 8]; hat [0.7] * 16, drift: 0.2 }
        b.trigger + b.velocity * 0.1 + b.number * 0.001
      }
      a = render(4 * 96000, &setup)
      expect(a.abs.max).to be > 0.9
      slow_tier([[367, 368], [1000, 13]], keep: 1).each do |sizes|
        expect(render(4 * 96000, sizes: sizes, &setup)).to eq(a), "buffer sizes #{sizes}"
      end
    end
  end

  it 'lands a turn made mid-beat on the next beat' do
    # 120 BPM, 800-frame buffers: a beat is 30 buffers; the turn comes
    # with buffer 45 (beat 1.5) and buffer 101 (beat 3.37)
    lines = { 45 => ['turn :e, 1.0, smooth: 0'], 101 => ['turn :e, 0.0, smooth: 0'] }
    setup = -> {
      MB::Sound.knob :e, 0.0, range: 0.0..1.0
      hats(MB::Sound.knob(:e)).trigger
    }
    audio = render(2 * 96000, bpm: 120, lines: lines, &setup)
    got = steps_of(audio, 2, bpm: 120)
    expect(got.each_slice(4).map(&:join).join(' ')).to eq('0000 0000 1111 1111 0000 0000 0000 0000')
    slow_tier([[367, 368], [1000, 13]], keep: 1).each do |sizes|
      # (the same turns, at about the same times)
      at = lines.to_h { |i, code| [(i * 800.0 / sizes.sum * sizes.length).round, code] }
      expect(steps_of(render(2 * 96000, bpm: 120, sizes: sizes, lines: at, &setup), 2, bpm: 120)).to eq(got), "buffer sizes #{sizes}"
    end
  end

  # One note per beat whose velocity is the busy value decided for that
  # beat (decide: 1.beat), through Clip.generate.
  def per_beat_clip
    MB::Sound::Sequence::Clip.generate(1.bar, values: [60], seed: 1, lead: 0, decide: 1.beat, params: { busy: MB::Sound.knob(:busy) }) { |_c, _d, busy:|
      Array.new(4) { |b| [b * 1r / 4, 1r / 8, 60, busy] }
    }
  end

  it 'follows a ramp beat by beat, reading it for each beat\'s start' do
    audio = render(4 * 96000, bpm: 120) {
      MB::Sound.knob :busy, 0.0, range: 0.0..1.0
      MB::Sound.turn :busy, 1.0, over: 2, at: MB::Sound.bar(2)
      per_beat_clip.velocity
    }
    # The velocity sounding a moment into each beat: the ramp at the beat's
    # start (its first frame at bar 2, 1/8 more each beat, then 1)
    got = Array.new(16) { |b| audio[b * 24000 + 100].round(4) }
    expect(got[0..3]).to eq([0.0] * 4)
    expect(got[4]).to be_within(1e-4).of(0)
    (5..11).each { |b| expect(got[b]).to be_within(1e-4).of((b - 4) / 8.0), "beat #{b}" }
    expect(got[12..15]).to eq([1.0] * 4)
  end

  it 'decides units a kit reads ahead for early flams at their own timeline positions' do
    # A clip launched at bar 2 counting from its launch (align: :launch):
    # unit b of cycle c starts at timeline 1 + c + b/4, where a 2-bar
    # square is low in bar 2, high in bar 3.  The kit plays flam-marked
    # notes early, so it reads units ahead of the main read (that read set
    # no steering origin: it asked the LFO for clip positions as if the
    # clip started at 0)
    seen = []
    s = new_session(bpm: 120)
    MB::Sound::Session.with_context(session: s) {
      clip = MB::Sound::Sequence::Clip.generate(1.bar, values: [38], seed: 1, lead: 0, decide: 1.beat, align: :launch,
                                                params: { busy: 2.bars.lfo.square.at(0.0..1.0) }) { |c, _d, busy:|
        seen << [c, busy]
        Array.new(4) { |b| [b * 1r / 4, 1r / 16, 38, 0.2 + 0.6 * busy, { flam: true }] }
      }
      seen.clear # (the clip's own events: cycle 0 previewed at build)
      MB::Sound.bg(:d, MB::Sound.tr909(clip), at: MB::Sound.bar(2))
      360.times { s.process_buffer }
    }
    expect(seen.select { |c, _| c == 0 }.map(&:last).uniq).to eq([0.0])
    expect(seen.select { |c, _| c == 1 }.map(&:last).uniq).to eq([1.0])
  ensure
    s&.close
  end

  describe 'with constant values' do
    # Plain numbers take the unsteered path, unchanged by this branch: a
    # knob resting on the same number (exact in float32) must give the same
    # samples at every granularity, through variations and transforms
    def drums(energy, **opts)
      MB::Sound.beats(16, hold: 2, swing: 0.54, energy: energy, seed: 5, **opts) do
        kick [1, 0, 0, 0] * 4, keep: [0, 4, 8, 12], drift: 0.12
        clap [0, 0, 0, 0, 1, 0, 0, 0] * 2, keep: [4, 12], level: 0.9
        hat euclid(10, 16), mutate: 0.5, drift: 0.15, level: 0.75
        open_hat [0, 0, 0.9, 0] * 4, drift: 0.3, level: 0.7
        fill every: 4, energy: true, snare: 0.7, low_tom: 0.4
      end
    end

    def probe(c)
      c.trigger + c.velocity * 0.1 + c.number * 0.001
    end

    [nil, :step, :bar, 1.n8].each do |decide|
      it "plays exactly as the plain number, deciding per #{decide || :beat}" do
        opts = decide ? { decide: decide } : {}
        [0.75, 0.25].each do |v|
          plain = render(4 * 96000, bpm: 120) { probe(drums(v)) }
          knobbed = render(4 * 96000, bpm: 120) {
            MB::Sound.knob :e, v, range: 0.0..1.0
            probe(drums(MB::Sound.knob(:e), **opts))
          }
          expect(plain.abs.max).to be > 0.9
          expect(knobbed).to eq(plain), "energy #{v}"
        end
      end
    end

    it 'plays exactly as the plain number when humanized or transformed' do
      { humanize: ->(c) { c.humanize(4.ms) }, transpose: ->(c) { c.transpose(2) }, echo: ->(c) { c.echo(1.n16, 1) } }.each do |name, fx|
        plain = render(4 * 96000, bpm: 120) { probe(fx.(drums(0.75))) }
        knobbed = render(4 * 96000, bpm: 120) {
          MB::Sound.knob :e, 0.75, range: 0.0..1.0
          probe(fx.(drums(MB::Sound.knob(:e))))
        }
        expect(knobbed).to eq(plain), name.to_s
      end
    end
  end

  it 'plays in each beat what the plain beat plays at that beat\'s energy (so raising it only adds hits)' do
    # A saw tempo LFO as the energy: four different values a bar
    lfo = 1.bar.lfo.ramp.at(0.0..1.0)
    steered = MB::Sound.beats(16, hold: 2, energy: lfo, seed: 9) { kick [1, 0, 0.3, 0] * 4; hat [0.5] * 16, drift: 0.2; snare [0.2] * 16 }
    plain = ->(e) { MB::Sound.beats(16, hold: 2, energy: e, seed: 9) { kick [1, 0, 0.3, 0] * 4; hat [0.5] * 16, drift: 0.2; snare [0.2] * 16 } }
    beat_of = ->(list, b) { list.select { |e| e.start >= b * 1r / 4 && e.start < (b + 1) * 1r / 4 }.map { |e| [e.start, e.value, e.velocity] } }
    (0..5).each do |cycle|
      events = steered.events_for(cycle)
      energies = (0..3).map { |b| MB::Sound::MIDI::Param::Graph.eval(lfo, cycle + b * 1r / 4) }
      expect(energies.uniq.length).to eq(4)
      energies.each_with_index do |e, b|
        expect(beat_of.(events, b)).to eq(beat_of.(plain.(e).events_for(cycle), b)), "cycle #{cycle} beat #{b}"
      end
      # Raising the energy only adds hits, beat by beat
      by_energy = energies.each_with_index.sort_by(&:first)
      by_energy.each_cons(2) do |(e1, _), (e2, _)|
        (0..3).each do |b|
          lo = beat_of.(plain.(e1).events_for(cycle), b).map { |st, n, _| [st, n] }
          hi = beat_of.(plain.(e2).events_for(cycle), b).map { |st, n, _| [st, n] }
          expect(lo - hi).to be_empty
        end
      end
    end
    expect(steered.steer_units).to eq(4)
  end

  it 'reads per beat by default in every beat of the library\'s family (L.gen.beat)' do
    # (drum-gen-1's beats are beats entries: merged after this branch, the
    # train checked the default reaches them; a saw LFO, four energies a bar)
    lfo = 1.bar.lfo.ramp.at(0.0..1.0)
    beat_of = ->(list, b) { list.select { |e| e.start >= b * 1r / 4 && e.start < (b + 1) * 1r / 4 }.map { |e| [e.start, e.value, e.velocity] } }
    MB::Sound::L.gen.beat.names.each do |name|
      steered = MB::Sound::L.gen.beat.send(name, energy: lfo)
      expect(steered.steer_units).to eq(4), name.to_s
      (0..1).each do |cycle|
        events = steered.events_for(cycle)
        (0..3).each do |b|
          e = MB::Sound::MIDI::Param::Graph.eval(lfo, cycle + b * 1r / 4)
          plain = MB::Sound::L.gen.beat.send(name, energy: e).events_for(cycle)
          expect(beat_of.(events, b)).to eq(beat_of.(plain, b)), "#{name} cycle #{cycle} beat #{b}"
        end
      end
    end
  end

  describe 'the decide: setting' do
    it 'takes :beat (the default), :step, :bar, :cycle, and lengths, and explains mistakes' do
      MB::Sound::Session.with_context(session: new_session.tap { |s| @s = s }) {
        MB::Sound.knob :e, 0.5
        k = MB::Sound.knob(:e)
        expect(hats(k).steer_units).to eq(4)
        expect(hats(k, decide: :step).steer_units).to eq(16)
        expect(hats(k, decide: 1.n8).steer_units).to eq(8)
        expect(hats(k, decide: :bar).steer_units).to eq(1)
        expect(hats(k, decide: :cycle).steer_units).to eq(1)
        expect(MB::Sound.beats(32, energy: k, decide: :bar) { hat [1] }.steer_units).to eq(2)
        # (a cycle shorter than a beat reads once a cycle)
        expect(MB::Sound.beats(2, energy: k) { hat [1] }.steer_units).to eq(1)
        expect(hats(k).steer_lead).to eq(0)
        expect(hats(k).to_ruby).not_to include('decide')
        expect(hats(k, decide: :step).to_ruby).to include('decide: :step')
        expect { hats(k, decide: :beet) }.to raise_error(ArgumentError, /did you mean :beat/)
        expect { hats(0.5, decide: 2.bars) }.to raise_error(ArgumentError, /at most one cycle/)
        expect { hats(0.5, decide: 3) }.to raise_error(ArgumentError, /length/)
      }
    ensure
      @s&.close
    end

    it 'counts how early a humanize moves notes in the decision lead' do
      MB::Sound::Session.with_context(session: new_session.tap { |s| @s = s }) {
        MB::Sound.knob :e, 0.5
        expect(hats(MB::Sound.knob(:e)).humanize(1.n64).steer_lead).to eq(1r / 64)
      }
    ensure
      @s&.close
    end

    it 'round-trips through graph documents, playing the same' do
      MB::Sound::Session.with_context(session: new_session(bpm: 120).tap { |s| @s = s }) {
        MB::Sound.knob :e, 0.75
        g = MB::Sound.beats(16, energy: MB::Sound.knob(:e), seed: 3, decide: :step) { kick [1, 0, 0.5, 0] * 4; hat [0.6] * 16 }
        graph = MB::Sound.tr909(g)
        doc = MB::Sound::GraphIO.dump(graph, name: :t)
        expect(doc).to include('decide: :step')
        loaded = MB::Sound::GraphIO.load(doc)
        a = SpecBuffers.join(Array.new(120) { graph.sample(800).dup })
        b = SpecBuffers.join(Array.new(120) { loaded.sample(800).dup })
        expect(a.abs.max).to be > 0.1
        expect(b).to eq(a)
      }
    ensure
      @s&.close
    end
  end

  describe 'melodic generators (one read a cycle, a beat ahead)' do
    # One note a bar whose velocity is the busy value decided for the cycle
    def busy_clip(seen)
      MB::Sound.generate(1.bar, busy: MB::Sound.knob(:busy), values: [60], seed: 1) { |cycle, _dice, busy:|
        seen[cycle] = busy
        [[0r, 1r / 8, 60, busy]]
      }
    end

    it 'read a square LFO for each cycle\'s start, with no lag' do
      seen = {}
      render(6 * 96000) {
        MB::Sound.knob :busy, 0.5, range: 0.0..1.0
        MB::Sound.turn :busy, 2.bars.lfo.square.at(0.0..1.0)
        busy_clip(seen).velocity
      }
      expect(seen.select { |c, _| c >= 0 }.sort.map(&:last).first(6)).to eq([1, 0, 1, 0, 1, 0])
    end

    it 'still read a hand turn at the decision point, a beat before the cycle' do
      seen = {}
      # 120 BPM: buffer 105 is at 0.875 bars (after cycle 1's decision
      # point at 0.75), so the turn steers cycle 2
      render(3 * 96000, bpm: 120, lines: { 105 => ['turn :busy, 0.6, smooth: 0'] }) {
        MB::Sound.knob :busy, 0.2, range: 0.0..1.0
        busy_clip(seen).velocity
      }
      expect(seen.values_at(0, 1, 2).map { |v| v.round(4) }).to eq([0.2, 0.2, 0.6])
    end
  end

  describe 'Ahead' do
    it 'computes the next beat with the values of now, so a constant knob computes each cycle once' do
      r = Class.new {
        attr_reader :jobs

        def initialize = @jobs = 0

        def background
          yield
          @jobs += 1
          true
        end
      }.new
      MB::Sound::Generative::Ahead.attach(r)
      MB::Sound::Session.with_context(session: new_session(bpm: 120).tap { |s| @s = s }) {
        MB::Sound.knob :e, 0.5
        g = hats(MB::Sound.knob(:e))
        MB::Sound.bg(:d, g.trigger, on: :now)
        240.times { @s.process_buffer }
        gen = g.variations[0].block
        # 2 bars: the clip's own events, the cycle before the launch (the
        # chase), cycles 0-1, and cycle 2 ahead, once each (not once a beat)
        expect(gen.stats[:cycles]).to be <= 5
        expect(r.jobs).to be >= 7
      }
    ensure
      MB::Sound::Generative::Ahead.detach(r)
      @s&.close
    end
  end

  describe 'takes' do
    it 'replay a beat steered per beat bit for bit at any buffer size, with hand turns and an LFO' do
      session = new_session(bpm: 120)
      lines = {
        0 => [
          'knob :e, 0.3',
          'g = beats(16, energy: knob(:e), swing: 0.55, seed: 4) { kick [1, 0, 0, 0] * 4, keep: [0, 8]; hat [0.6] * 16, drift: 0.2; snare [0.2] * 16 }',
          "track(:d, q: 1) { |c| c.number * 0.003 + c.trigger * 0.2 + c.velocity * 0.05 }",
          'scene :a, d: g',
          'go :a, at: :now',
        ],
        47 => ['turn :e, 0.9'],
        100 => ['turn :e, 2.beats.lfo.square.at(0.1..0.9)'],
        230 => ['turn :e, 0.2, over: 1'],
        300 => ['seek 5'],
      }
      bnd = MB::Sound::Take.console_binding
      MB::Sound.seed(5)
      t = MB::Sound::Take.new(session: session)
      live = SpecBuffers.join(Array.new(400) { |i|
        lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: session) { t.line(code, bnd) } }
        session.process_buffer[0].dup
      })
      expect(live.abs.max).to be > 0.2

      path = tmp_path('take.rb')
      expect { t.save(path) }.to output(/Saved/).to_stdout
      load path
      replay = MB::Sound::Take::Replay.last
      slow_tier([[800], [367, 368]], keep: 2).each do |sizes|
        MB::Sound.seed(5)
        out = []
        replay.render(MB::Sound::NullOutput.new(channels: 1, sleep: false), buffer_sizes: sizes, tail: 0) { |mix| out << mix[0].dup }
        data = SpecBuffers.join(out)
        expect(data.length).to be >= live.length
        expect(data[0...live.length]).to eq(live), "buffer sizes #{sizes}"
      end
    ensure
      session&.close
    end
  end
end
