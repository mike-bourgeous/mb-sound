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
      saw = v.amp_env * base.saw.pm(e * mod + v.bend) * 0.1
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

  it 'splits more same-shape regions than run_lanes takes into groups of at most 64' do
    MB::Sound::Plan.lanes = true
    MB::Sound.seed(0)
    s = MB::Sound.synth('spec/test_data/c_major.mid', voices: 70, spares: 0, skip_idle: false) { |v| v.hz.saw.filter(:lowpass, cutoff: 1000) * v.amp_env }
    20.times { expect(s.sample(128)).not_to be_nil }
    sizes = s.lane_groups.groups.map { |g| g.members.length }
    expect(sizes.max).to be <= MB::Sound::Plan::LaneGroup::MAX_LANES
    expect(sizes.sum).to eq(70)
  end

  it "doesn't group lanes with unfused work of their own (idle lanes keep being skipped)" do
    MB::Sound::Plan.lanes = true
    MB::Sound.seed(0)
    s = MB::Sound.synth('spec/test_data/c_major.mid', voices: 4) { |v| (v.hz.saw * v.amp_env).proc { |x| x } }
    expect(s.lane_groups).to be_nil
    expect(s.skippable_lanes).not_to be_empty
  end

  it 'groups lanes that are never skipped anyway (long-memory nodes) even with unfused work' do
    MB::Sound::Plan.lanes = true
    MB::Sound.seed(0)
    s = MB::Sound.synth('spec/test_data/c_major.mid', voices: 3) { |v|
      (v.hz.saw.filter(:lowpass, cutoff: 900) * v.amp_env).proc { |x| x }.delay(0.001) * 0.5
    }
    expect(s.skippable_lanes).to be_empty
    expect(s.lane_groups&.groups.to_a).not_to be_empty
  end

  it "keeps each member's last block intact for its Tee until it reads again", :check_shared do
    # The group writes every member's next block when the first member is
    # read; members' outputs shared by Tees (frozen frames) must not change
    # before their own readers ask (Region#swap_out!)
    build = ->(lanes) {
      MB::Sound::Plan.lanes = lanes
      MB::Sound.seed(0)
      MB::Sound.synth('spec/test_data/dense_modulated.mid', voices: 3, spares: 1) { |v|
        f = v.freq
        (f.tone.saw * v.amp_env).proc { |x| x } * 0.1 + (f / 1000.constant).delay(0.001) * 0.01
      }
    }
    s = build.(true)
    expect(s.lane_groups.groups).not_to be_empty
    a = render(s, sizes.first(20))
    b = render(build.(false), sizes.first(20))
    expect(a).to eq(b)
  end

  # omnibus12: whether a lane may be skipped while idle depends only on its
  # node types (Synth#lane_fusable?), never on the plans, since skipping
  # changes the samples (a key-synced saw's reset step from a paused phase)
  it 'never skips fusable lanes, with lane groups off or plans off too' do
    old = MB::Sound::Plan.enabled
    [[true, false], [false, true]].each do |enabled, lanes|
      MB::Sound::Plan.enabled = enabled
      MB::Sound::Plan.lanes = lanes
      MB::Sound.seed(0)
      s = MB::Sound.synth('spec/test_data/c_major.mid', voices: 4) { |v| v.hz.saw.filter(:lowpass, cutoff: 1000) * v.amp_env }
      expect(s.lane_groups).to be_nil
      expect(s.skippable_lanes).to be_empty
    end
  ensure
    MB::Sound::Plan.enabled = old
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
      chans = [110, 165].map { |f| f.hz.saw.pm(src_wave(f) * 0.2).filter(:lowpass, cutoff: lfo, quality: 2).lp4(1500, resonance: 0.3) * 0.4 }
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

    it "doesn't group regions inside a graph (a drum kit's voices push buffers to their subgraphs)" do
      kit = ->(lanes) {
        MB::Sound::Plan.lanes = lanes
        MB::Sound.seed(0)
        k = MB::Sound.tr808(MB::Sound.grid(16, bd: 'x.x.x...', lt: '..x...x.', mt: '.x...x..', ht: 'x...x...'))
        MB::Sound::Plan.install(k)
        k
      }
      a = kit.(true)
      b = kit.(false)
      sizes.first(20).each { |n| expect(a.sample(n).to_a).to eq(b.sample(n).to_a) }
    end

    # A stereo voice: both channels read one envelope (its own region
    # through a Tee), and their regions are grouped.  When the MIDI file
    # ends, the envelope's feeder leaves the plan in the middle of a group
    # run, replacing the second channel's region; that channel used to get
    # nil (ending the lane mid-release, so the envelope never went idle and
    # Synth#ended? stayed false: the patches-1 ring-out bug).
    it 'keeps a member replaced in the middle of a run going (a stereo lane whose envelope stream ends)' do
      old = MB::Sound::Plan.enabled
      run = ->(planned) {
        MB::Sound::Plan.enabled = planned
        MB::Sound::Plan.lanes = true
        MB::Sound.seed(0)
        notes = MB::Sound::Notes.new('spec/test_data/c_major.mid')
        g = MB::Sound.synth(notes, voices: 1) { |v|
          s = v.hz.unison(3, detune: 0.3, spread: 0.5) { |p, _| p.saw }
          s.lp4(2400 * 2 ** v.lfo(2.bars, shape: :sine, depth: 0.8), resonance: 0.25) * v.env(0.004, 0.25, 0.85, 0.06, gm: false)
        }
        syn = g.graph.grep(MB::Sound::Synth).first
        out = []
        ended_at = nil
        sizes = PlanSpecHelpers.sizes_for(samples: 48000 * 8)
        sizes.each_with_index do |n, i|
          bufs = g.outputs.map { |o| o.sample(n) }
          break if bufs.any?(&:nil?)

          out << bufs.map(&:to_a)
          ended_at ||= i if syn.ended?
        end
        [out, ended_at]
      }

      a, a_end = run.(true)
      b, b_end = run.(false)
      expect(b_end).not_to be_nil
      expect(a_end).to eq(b_end)
      expect(a.length).to eq(b.length)
      a.each_with_index { |bl, i| expect(bl).to eq(b[i]), "block #{i} differs" }
    ensure
      MB::Sound::Plan.enabled = old
    end

    # fixes-8: an unread `band * 0.5` makes each lane's band its own region
    # (made outside the voice block since fixes-9).
    # When the stream ends, a lane's envelope leaves the plan in the middle
    # of a group run and its fallback reads its band region, which rebuilds
    # the lane's installation; the root's hook then pointed at a new region
    # after the group had computed the lane's block, so the Synth's read
    # computed it again (noise advanced twice, the last lane changed and
    # the synth ended a buffer early).  The group hands the block over.
    it 'hands a block computed before a rebuild to the replaced region' do
      run = ->(lanes) {
        MB::Sound::Plan.lanes = lanes
        MB::Sound.seed(5)
        notes = MB::Sound::MIDI::Stream.new(MIDIListSource.new(*[[50, 0.05, 0.5], [55, 0.1, 0.4], [57, 0.6, 0.9]].flat_map { |n, on, off|
          [MB::Sound::MIDI::Event.note_on(n, 0.8, time: on.to_r), MB::Sound::MIDI::Event.note_off(n, time: off.to_r)]
        }))
        bands = []
        s = MB::Sound.synth(notes, voices: 2, skip_idle: false) { |v|
          band = MB::Sound.noise.filter(:lowpass, cutoff: 3000, quality: 1.5)
          bands << band
          band * v.env(0.1, 0.2, 0.5, 0.1, gm: false)
        }
        # Never read, but made outside the voice block, so they count as
        # readers (fixes-9: unread branches made in the block don't)
        _outside = bands.map { |b| b * 0.5 }
        [render(s, [800] * 80), s]
      }
      a, s = run.(true)
      b, _ = run.(false)
      expect(s.lane_groups.groups.sum(&:lane_runs)).to be > 0
      expect(a.length).to be > 48000
      expect(a).to eq(b)
    end

    # fixes-9: the plans counted unread branches made in the voice block
    # as readers, so each lane's band became its own region.  With a spy on
    # lane 0's band (a bus tap's `only:`), lane 0's region differed from
    # lane 1's, so lane 0 stayed ungrouped and slept while idle (its noise
    # paused); with the unread nodes every lane's band region grouped and
    # ran every buffer (max difference 0.81 at a peak of 0.54), and the
    # unread `mod * 2` stopped the controller's sharing.  Plans now treat
    # those branches as absent (Installation#live_branches).  (Since
    # omnibus12 fusable lanes are never skipped, so grouping no longer
    # changes skipping either: both lanes group, spied or not.)
    it 'fuses, groups, shares, and skips as if unread voice nodes were not there' do
      ev = MB::Sound::MIDI::Event
      run = ->(extra) {
        MB::Sound::Plan.lanes = true
        MB::Sound.seed(5)
        src = MB::Sound::MIDI::Stream.new(MIDIListSource.new(
          ev.note_on(50, 0.8, time: 0.05r), ev.note_off(50, time: 0.3r), ev.note_on(50, 0.8, time: 2.0r), ev.note_off(50, time: 2.2r)
        ))
        bands = []
        s = MB::Sound.synth(src, voices: 2) { |v|
          band = MB::Sound.noise.filter(:bandpass, cutoff: 3000, quality: 1.5)
          bands << band
          mod = v.mod
          if extra
            _unread = band * 0.5 # never read
            _unread_mod = mod * 2
          end
          band * v.env(0.01, 0.1, 0.5, 0.1, gm: false) * (mod + 1)
        }
        taps = []
        bands[0].spy { |d| taps << d.dup if d }
        skipped = []
        out = 150.times.map { b = s.sample(800).dup; skipped << s.skipped_lanes.dup; b }
        [
          SpecBuffers.join(out), SpecBuffers.join(taps), s.skippable_lanes, skipped,
          s.lane_groups.groups.map { |g| g.members.length }, s.shared_inputs.sources.length,
        ]
      }

      a = run.(false)
      b = run.(true)
      expect(a[0].abs.max).to be > 0.3
      expect(a[2]).to eq([])
      expect(a[3].flatten).to be_empty
      expect(a[4]).to eq([3]) # (two voices and a spare)
      expect(a[5]).to eq(1)
      expect(b[2..]).to eq(a[2..])
      expect(b[0]).to eq(a[0])
      expect(b[1]).to eq(a[1])
    end

    # fuzz-fixes-1 (the relation fuzzer's find): two same-shape per-channel
    # regions read the outputs of one pan region.  In the first block the
    # sum's ended input rebuilds the installation in the middle of the
    # group's run, after the left channel was delivered; the right channel's
    # read ran the new group, which computed the left channel's next block
    # early, reading the pan's left output again, so the pan computed a new
    # frame and the right channel got it a block early (off by 0.5 from
    # sample 0, C and Ruby mirror alike).  The new group now leaves out
    # members delivered in the block still in progress.
    [:c, :ruby].each do |engine|
      it "leaves a member delivered before a rebuild out of the new group's block (#{engine})" do
        trig = -> { MB::Sound.seq(MB::Sound::C4.n64, MB::Sound::E4.n64).loop.notes.trigger }
        build = -> {
          MB::Sound.rewind
          (220.hz.saw.at(0.5) + 0.1.constant.until(400.samples)).pan(0.076).sample_hold(MB::Sound.stereo(trig.(), trig.()))
        }
        old = [MB::Sound::Plan.engine, MB::Sound::Plan.enabled]
        MB::Sound::Plan.lanes = true
        MB::Sound::Plan.engine = engine
        MB::Sound::Plan.enabled = false
        ref = (g = build.(); 6.times.map { g.outputs.map { |o| o.sample(800).to_a } })
        MB::Sound::Plan.enabled = true
        g = build.()
        inst = MB::Sound::Plan.install(g)
        got = 6.times.map { g.outputs.map { |o| o.sample(800).to_a } }
        expect(got[0][1][0]).to be_within(1e-6).of(0.1 * Math.sin(1.076 * Math::PI / 4))
        expect(got).to eq(ref)
        expect(inst.lane_groups.groups.sum(&:lane_runs)).to be > 0 if engine == :c
      ensure
        MB::Sound::Plan.engine, MB::Sound::Plan.enabled = old
        MB::Sound.rewind
      end
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

  describe 'x and x * c as one shape (ScaleMatch)' do
    # stereo_drone's shape: a shared node read plainly on the left and
    # inverted on the right
    def drone(lanes)
      MB::Sound::Plan.lanes = lanes
      MB::Sound.seed(3)
      n = (1.hz.noise.at(0.1) * 0.5).filter(:lowpass, cutoff: 800, quality: 2)
      m = 2.hz.lfo.at(0.2..0.4)
      b = MB::Sound::GraphNode::Channels.new([
        (220.hz.saw * m + n).softclip(0.6),
        (330.hz.saw * (m * 0.5) + n * -1 * 0.5).softclip(0.6),
      ])
      [b, MB::Sound::Plan.install(b)]
    end

    it 'pads the plain channel with x * 1 so both channels run together, bit for bit' do
      a, inst = drone(true)
      b, _ = drone(false)
      sizes.each { |n| expect(a.outputs.map { |o| o.sample(n).to_binary }).to eq(b.outputs.map { |o| o.sample(n).to_binary }) }
      groups = inst.lane_groups.groups
      expect(groups.map { |g| g.members.length }).to eq([2])
      expect(groups[0].lane_runs).to eq(2 * sizes.length)
      padded = groups[0].members.find(&:pads)
      expect(padded.pads.values.sum).to eq(3) # m * 1, and n * 1 * 1
      expect(groups[0].members.map { |r| r.program.signature }.uniq.length).to eq(1)
    end

    it 'keeps the pads stable across a regroup' do
      a, inst = drone(true)
      a.outputs.each { |o| o.sample(64) }
      inst.stale!
      3.times { a.outputs.each { |o| o.sample(64) } }
      expect(inst.lane_groups.groups.map { |g| g.members.length }).to eq([2])
      g = inst.lane_groups.groups[0]
      expect(g.members.map { |r| r.program.signature }.uniq.length).to eq(1)
      expect(g.members.map { |r| r.pads&.values&.sum.to_i }.sort).to eq([0, 3])
    end

    it "doesn't pad gains on complex values (x * 1 isn't exact for complex infinities)" do
      prog = ->(g) { MB::Sound::Plan::ScaleMatch.core(MB::Sound::Plan::Installation.new([g], engine: :c, check: nil).build.regions[0].compile(start: false)) }
      c = 220.hz.complex_sine
      _, sites = prog.((c * 2).real + 1.hz.saw)
      expect(sites).to be_empty
    end
  end

  describe 'with resamplers' do
    it 'groups regions of one shape in an installation with resamplers only across installations' do
      # Regions inside and outside a resampler may run at different counts
      MB::Sound.seed(0)
      chans = [1, 2].map { |i| (PlanSpecHelpers::Source.new(seed: i) * 0.5).filter(:lowpass, cutoff: 900) * 2 }
      chans << PlanSpecHelpers::Source.new(seed: 3).resample(24000) * 0.5
      inst = MB::Sound::Plan.install(MB::Sound::GraphNode::Channels.new(chans))
      expect(inst.resamples?).to eq(true)
      shapes = inst.regions.map { |r| r.program.signature }
      expect(shapes.length).to be > shapes.uniq.length
      expect(inst.lane_groups.groups).to be_empty
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
