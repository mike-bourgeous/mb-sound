# Plan rebuilds when parts of a graph end (render-rebuild-1): how many
# rebuilds a song's end costs, and that every way of rebuilding gives the
# unplanned samples.
RSpec.describe('Plan rebuilds') do
  after { MB::Sound.rewind }

  # A Synth whose voices have three envelopes on one note stream and a sum
  # whose summands end (as fm_bass's lanes), inside a graph a Session
  # installs plans on too, over a clip that ends: when the stream is over
  # every lane's envelopes and envelope inputs leave the plans.
  def ending_song
    m = MB::Sound
    clip = m.seq(m::C3, m::E3, m::G3, m::C4, [m::E3, m::G3]).n8
    synth = m::Synth.new(clip, voices: 3) { |v|
      a = v.fm_env(0, 0.2, 0, 0.1)
      b = v.amp_env(0.001, 0.3, 0.5, 0.1)
      c = v.fm_env(0, 0.1, 0.3, 0.05)
      base = v.hz.glide(50.ms)
      (b * base.sine.pm(a * base.transpose(12).sine + c * base.sine)) * 0.2
    }
    [synth, synth.softclip(0.8, 0.95) + synth.delay(10.ms) * 0.3]
  end

  # Renders the song through an offline Session (+buffers+ buffers of
  # +count+ frames), returning the Synth, the Session's installation, and
  # the buffers.  +rebuilds+ sets Plan.rebuilds; +wait+ waits after each
  # buffer for rebuilds running on the worker thread to finish.  Counts
  # Installation#rebuild calls made while a buffer renders in
  # @render_rebuilds and keeps the Session's Plan::Deferral in @deferral.
  def render_song(plan, count: 128, buffers: 600, rebuilds: :inline, wait: false, &between)
    MB::Sound::Plan.enabled = plan
    old_rebuilds = MB::Sound::Plan.rebuilds
    MB::Sound::Plan.rebuilds = rebuilds
    MB::Sound.rewind
    @render_rebuilds = 0
    rendering = false
    allow_any_instance_of(MB::Sound::Plan::Installation).to receive(:rebuild).and_wrap_original do |m, *a, **k|
      @render_rebuilds += 1 if rendering
      m.call(*a, **k)
    end
    MB::Sound.with_seed(5) {
      synth, graph = ending_song
      session = MB::Sound::Session.new(realtime: false, buffer_size: count, output: MB::Sound::NullOutput.new(channels: 2, sleep: false, buffer_size: count))
      session.add(graph)
      out = Array.new(buffers) do |i|
        rendering = true
        buf = session.process_buffer(count).map(&:dup)
        rendering = false
        between&.call(i, synth, session)
        if wait && (d = session.plan_deferral_used)
          deadline = MB::U.clock_now + 5
          sleep 0.001 until d.idle? || MB::U.clock_now > deadline
        end
        buf
      end
      outer = plan ? MB::Sound::Plan.watch[synth].keys.reject { |i| synth.plans.include?(i) }.first : nil
      @deferral = session.plan_deferral_used
      session.close
      [synth, outer, out]
    }
  ensure
    MB::Sound::Plan.enabled = true
    MB::Sound::Plan.rebuilds = old_rebuilds if old_rebuilds
  end

  def binaries(out)
    out.map { |b| b.map(&:to_binary) }
  end

  it 'gives the unplanned samples when every lane\'s envelopes end' do
    _, _, planned = render_song(true)
    _, _, unplanned = render_song(false)
    expect(binaries(planned)).to eq(binaries(unplanned))
  end

  it 'leaves out every feeder of a region whose stream is over in one rebuild' do
    # The three envelopes of a lane read one stream, so they finish in the
    # same block; they were found one block at a time (each block unfused
    # and each a rebuild of the lane: 5 rebuilds of some lanes here, up to
    # 4 per lane per buffer in fm_bass)
    synth, _, _ = render_song(true)
    lanes = synth.plans.compact
    expect(lanes.length).to eq(synth.lanes.length)
    expect(lanes.map(&:rebuilds).max).to be <= 3
  end

  it 'never plans a node another installation left out' do
    # The Session's installation reaches the lanes' nodes through the
    # Synth; it took over the nodes the lanes left out (45 here), then
    # rebuilt its whole graph for each one as it ended in turn (18 of
    # fm_bass's rebuilds, up to 9 in one buffer)
    synth, outer, _ = render_song(true)
    expect(outer).not_to be_nil
    left_out = synth.plans.compact.flat_map { |i| i.excluded.keys }
    expect(left_out.length).to be > 30
    claimed = outer.regions.flat_map(&:members).select { |m| left_out.any? { |n| n.equal?(m) } }
    expect(claimed).to be_empty
    expect(outer.candidate_reason(left_out.first)).to start_with('left out by another installation')
  end

  describe 'deferred to a block boundary (Plan.rebuilds)' do
    it 'rebuilds nothing while a buffer renders, holding the changed regions unfused (:next_span)' do
      synth, _, planned = render_song(true, rebuilds: :next_span)
      expect(@render_rebuilds).to eq(0)
      expect(@deferral.mode).to eq(:next_span)
      expect(@deferral.adopted).to be > 5
      expect(@deferral.dropped).to eq(0)
      # Every lane's plans followed the stream's end
      lanes = synth.plans.compact
      expect(lanes.map(&:rebuilds).min).to be >= 2
      expect(lanes.map(&:job)).to all(be_nil)
      expect(lanes.map(&:stale_here?)).to all(eq(false))
      _, _, unplanned = render_song(false)
      expect(binaries(planned)).to eq(binaries(unplanned))
    end

    it 'builds on the worker thread and swaps the plans in between buffers (:background)' do
      _, _, planned = render_song(true, rebuilds: :background, wait: true)
      expect(@render_rebuilds).to eq(0)
      expect(@deferral.mode).to eq(:thread)
      expect(@deferral.adopted).to be > 5
      expect(@deferral.seconds).to be > 0
      expect(MB::Sound::Plan::Worker.thread.name).to eq('MB::Sound::Plan rebuilds')
      _, _, unplanned = render_song(false)
      expect(binaries(planned)).to eq(binaries(unplanned))
    end

    it 'gives the same samples wherever the builds land (:background without waiting)' do
      # (The worker gets the render lock only between buffers here, so the
      # builds land after varying numbers of buffers)
      _, _, planned = render_song(true, rebuilds: :background)
      expect(@render_rebuilds).to eq(0)
      _, _, unplanned = render_song(false)
      expect(binaries(planned)).to eq(binaries(unplanned))
    end

    it 'drops a build a structural change overtook, and builds again' do
      # A structural change between the build's start (in the span that
      # changed the plans) and the next span, where it would land
      changed = false
      between = lambda do |_i, synth, _session|
        lane = synth.plans.compact.find(&:job)
        next if changed || lane.nil?

        MB::Sound::Plan.changed(lane.roots[0])
        changed = true
      end
      _, _, planned = render_song(true, rebuilds: :next_span, &between)
      expect(changed).to eq(true)
      expect(@deferral.dropped).to be >= 1
      expect(@render_rebuilds).to eq(0)
      _, _, unplanned = render_song(false)
      expect(binaries(planned)).to eq(binaries(unplanned))
    end
  end

  describe 'regions kept by a rebuild' do
    it 'keeps the compiled programs of regions whose nodes didn\'t change' do
      # A sum whose left summand ends (the sum drops it and rebuilds), and
      # a right summand read by a second output too (so it is a region of
      # its own), which keeps its program
      a = PlanSpecHelpers::Source.new(seed: 1, ends_at: 300)
      b = PlanSpecHelpers::Source.new(seed: 2)
      right = (b * 0.25).softclip(0.5, 0.9)
      g = (a * 0.5).softclip(0.5, 0.9) + right
      g2 = right * 2
      inst = MB::Sound::Plan.install(g, g2)
      kept = inst.regions.find { |r| r.root.equal?(right) }
      expect(kept).not_to be_nil
      prog = kept.program || kept.compile
      expect(prog).not_to be_nil
      8.times { g.sample(100); g2.sample(100) }
      expect(inst.rebuilds).to be >= 1
      expect(inst.regions).to include(kept)
      expect(kept.program).to equal(prog)
    end
  end
end
