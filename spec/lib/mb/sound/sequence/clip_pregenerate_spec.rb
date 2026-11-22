# Generator clips made ahead of their landing (bg-latency-2, 2026-11-22):
# the buffer where `bg`, `swap`, or a scene starts a generated beat used to
# compute the generator's look-back cycles, a unit's events and an edge
# table per beat, and the chase on the render thread (16.5-17.9 ms of CPU at
# 256 frames for a swap, over three periods).  Now the command makes them on
# its own thread (Sequence::Clip#pregenerate), each steered beat with the
# values its knobs have then, and the landing takes a result only when its
# own decision brings the same values: counted here, not timed, and checked
# bit for bit against the path without pregenerating.
RSpec.describe(MB::Sound::Sequence::Clip, '#pregenerate', :aggregate_failures) do
  BAR = 96000 # (frames per bar at 120 BPM)

  before do
    # (#render_unprepared: the path before, clip sources pregenerating
    # nothing)
    unprepared = -> { @unprepared }
    allow_any_instance_of(MB::Sound::MIDI::ClipSource).to receive(:prepare_clip).and_wrap_original { |m, clip, at: nil, epoch: 0|
      m.call(clip, at: unprepared.() ? nil : at, epoch: epoch)
    }
  end

  after do
    MB::Sound.rewind
  end

  # A steered beat (energy from knob :e, read per beat), or a plain one.
  def beat(seed, steered: true)
    energy = steered ? MB::Sound.knob(:e) : 0.7
    MB::Sound.beats(16, energy: energy, hold: 2, seed: seed) {
      kick [1, 0, 0, 0.2] * 4, keep: [0, 8]
      snare [0, 0, 0, 0, 1, 0, 0.1, 0] * 2, keep: [4, 12]
      hat [1, 0.3] * 8, mutate: 0.4
      fill every: 2, snare: 0.6
    }
  end

  # Renders +bars+ bars at +n+ frames in a new offline Session: a track playing
  # beat 1 from bar 1, then +command+ (code run with MB::Sound's methods)
  # (a Proc given the example) issued halfway through bar 2, landing on
  # bar 3, and +between+ run a
  # quarter bar later, before it lands.  Returns [the audio, counts in the
  # landing buffer: generator cycles computed, unit event lists and edge
  # tables made].
  def render(n, command, between: nil, steered: true, bars: 6)
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120),
                               channels: 1, buffer_size: n, realtime: false, raise_errors: true, master_gain: 1)
    counting = false
    counts = Hash.new(0)
    allow(MB::Sound::Sequence::Clip::EdgeTable).to receive(:new).and_wrap_original { |m, **kw| counts[:tables] += 1 if counting; m.call(**kw) }
    allow(MB::Sound::Sequence::Clip::UnitEvents).to receive(:new).and_wrap_original { |m, **kw| counts[:units] += 1 if counting; m.call(**kw) }
    gens = []
    allow(MB::Sound::Generative::Generator).to receive(:new).and_wrap_original { |m, *a, **kw, &b| m.call(*a, **kw, &b).tap { |g| gens << g } }
    run = ->(code) { MB::Sound::Session.with_context(session: s) { code.(self) } }
    run.(->(x) {
      MB::Sound.knob :e, 0.6, range: 0.0..1.0
      MB::Sound.track(:d) { |c| c.trigger + c.velocity * 0.5 }
      MB::Sound.bg :d, x.beat(1, steered: steered)
    })
    out = []
    land = 2 * BAR
    (bars * BAR / n.to_f).ceil.times do |i|
      frame = i * n
      run.(command) if frame <= BAR * 3 / 2 && frame + n > BAR * 3 / 2
      run.(between) if between && frame <= BAR * 7 / 4 && frame + n > BAR * 7 / 4
      counting = frame <= land && frame + n > land
      cycles = gens.sum { |g| g.stats[:cycles] }
      objects = GC.stat(:total_allocated_objects)
      buf = s.process_buffer[0]
      @landing_objects = GC.stat(:total_allocated_objects) - objects if counting
      out << buf.dup
      counts[:cycles] += gens.sum { |g| g.stats[:cycles] } - cycles if counting
    end
    [SpecBuffers.join(out), counts.reject { |_, v| v == 0 }]
  ensure
    s&.close
  end

  # #render with nothing pregenerated (the path before).
  def render_unprepared(...)
    @unprepared = true
    render(...)
  ensure
    @unprepared = false
  end

  {
    'swap' => ->(x) { MB::Sound.swap :d, x.beat(2) },
    'bg of another clip on the track' => ->(x) { MB::Sound.bg :d, x.beat(3).transpose(1) },
    'scene launch' => ->(x) { MB::Sound.scene :x, d: x.beat(4); MB::Sound.go :x },
  }.each do |path, command|
    it "lands a #{path} of a steered beat computing nothing, and plays what it played before" do
      [800, *slow_tier([367])].each do |n|
        audio, counts = render(n, command)
        objects = @landing_objects
        before, old = render_unprepared(n, command)
        expect(counts).to eq({}), "#{n} frames"
        expect(old[:cycles] + old[:tables]).to be > 0, "#{n} frames: the path before computed at the landing"
        expect(audio.to_binary.hash).to eq(before.to_binary.hash), "#{n} frames"
        expect(audio.abs.max).to be > 0.4
        # (the landing buffer's allocations: 660-890 objects, 3200-3800
        # before; the rest is the swap, the chase, and the notes)
        expect(objects).to be < 1200, "#{n} frames"
        expect(@landing_objects).to be > objects
      end
    end
  end

  it 'lands each library drum beat, steered by its track knobs, computing nothing', render_budget: { seconds: 120, reason: 'seven beats, each rendered twice for 4 bars' } do
    %i[rock pop halftime funk house dnb techno].each do |name|
      bg = ->(_) { MB::Sound.bg :d, MB::Sound::L.gen.beat.public_send(name) }
      audio, counts = render(800, bg, bars: 4)
      before, = render_unprepared(800, bg, bars: 4)
      expect(counts).to eq({}), name.to_s
      expect(audio.to_binary.hash).to eq(before.to_binary.hash), name.to_s
    end
  end

  it 'lands a swap of a plain generator computing nothing' do
    swap = ->(x) { MB::Sound.swap :d, x.beat(2, steered: false) }
    audio, counts = render(800, swap, steered: false)
    before, = render_unprepared(800, swap, steered: false)
    expect(counts).to eq({})
    expect(audio.to_binary.hash).to eq(before.to_binary.hash)
  end

  it 'makes only the beats whose values moved when the knob turns between the command and the landing' do
    [800, *slow_tier([367])].each do |n|
      turn = ->(_) { MB::Sound.turn :e, 0.95 }
      swap = ->(x) { MB::Sound.swap :d, x.beat(2) }
      audio, counts = render(n, swap, between: turn)
      before, old = render_unprepared(n, swap, between: turn)
      expect(audio.to_binary.hash).to eq(before.to_binary.hash), "#{n} frames"
      # (the beats decided at the landing for positions after the turn get
      # the turned value: those are made again there, the rest are taken)
      expect(counts[:units]).to be > 0
      expect(counts[:units]).to be <= old[:units]
      expect(counts[:tables]).to be <= old[:tables]
    end
  end

  it 'keeps a result only for the values it was made with (Clip#pregenerate)' do
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120),
                               channels: 1, realtime: false, raise_errors: true)
    MB::Sound::Session.with_context(session: s) {
      MB::Sound.knob :e, 0.2, range: 0.0..1.0
      clip = beat(5)
      made = clip.pregenerate(8r, origin: 0r, epoch: s.epoch)
      expect(made).to be > 20
      pregen = clip.instance_variable_get(:@pregen)
      expect(pregen.cycles.values.map { |v, _| v[:energy] }.uniq).to eq([0.2])
      expect(pregen.edges.keys).to all(be >= s.epoch << 48)
    }
  ensure
    s&.close
  end
end
