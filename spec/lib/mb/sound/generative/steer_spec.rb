RSpec.describe('MB::Sound generator steering (G3)', :aggregate_failures) do
  # 120 BPM: a bar (a whole note) is 2 seconds, 96000 samples
  def new_session(buffer_size: 800)
    MB::Sound::Session.new(
      output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120),
      channels: 1, buffer_size: buffer_size, realtime: false, raise_errors: true, master_gain: 1
    )
  end

  # A one-bar generator playing one note whose velocity is the knob :busy
  # as decided for the cycle; +seen+ collects cycle => busy.
  def busy_clip(seen, **opts)
    MB::Sound.generate(1.bar, busy: MB::Sound.knob(:busy), values: [60], seed: 1, **opts) { |cycle, _dice, busy:|
      seen[cycle] = busy
      [[0r, 1r / 8, 60, busy]]
    }
  end

  # Renders +bars+ bars at +sizes+ (cycled) in a new Session after running
  # +setup+ in it (with MB::Sound's methods), and +lines+ (buffer index =>
  # code) between buffers.  Returns [seen, audio].
  def steer_render(bars, sizes: [800], lines: {}, &setup)
    s = new_session(buffer_size: sizes.max)
    seen = {}
    MB::Sound::Session.with_context(session: s) { setup.call(seen) }
    out = []
    n = 0
    i = 0
    while n < bars * 96000
      lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: s) { MB::Sound.instance_eval(code) } }
      out << s.process_buffer(sizes[i % sizes.length])[0].dup
      n += out.last.length
      i += 1
    end
    [seen.sort.to_h, SpecBuffers.join(out)[0...(bars * 96000)]]
  ensure
    s&.close
  end

  it 'reads knobs at each cycle\'s decision point, a beat before the cycle, at any buffer size' do
    setup = ->(seen) {
      MB::Sound.knob :busy, 0.0, range: 0.0..1.0
      MB::Sound.bg(:a, busy_clip(seen).velocity, on: :now)
      # From bar 2 (position 1) to bar 4 (position 3)
      MB::Sound.turn :busy, 1.0, over: 2, at: MB::Sound.bar(2)
    }
    seen, audio = steer_render(5, &setup)
    # Decision points 1.75 (3/8 of the ramp) and 2.75 (7/8)
    expect(seen[0]).to eq(0)
    expect(seen[1]).to eq(0)
    expect(seen[2]).to be_within(1e-4).of(0.375)
    expect(seen[3]).to be_within(1e-4).of(0.875)
    expect(seen[4]).to eq(1)
    expect(audio.abs.max).to be > 0.9

    slow_tier([[800], [367, 368], [1000, 13]], keep: 2).drop(1).each do |sizes|
      seen2, audio2 = steer_render(5, sizes: sizes, &setup)
      expect(seen2).to eq(seen), "buffer sizes #{sizes}"
      expect(audio2).to eq(audio), "buffer sizes #{sizes}"
    end
  end

  it 'steers the next cycle with a turn issued before its decision point, else the cycle after' do
    setup = ->(seen) {
      MB::Sound.knob :busy, 0.2, range: 0.0..1.0
      MB::Sound.bg(:a, busy_clip(seen).velocity, on: :now)
    }
    # Buffer 150 starts at 1.25 bars (before cycle 2's decision point at
    # 1.75), buffer 200 at 1.667 bars (after cycle 2's, before cycle 3's)
    seen, = steer_render(4, lines: { 150 => ['turn :busy, 0.6, smooth: 0'] }, &setup)
    expect(seen.values_at(1, 2, 3).map { |v| v.round(4) }).to eq([0.2, 0.6, 0.6])
    seen, = steer_render(4, lines: { 215 => ['turn :busy, 0.6, smooth: 0'] }, &setup)
    expect(seen.values_at(1, 2, 3).map { |v| v.round(4) }).to eq([0.2, 0.2, 0.6])
  end

  it 'never reads a steered cycle before its decision point' do
    seen = {}
    clip = MB::Sound::Session.with_context(session: new_session.tap { |s| @s = s }) {
      MB::Sound.knob :busy, 0.5
      busy_clip(seen)
    }
    seen.clear # (the clip's own events computed cycle 0)
    clip.edges(0, 1r / 2)
    clip.edges(1r / 2, 3r / 4)
    expect(seen.keys).to eq([])
    # The decision point is where a quiet read must stop
    expect(clip.edge_horizon(1r / 4).first).to eq(3r / 4)
    clip.edges(3r / 4, 3r / 4 + 1r / 100)
    expect(seen.keys).to eq([1])
    clip.edges(3r / 4 + 1r / 100, 7r / 4)
    expect(seen.keys).to eq([1])
    clip.edges(7r / 4, 2)
    expect(seen.keys).to eq([1, 2])
  ensure
    @s&.close
  end

  it 'computes cycles cold the same as in order with a knob gesture' do
    late = {}
    gest = ->(seen) {
      MB::Sound.knob :busy, 0.0, range: 0.0..1.0
      MB::Sound.bg(:a, busy_clip(seen).velocity, on: :now)
      # A copy launched at bar 5 computes its cycles cold from cycle 4
      MB::Sound.bg(:b, busy_clip(late).velocity, at: MB::Sound.bar(5))
      MB::Sound.turn :busy, 0 => 0.2, 8.bars => 0.9
    }
    in_order, audio = steer_render(8, &gest)
    expect(late.keys).to include(5, 6, 7)
    (5..7).each { |c| expect(late[c]).to eq(in_order[c]), "cycle #{c}" }
    expect(in_order.values_at(*1..7).each_cons(2).all? { |a, b| b > a }).to eq(true)
    expect(audio.abs.max).to be > 1

    # motifs: any cycle, cold, from the values decided
    MB::Sound::Session.with_context(session: new_session.tap { |s| @s = s }) {
      MB::Sound.knob :busy, 0.5
      h = MB::Sound.scale(:dorian, :d).weights
      warm = MB::Sound.motifs(h, 8, density: MB::Sound.knob(:busy), mutate: MB::Sound.knob(:busy), evolve: 1, seed: 4).variations[0].block
      list = (0..40).map { |c| warm.compute(c, { density: 0.3 + c / 100.0, mutate: 0.4 }) }
      [37, 3, 0, 22].each do |c|
        cold = MB::Sound.motifs(h, 8, density: MB::Sound.knob(:busy), mutate: MB::Sound.knob(:busy), evolve: 1, seed: 4).variations[0].block
        expect(cold.compute(c, { density: 0.3 + c / 100.0, mutate: 0.4 })).to eq(list[c]), "cycle #{c}"
      end
    }
  ensure
    @s&.close
  end

  describe 'motifs density' do
    it 'thins and fills around 0.5: the same notes at the same density, more notes only added' do
      h = MB::Sound.scale(:dorian, :d).weights
      knobbed = MB::Sound::Session.with_context(session: new_session.tap { |s| @s = s }) {
        MB::Sound.knob :busy, 0.5
        MB::Sound.motifs(h, 16, step: 1.n16, density: MB::Sound.knob(:busy), seed: 9, form: %i[a])
      }
      plain = MB::Sound.motifs(h, 16, step: 1.n16, seed: 9, form: %i[a])
      gen = knobbed.variations[0].block
      at = ->(d, c = 0) { gen.compute(c, { density: d }).map { |e| [e.start, e.value] } }
      # 0.5 is the motif as built
      expect(at.(0.5)).to eq(plain.events_for(0).map { |e| [e.start, e.value] })
      starts = [0.0, 0.2, 0.4, 0.5, 0.6, 0.8, 1.0].map { |d| at.(d).map(&:first) }
      starts.each_cons(2) { |a, b| expect(a - b).to be_empty }
      expect(starts.first.length).to eq(1)
      expect(starts.last.length).to eq(16)
      # The same density gives the same rhythm in later passes
      expect(at.(0.8, 3).map(&:first)).to eq(at.(0.8).map(&:first))
    ensure
      @s&.close
    end
  end

  describe 'Ahead' do
    # Runs background blocks right away on the calling thread.
    class SyncRunner
      attr_reader :jobs

      def initialize
        @jobs = 0
      end

      def background
        yield
        @jobs += 1
        true
      end
    end

    it 'computes the next cycle with the knob values of now, used when the decision agrees' do
      r = SyncRunner.new
      MB::Sound::Generative::Ahead.attach(r)
      seen = {}
      MB::Sound::Session.with_context(session: new_session.tap { |s| @s = s }) {
        MB::Sound.knob :busy, 0.3
        clip = busy_clip(seen)
        gen = clip.variations[0].block
        clip.events_for(0)
        computed = gen.stats[:cycles]
        expect(gen.cached?(1, { busy: 0.3 })).to eq(true)
        clip.events_for(1)
        expect(gen.stats[:cycles]).to eq(computed + 1) # (cycle 2 ahead; cycle 1 was cached)
        MB::Sound.turn :busy, 0.7, smooth: 0, on: :now
        @s.process_buffer
        expect(clip.events_for(2).first.velocity).to be_within(1e-4).of(0.7)
        expect(r.jobs).to be >= 2
      }
    ensure
      MB::Sound::Generative::Ahead.detach(r)
      @s&.close
    end
  end

  describe 'MIDI::Param.peek' do
    it 'decides nothing: no knob decision logged, no choice state kept' do
      s = new_session
      MB::Sound::Session.with_context(session: s) {
        MB::Sound.knob :sel, 0.0
        k = MB::Sound.knob(:sel)
        knob = s.knobs[:sel]
        choice = k.choose(:a, :b)
        MB::Sound::MIDI::Param.peek {
          expect(knob.value_at(10r)).to eq(0)
          expect(choice.value_at(10r)).to eq(:a)
        }
        expect(s.decision_log_length).to eq(0)
        expect(choice.instance_variable_get(:@last)).to be_nil
        knob.value_at(10r)
        expect(s.decision_log_length).to eq(1)
      }
    ensure
      s&.close
    end
  end

  describe 'generate keywords' do
    it 'passes options to the block, and suggests block keywords for typos' do
      c = MB::Sound.generate(1.bar, busy: 0.5, seed: 2) { |_cycle, _dice, busy:| [[0r, 1r / 8, 60, busy]] }
      expect(c).not_to be_steered
      expect(c.events_for(3).first.velocity).to eq(0.5)
      expect {
        MB::Sound.generate(1.bar, bussy: 0.5) { |_cycle, _dice, busy: 0.2| [] }
      }.to raise_error(ArgumentError, /no keyword :bussy.*did you mean :busy/)
      expect {
        MB::Sound.generate(1.bar, sed: 3) { |_cycle, _dice| [] }
      }.to raise_error(ArgumentError, /did you mean :seed/)
      expect {
        MB::Sound.generate(1.bar) { |_cycle, _dice, busy:| [] }
      }.to raise_error(ArgumentError, /needs busy:/)
    end

    it 'keeps steered events from starting before the decision point' do
      s = new_session
      MB::Sound::Session.with_context(session: s) {
        MB::Sound.knob :busy, 0.5
        expect {
          MB::Sound.generate(1.bar, busy: MB::Sound.knob(:busy)) { |_cycle, _dice, busy:| [[-1r / 2, 1r / 8, 60, busy]] }
        }.to raise_error(ArgumentError, /at most its lead/)
        expect {
          MB::Sound.generate(1.bar, lead: 2.bars, busy: MB::Sound.knob(:busy)) { |_c, _d, busy:| [] }
        }.to raise_error(ArgumentError, /at most one cycle/)
      }
    ensure
      s&.close
    end
  end

  describe 'takes' do
    it 'replay steered generators bit for bit at any buffer size, with live turns' do
      session = new_session
      lines = {
        0 => [
          'knob :busy, 0.3',
          'knob :reg, 0.0',
          'h = harmony(0 => scale(:dorian, :d), 2.bars => scale(:major, :f), loop: 4.bars)',
          'lead = motifs(h, 8, density: knob(:busy), mutate: knob(:busy), evolve: 1, range: knob(:reg).choose(A2..A4, A3..A5))',
          'bells = strikes(h.over(A4..A6), every: 1.n8, chance: knob(:busy))',
          "track(:lead, q: 1) { |c| c.number * 0.01 + c.velocity * 0.1 }",
          "track(:bells, q: 1) { |c| c.number * 0.003 + c.trigger * 0.2 }",
          'scene :a, lead: lead, bells: bells',
          'go :a, at: :now',
        ],
        100 => ['turn :busy, 0.9, over: 2'],
        230 => ['turn :reg, 1.0'],
        300 => ['seek 9'],
        400 => ['turn :busy, 0.1'],
      }
      bnd = MB::Sound::Take.console_binding
      MB::Sound.seed(5)
      t = MB::Sound::Take.new(session: session)
      live = SpecBuffers.join(Array.new(480) { |i|
        lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: session) { t.line(code, bnd) } }
        session.process_buffer[0].dup
      })
      expect(live.abs.max).to be > 0.3

      path = tmp_path('take.rb')
      expect { t.save(path) }.to output(/Saved/).to_stdout
      load path
      r = MB::Sound::Take::Replay.last
      slow_tier([[800], [367, 368]], keep: 2).each do |sizes|
        MB::Sound.seed(5)
        out = []
        r.render(MB::Sound::NullOutput.new(channels: 1, sleep: false), buffer_sizes: sizes, tail: 0) { |mix| out << mix[0].dup }
        data = SpecBuffers.join(out)
        expect(data.length).to be >= live.length
        expect(data[0...live.length]).to eq(live), "buffer sizes #{sizes}"
      end
    ensure
      session&.close
    end
  end
end
