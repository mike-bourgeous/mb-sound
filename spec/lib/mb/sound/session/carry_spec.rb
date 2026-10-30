# Running state carried across a track's rebuild (sound-design-2,
# Session::Carry): a bind (or a build knob's turn) mid-note keeps the held
# notes in their voices with their phases, envelope stages and levels, and
# filter states; with every stateful node matched, the rebuilt graph plays
# the old one's samples bit for bit (the swap is a cut, on its exact frame
# at any buffer size); where the structure changed it crossfades over the
# declick time, still without restarting the note.
RSpec.describe(MB::Sound::Session::Carry, :aggregate_failures) do
  CARRY_LEAD = ->(c) { c.synth(voices: 2) { |v| v.hz.saw.lp4(1200.hz, resonance: 0.25) * v.amp_env(0.05, 0.2, 0.5, 0.3) } }

  # A held note across bar 2:1 (where rebuilds land), then a loop restart
  CARRY_CLIP = MB::Sound.seq(MB::Sound::E3.n2, MB::Sound::G3.n1).loop

  after { MB::Sound.rewind }

  # The same rebuild a bind makes, without binding.
  CARRY_REBUILD = ->(s, carry = true) {
    arr = s.arrangement
    tr = arr.tracks.values.first
    s.command('rebuild') { arr.send(:start_track, tr, tr.clip, arr.send(:resolve, tr.q || arr.quant, tr, MB::Sound::LaunchPoint::NONE), nil, carry: carry) }
  }

  # The mono mix of +track+ playing +patch+ (a block, or an instrument
  # name) from CARRY_CLIP, with +act+ run (in the Session's context) after the
  # first 3200 frames; 160000 frames in +size+-frame buffers.  Returns
  # [samples, Session#last_carry].
  def play(act = nil, patch: CARRY_LEAD, size: 800, frames: 160_000)
    MB::Sound.rewind
    MB::Sound.seed(1)
    out = MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: size)
    s = MB::Sound::Session.new(output: out, realtime: false, buffer_size: size)
    MB::Sound::Session.with_context(session: s) do
      patch.is_a?(Symbol) ? MB::Sound.track(:lead, patch) : MB::Sound.track(:lead, &patch)
      MB::Sound.bg(:lead, CARRY_CLIP)
    end
    s.process_buffer while s.frame < 3200
    MB::Sound::Session.with_context(session: s) { act.call(s) } if act
    s.process_buffer while s.frame < frames
    [Numo::DFloat.cast(out.captured[0])[0...frames], s.last_carry]
  ensure
    s&.close
  end

  CARRY_SWAP = 96_000 # (bar 2:1 at 120 BPM)

  def rms_db(x) = 20 * Math.log10(Math.sqrt((x**2).mean) + 1e-30)

  it 'carries a bound literal\'s rebuild mid-note: the same samples as no rebuild, bit for bit' do
    plain, = play
    bound, plan = play(->(_) { MB::Sound.bind(:lead, lp4: :resonance) })
    expect(plan).to be_full
    expect(plan.synths.length).to eq(1)
    expect(bound).to eq(plain)
    # (a fresh graph, as before carrying: the held note is gone until the next one)
    fresh, = play(->(s) { CARRY_REBUILD.(s, false) })
    expect(fresh[0...CARRY_SWAP]).to eq(plain[0...CARRY_SWAP])
    expect(rms_db(fresh[CARRY_SWAP...(CARRY_SWAP + 4800)]) - rms_db(plain[CARRY_SWAP...(CARRY_SWAP + 4800)])).to be < -20
  end

  it 'lands on its exact frame at any buffer size' do
    plain, = play(size: 367)
    carried, plan = play(->(s) { CARRY_REBUILD.(s) }, size: 367)
    expect(plan).to be_full
    expect(carried).to eq(plain)
  end

  it 'carries a mono synth with glide (dnb_reese) bit for bit' do
    plain, = play(patch: :dnb_reese)
    carried, plan = play(->(s) { CARRY_REBUILD.(s) }, patch: :dnb_reese)
    expect(plan).to be_full
    expect(carried).to eq(plain)
  end

  it 'keeps the held note where the structure changed (the init voice\'s sync turned on mid-note)' do
    plain, = play(patch: :init)
    synced, plan = play(->(_) { MB::Sound.turn(:"lead/sync", 1) }, patch: :init)
    # (OSC2 synced is the same tone with a sync input: every stateful node
    # has its partner, and the sync starts from the free tone's phase)
    expect(plan.matched).to eq(plan.stateful)
    expect(synced).not_to eq(plain)
    expect(synced[0...CARRY_SWAP]).to eq(plain[0...CARRY_SWAP])
    before = rms_db(plain[(CARRY_SWAP - 2400)...CARRY_SWAP])
    after = rms_db(synced[(CARRY_SWAP + 480)...(CARRY_SWAP + 2880)])
    expect(after - before).to be_within(4).of(0) # (the note plays on: no restart, no gap)
    # (no click: the swap's largest step between samples is the sound's own size)
    steps = (synced[(CARRY_SWAP - 480)...(CARRY_SWAP + 480)].diff).abs.max
    expect(steps).to be < 2 * plain[(CARRY_SWAP - 4800)...CARRY_SWAP].diff.abs.max
  end

  it 'crossfades a graph with memory it can\'t copy (a reverb), saying so' do
    _, plan = play(->(s) { CARRY_REBUILD.(s) }, patch: :dnb_pad, frames: 100_000)
    expect(plan.uncarried).to be >= 1
    expect(plan).not_to be_full
    expect(plan.to_s).to include('with memory that starts fresh (crossfaded)')
  end

  # (research-snapshot-mutability: multitap and ping_pong aren't GraphNodes,
  # so Carry counted them as carried and cut their echoes with no declick;
  # every node kind now declares its memory, NodeTraits)
  it 'crossfades a patch whose only memory is a multitap or a ping-pong' do
    [->(c) { CARRY_LEAD.(c).multitap(0.2, 0.35) }, ->(c) { CARRY_LEAD.(c).ping_pong(0.25, feedback: 0.5) }].each do |patch|
      plain, = play(patch: patch, frames: 100_000)
      carried, plan = play(->(s) { CARRY_REBUILD.(s) }, patch: patch, frames: 100_000)
      expect(plan).not_to be_full
      expect(plan.uncarried).to eq(1)
      expect(plan.matched).to eq(plan.stateful)
      # (no click: the swap's largest step between samples is the sound's own size)
      steps = carried[(CARRY_SWAP - 480)...(CARRY_SWAP + 480)].diff.abs.max
      expect(steps).to be < 2 * plain[(CARRY_SWAP - 4800)...CARRY_SWAP].diff.abs.max
    end
  end
end
