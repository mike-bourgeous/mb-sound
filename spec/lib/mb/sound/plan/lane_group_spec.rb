# Structurally identical regions run together (MB::Sound::Plan::LaneGroup):
# a Synth's lanes, one FastPlan.run_lanes call per block with lane-major
# recursions, exactly what each lane gives alone.
RSpec.describe(MB::Sound::Plan::LaneGroup) do
  around do |ex|
    old = [MB::Sound::Plan.precision, MB::Sound::Plan.lanes]
    MB::Sound::Plan.precision = :exact
    ex.run
  ensure
    MB::Sound::Plan.precision, MB::Sound::Plan.lanes = old
  end

  # A synth whose lanes use every lane-major op; +lanes+ turns grouping
  # on or off.  Without grouping, lanes aren't skipped either, so the two
  # are comparable sample for sample.
  def make_synth(file = 'spec/test_data/dense_modulated.mid', voices: 4, spares: 2, lanes: true, &extra)
    MB::Sound::Plan.lanes = lanes
    MB::Sound.seed(0)
    MB::Sound.synth(file, voices: voices, spares: spares, skip_idle: false) { |v|
      base = v.hz.glide(50.ms)
      mod = v.cc(1, range: 1.0..2.0)
      e = v.fm_env(0, 1, 0.5, 0.3) * base.transpose(12).sine.pm(mod * base.sine)
      saw = v.amp_env * base.ramp.pm(e * mod + v.bend) * 0.1
      out = saw.filter(:lowpass, cutoff: v.cutoff(800), quality: 2) +
        saw.lp4(v.cutoff(1200), resonance: v.reso(0.4)) * 0.5 +
        saw.diode(v.cutoff(700), resonance: v.reso(0.6), drive: 1.5) * 0.3 +
        saw.filter(:highpass, cutoff: 300, structure: :biquad) * 0.25
      extra ? extra.call(v, out) : out
    }
  end

  def render(synth, sizes, &each_block)
    out = []
    sizes.each_with_index do |n, i|
      each_block&.call(synth, i)
      b = synth.sample(n)
      break if b.nil?

      out.concat(b.to_a)
    end
    out
  end

  let(:sizes) { [128, 1, 37, 512, 800, 128, 64, 2, 255] * 5 }

  it "groups the same region of every lane (voices and spares)" do
    s = make_synth
    s.sample(128)
    groups = s.lane_groups.groups
    expect(groups.length).to be >= 1
    expect(groups.map { |g| g.members.length }.max).to eq(6)
    expect(groups.sum(&:lane_runs)).to be > 0
  end

  it 'gives the same samples as each lane alone, at any block sizes' do
    %w[spec/test_data/dense_modulated.mid spec/test_data/c_major.mid].each do |f|
      a = render(make_synth(f), sizes)
      b = render(make_synth(f, lanes: false), sizes)
      expect(a.length).to be > 5000
      expect(a).to eq(b), f
    end
  end

  it 'stays exact when voices are stolen and spares take notes' do
    a = render(make_synth(voices: 2, spares: 1), sizes)
    b = render(make_synth(voices: 2, spares: 1, lanes: false), sizes)
    expect(a).to eq(b)
  end

  it 'computes every lane every block (no idle skipping in grouped lanes)' do
    MB::Sound::Plan.lanes = true
    MB::Sound.seed(0)
    s = MB::Sound.synth('spec/test_data/c_major.mid', voices: 4) { |v| v.hz.saw.filter(:lowpass, cutoff: 1000) * v.amp_env }
    expect(s.lane_groups.groups).not_to be_empty
    expect(s.skippable_lanes).to be_empty
    200.times { s.sample(128) }
    expect(s.skipped_lanes).to be_empty
  end

  it 'still skips idle lanes with lane groups off' do
    MB::Sound::Plan.lanes = false
    MB::Sound.seed(0)
    s = MB::Sound.synth('spec/test_data/c_major.mid', voices: 4) { |v| v.hz.saw.filter(:lowpass, cutoff: 1000) * v.amp_env }
    expect(s.lane_groups).to be_nil
    expect(s.skippable_lanes).not_to be_empty
  end

  it 'gives the same samples in check mode' do
    old = MB::Sound::Plan.check
    MB::Sound::Plan.check = :raise
    a = render(make_synth, sizes.first(14))
    MB::Sound::Plan.check = old
    b = render(make_synth(lanes: false), sizes.first(14))
    expect(a).to eq(b)
  end

  it 'gives the same samples with the Ruby mirror' do
    old = MB::Sound::Plan.engine
    MB::Sound::Plan.engine = :ruby
    a = render(make_synth, sizes.first(10))
    MB::Sound::Plan.engine = old
    b = render(make_synth(lanes: false), sizes.first(10))
    expect(a.length).to eq(b.length)
    expect((Numo::DFloat.cast(a) - Numo::DFloat.cast(b)).abs.max).to be <= 1e-6
  end

  it 'stays exact when a lane rebuilds its plans in the middle of the song' do
    rebuild = ->(s, i) { s.plans[1].stale! if i == 4 || i == 9 }
    a = render(make_synth, sizes.first(20), &rebuild)
    b = render(make_synth(lanes: false), sizes.first(20), &rebuild)
    expect(a).to eq(b)
  end

  it 'regroups after a rebuild' do
    s = make_synth
    s.sample(128)
    before = s.lane_groups.groups.map { |g| g.members.length }
    s.plans[1].stale!
    s.sample(128)
    s.sample(128)
    expect(s.lane_groups.groups.map { |g| g.members.length }).to eq(before)
    expect(s.lane_groups.groups.all? { |g| g.members.all? { |r| r.root.instance_variable_get(:@plan_region).equal?(r) } }).to eq(true)
  end

  it 'stays exact when a member stops planning in the middle of the song' do
    stop = ->(s, i) { s.plans[2].regions.last.disable('spec') if i == 5 }
    a = render(make_synth, sizes.first(20), &stop)
    b = render(make_synth(lanes: false), sizes.first(20), &stop)
    expect(a).to eq(b)
  end

  it 'runs a member asked for while the group gathers (one member reading another)' do
    # Two identical regions in one graph, the second reading the first
    # (through a node without ops)
    MB::Sound.seed(0)
    src = PlanSpecHelpers::Source.new(seed: 3)
    a1 = (src * 0.5).filter(:lowpass, cutoff: 900) * 2
    a2 = (a1.proc { |x| x } * 0.5).filter(:lowpass, cutoff: 900) * 2
    graph = a2.get_sampler
    inst = MB::Sound::Plan.install(graph)
    expect(inst.regions.length).to eq(2)
    expect(inst.regions.map { |r| r.program.signature }.uniq.length).to eq(1)
    group = MB::Sound::Plan::LaneGroup.new(inst.regions)

    MB::Sound.seed(0)
    src2 = PlanSpecHelpers::Source.new(seed: 3)
    b1 = (src2 * 0.5).filter(:lowpass, cutoff: 900) * 2
    b2 = (b1.proc { |x| x } * 0.5).filter(:lowpass, cutoff: 900) * 2
    ref = b2.get_sampler
    MB::Sound::Plan.enabled = false
    sizes.first(12).each do |n|
      expect(graph.sample(n).to_a).to eq(ref.sample(n).to_a)
    end
    expect(group.runs).to be > 0
  ensure
    MB::Sound::Plan.enabled = true
  end

  describe 'regions of one installation' do
    # A stereo patch whose channels have the same shape (different
    # constants), and a third channel of another shape
    def make_bundle(lanes)
      MB::Sound::Plan.lanes = lanes
      MB::Sound.seed(0)
      lfo = 0.3.hz.lfo.sine.at(600..2400)
      chans = [110, 165].map { |f| f.hz.ramp.pm(src_wave(f) * 0.2).filter(:lowpass, cutoff: lfo, quality: 2).lp4(1500, resonance: 0.3) * 0.4 }
      chans << 55.hz.sine * 0.3
      MB::Sound::GraphNode::Channels.new(chans)
    end

    def src_wave(seed)
      PlanSpecHelpers::Source.new(seed: seed)
    end

    def render_bundle(lanes, sizes)
      b = make_bundle(lanes)
      inst = MB::Sound::Plan.install(b)
      out = sizes.map { |n| b.outputs.map { |o| o.sample(n).to_a } }
      [out, inst]
    end

    it 'groups the channels of the same shape and gives the same samples' do
      a, inst = render_bundle(true, sizes)
      b, _ = render_bundle(false, sizes)
      expect(a).to eq(b)
      groups = inst.lane_groups.groups
      expect(groups.map { |g| g.members.length }).to eq([2])
      expect(groups[0].lane_runs).to be > 0
    end

    it 'regroups after a rebuild' do
      b = make_bundle(true)
      inst = MB::Sound::Plan.install(b)
      b.outputs.each { |o| o.sample(64) }
      inst.stale!
      3.times { b.outputs.each { |o| o.sample(64) } }
      expect(inst.lane_groups.groups.map { |g| g.members.length }).to eq([2])
      expect(inst.lane_groups.groups[0].members.all?(&:installed?)).to eq(true)
    end
  end

  describe 'lane-major filter kernels' do
    # One graph per lane: +build+ is called with the lane index and a
    # fresh input source; the lanes' regions are grouped by hand.
    def compare_lanes(lanes, sizes: self.sizes, &build)
      MB::Sound.seed(0)
      graphs = lanes.times.map { |i| build.call(i, PlanSpecHelpers::Source.new(seed: i + 1)).get_sampler }
      insts = graphs.map { |g| MB::Sound::Plan.install(g) }
      expect(insts.map { |inst| inst.regions.length }.uniq).to eq([1])
      regions = insts.map { |inst| inst.regions.first }
      expect(regions.map { |r| r.program.signature }.uniq.length).to eq(1)
      group = MB::Sound::Plan::LaneGroup.new(regions)

      MB::Sound.seed(0)
      MB::Sound::Plan.enabled = false
      refs = lanes.times.map { |i| build.call(i, PlanSpecHelpers::Source.new(seed: i + 1)).get_sampler }
      MB::Sound::Plan.enabled = true

      sizes.each_with_index do |n, b|
        got = graphs.map { |g| g.sample(n).dup }
        exp = refs.map { |g| g.sample(n) }
        lanes.times do |i|
          expect(got[i].to_binary).to eq(exp[i].to_binary), "lane #{i}, block #{b} (#{n} samples): differs by #{(got[i] - exp[i]).abs.max}"
        end
      end
      expect(group.lane_runs).to be > 0
      group
    ensure
      MB::Sound::Plan.enabled = true
    end

    it 'runs SVFs of every type with moving parameters' do
      types = MB::Sound::Filter::SVF::FILTER_TYPES
      compare_lanes(types.length) { |i, src|
        cutoff = PlanSpecHelpers::Source.new(seed: i + 7, scale: 900, offset: 1200)
        quality = PlanSpecHelpers::Source.new(kind: :steps, seed: i + 3, scale: 2, offset: 2.5, every: 77)
        gain = PlanSpecHelpers::Source.new(kind: :steps, seed: i + 5, scale: 4, offset: 5, every: 131)
        (src * 0.5).filter(types[i], cutoff: cutoff, quality: quality, gain: gain) * 2
      }
    end

    it 'runs four-poles and diode ladders in every drive mode, mixed in one group' do
      settings = [
        { mode: :lp4 }, { mode: :hp4 }, { mode: :bp2, drive: 2, drive_mode: :input },
        { drive: 1.5, drive_mode: :stages }, { drive: 2, drive_mode: :feedback, clip: :hard },
        { mode: :diode }, { mode: :diode, drive: 2 }, { mode: :diode, drive: 1, drive_mode: :feedback },
        { self_oscillate: true },
      ]
      compare_lanes(settings.length) { |i, src|
        cutoff = PlanSpecHelpers::Source.new(seed: i + 2, scale: 1500, offset: 2000)
        res = PlanSpecHelpers::Source.new(kind: :steps, seed: i + 4, scale: 0.45, offset: 0.5, every: 90)
        (src * 0.5).lp4(cutoff, resonance: res, **settings[i]) * 2
      }
    end

    it 'runs cookbook biquads with moving parameters' do
      compare_lanes(5) { |i, src|
        cutoff = PlanSpecHelpers::Source.new(seed: i + 2, scale: 1500, offset: 2000)
        quality = PlanSpecHelpers::Source.new(kind: :steps, seed: i + 4, scale: 2, offset: 3, every: 90)
        (src * 0.5).filter(:bandpass, cutoff: cutoff, quality: quality, structure: :biquad) * 2
      }
    end
  end

  describe 'FastPlan.run_lanes' do
    it 'raises for lane lists of different lengths' do
      words = Numo::Int32[1, 0, 3, 0, 0, -1, 1, 0, 0]
      expect {
        MB::Sound::FastPlan.run_lanes(words, [Numo::DFloat[0.0]], [[], []], [[], []], [[], []], Numo::SFloat.zeros(1), [Numo::SFloat.zeros(4)] * 2, 4)
      }.to raise_error(ArgumentError, /lane lists/)
    end

    it 'raises for too many lanes' do
      max = MB::Sound::FastPlan.enums[:max_lanes]
      n = max + 1
      words = Numo::Int32[1, 0, 3, 0, 0, -1, 1, 0, 0]
      expect {
        MB::Sound::FastPlan.run_lanes(words, [Numo::DFloat[0.0, 0.0]] * n, [[]] * n, [[]] * n, [[]] * n, Numo::SFloat.zeros(1), [Numo::SFloat.zeros(4)] * n, 4)
      }.to raise_error(ArgumentError, /lanes/)
    end
  end
end
