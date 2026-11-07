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
  def play(act = nil, patch: CARRY_LEAD, size: 800, frames: 160_000, after: nil)
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
    after&.call(s)
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

  # Two rebuilds queued for one launch point (editability-1: two binds
  # before the bar landed only the first; the second was planned against
  # the graph the first replaces, and Session#add_now drops a rebuild whose
  # graph is gone): the second follows the first, carrying from it.
  it 'lands both of two rebuilds queued for one launch point, carrying through both bit for bit' do
    plain, = play
    knobs = nil
    both, plan = play(->(s) {
      MB::Sound.bind(:lead, lp4: :resonance)
      s.process_buffer
      MB::Sound.bind(:lead, amp_env: :release)
    }, after: ->(s) {
      knobs = s.ui_graphs[:lead].graph.grep(MB::Sound::GraphNode::Knob::Reader).map { |r| r.knob.name }.uniq.sort
    })
    expect(knobs).to eq(%i[lead/release lead/resonance])
    expect(plan).to be_full
    expect(both).to eq(plain)

    # The second queued for a later launch point: it follows the first,
    # carrying from the graph the first started (bar 2:1, then 2:3)
    landed = nil
    later, plan = play(->(s) {
      MB::Sound.bind(:lead, lp4: :resonance)
      arr = s.arrangement
      tr = arr.tracks[:lead]
      s.command('rebuild') { arr.send(:start_track, tr, tr.clip, 3/2r, nil, carry: true, spill: true) }
    }, after: ->(s) { landed = s.journal.changes.select { |e| e.subject == :lead && e.kind == :bg }.map { |e| [e.status, e.lands.to_s] } })
    expect(landed.last(2)).to eq([[:landed, '2:1'], [:landed, '2:3']])
    expect(plan).to be_full
    expect(later).to eq(plain)
  end

  it 'lands on its exact frame at any buffer size' do
    plain, = play(size: 367)
    carried, plan = play(->(s) { CARRY_REBUILD.(s) }, size: 367)
    expect(plan).to be_full
    expect(carried).to eq(plain)
  end

  # (carry-1: a swap between samples split the buffer on the sample after
  # its time, so the state was copied a piece before the old graph stopped;
  # it splits on the floor sample, where the new graph starts)
  it 'lands between samples (137.5 BPM) bit for bit at any buffer size' do
    [800, *SlowTier.slow_tier([367])].each do |size|
      r = CarryCheck.compare(CARRY_LEAD, clip: CARRY_CLIP, size: size, frames: 120_000, bpm: 137.5)
      expect(r.plan).to be_full
      expect(r).to be_exact, "#{size}: #{r}"
    end
  end

  # (carry-1: a rebuild started a one-shot clip again from its start, and a
  # seek back before the rebuild left the new graph waiting for its start)
  it 'plays a one-shot clip on from its place, also after a seek back before the rebuild' do
    clip = MB::Sound.seq(MB::Sound::C3.n2, MB::Sound::E3.n2, MB::Sound::G3.n1, MB::Sound::C4.n1)
    r = CarryCheck.compare(CARRY_LEAD, clip: clip, frames: 150_000)
    expect(r.plan).to be_full
    expect(r).to be_exact, r.to_s
    seek = ->(s) { CARRY_REBUILD.(s); MB::Sound.at_bar(2, beat: 3) { MB::Sound.seek(1, 3) } }
    plain, = CarryCheck.play(CARRY_LEAD, clip: clip, act: ->(s) { MB::Sound.at_bar(2, beat: 3) { MB::Sound.seek(1, 3) } }, frames: 150_000)
    carried, plan = CarryCheck.play(CARRY_LEAD, clip: clip, act: seek, frames: 150_000)
    expect(plan).to be_full
    expect(carried).to eq(plain)
  end

  # (the maintainer, 2026-10-31: "Next buffer in sound design only";
  # 2026-10-30: "Immediately or within 1 beat if working on sound design")
  describe 'timing in sound design' do
    # The frame where the rebuild +act+ (run after 3200 frames) swapped,
    # in a Session playing CARRY_LEAD, designing it if +design+.
    def swap_frame(act, design:)
      MB::Sound.rewind
      out = MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: 800)
      s = MB::Sound::Session.new(output: out, realtime: false)
      MB::Sound::Session.with_context(session: s) do
        MB::Sound.track(:lead, &CARRY_LEAD)
        MB::Sound.bg(:lead, CARRY_CLIP)
        s.process_buffer while s.frame < 3200
        MB::Sound::UI::Design.open(:lead) if design
        act.call(s)
        s.process_buffer while s.frame < 100_000 && s.last_carry.nil?
        entry = s.journal.entries.reverse.find { |e| e.kind == :bg && e.subject == :lead }
        [entry.lands.frame, s.last_carry]
      end
    ensure
      MB::Sound::UI::Design.close if design
      s&.close
    end

    it 'lands a fully carried bind on the next buffer while the track is designed, else at its launch point' do
      bind = ->(_) { MB::Sound.bind(:lead, lp4: :resonance) }
      frame, plan = swap_frame(bind, design: true)
      expect(plan).to be_full
      expect(frame).to eq(3200) # (the next buffer)
      frame, = swap_frame(bind, design: false)
      expect(frame).to eq(CARRY_SWAP)
    end

    it 'lands a rebuild that crossfades or spills on the next beat while the track is designed' do
      redefine = ->(_) { MB::Sound.track(:lead) { |c| CARRY_LEAD.(c).oversample(2) } }
      frame, plan = swap_frame(redefine, design: true)
      expect(plan).not_to be_full
      expect(frame).to eq(24_000) # (beat 2)
    end
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

  it 'crossfades a graph with memory it can\'t move (a resampler), saying so' do
    patch = ->(c) { CARRY_LEAD.(c).oversample(2) }
    _, plan = play(->(s) { CARRY_REBUILD.(s) }, patch: patch, frames: 100_000)
    expect(plan.uncarried).to be >= 1
    expect(plan).not_to be_full
    expect(plan.to_s).to include('with memory that starts fresh (crossfaded)')
  end

  # (research-snapshot-mutability: multitap and ping_pong weren't
  # GraphNodes, so Carry counted them as carried and cut their echoes with
  # no declick; every node kind declares its memory, NodeTraits, and since
  # carry-1 delays, reverbs, choruses, and formants adopt their partners'
  # state: the cut keeps the echoes)
  it 'carries a multitap or a ping-pong\'s echoes bit for bit' do
    [->(c) { CARRY_LEAD.(c).multitap(0.2, 0.35) }, ->(c) { CARRY_LEAD.(c).ping_pong(0.25, feedback: 0.5) }].each do |patch|
      plain, = play(patch: patch, frames: 100_000)
      carried, plan = play(->(s) { CARRY_REBUILD.(s) }, patch: patch, frames: 100_000)
      expect(plan).to be_full
      expect(plan.adopts.map { |_, n| n.class }).to include(MB::Sound::GraphNode::MultitapDelay).or include(MB::Sound::GraphNode::DelayNetwork)
      expect(carried).to eq(plain)
    end
  end

  # (fix-batch-1101, SessionFuzz seed 768044: the rebuilt Synth took the
  # old one's lane frame count but not its output's, so its end, found in
  # the first, cut the second 96000 frames late: the track's player stayed
  # current, and a later scene launch built the patch again instead of
  # swapping its clip)
  it "ends a rebuilt synth's one-shot clip on the frame it ends without the rebuild" do
    clip = MB::Sound.seq(MB::Sound::C3.n2, MB::Sound::E3.n2, MB::Sound::G3.n1)
    ends = [nil, CARRY_REBUILD].map do |act|
      MB::Sound.rewind
      MB::Sound.seed(1)
      s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false, buffer_size: 800)
      MB::Sound::Session.with_context(session: s) do
        MB::Sound.track(:lead, &CARRY_LEAD)
        MB::Sound.bg(:lead, clip)
      end
      s.process_buffer while s.frame < 3200
      MB::Sound::Session.with_context(session: s) { act.call(s) } if act
      s.process_buffer while s.frame < 300_000 && !s.idle?
      expect(s.last_carry).to be_full if act
      s.sound_end_frame
    ensure
      s&.close
    end
    expect(ends[0]).to be_between(192_000, 230_000)
    expect(ends[1]).to eq(ends[0])

    # (a Synth's frame counts of its own time go over together, or its
    # times disagree: every *_position it has is in SYNTH_STATE)
    synth = MB::Sound.seq(MB::Sound::C3).n4.synth { |v| v.hz.sine * v.amp_env(0.01, 0.1, 0.5, 0.1) }
    positions = synth.instance_variables.grep(/position\z/)
    expect(positions).to include(:@skip_position, :@out_position)
    expect(positions - MB::Sound::Session::Carry::SYNTH_STATE).to eq([])
  end

  # (ux-notes-1, the maintainer's note of 2026-10-31: "now the clip is
  # playing at double speed": his patch redefinition read the clip in two
  # places, `it.tone ... cutoff: it.hz + 150`, after one; the new clip
  # sources didn't pair with the old one, so they played the clip the graph
  # was first built for, `design`'s half notes, instead of the whole notes
  # swapped in since)
  it 'plays the swapped-in clip after a redefinition that reads the clip in more places' do
    first = MB::Sound.seq(MB::Sound::C3).n2.loop
    later = MB::Sound.seq(MB::Sound::C2, MB::Sound::C4, MB::Sound::G2, MB::Sound::G3).n1.loop
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false, buffer_size: 800)
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.track(:growl) { |c| c.tone.ramp.at(-10.db) }
      MB::Sound.bg(:growl, first)
    end
    s.process_buffer while s.frame < 48_000
    MB::Sound::Session.with_context(session: s) { MB::Sound.swap(:growl, later) }
    s.process_buffer while s.frame < 48_000 * 3
    # (c.freq: since ux-notes-2, `c.hz + 150` warns that it adds 150 to a
    # sine; both read the clip in a second place)
    MB::Sound::Session.with_context(session: s) { MB::Sound.track(:growl) { |c| c.tone.ramp.at(-10.db).filter(:bp4, cutoff: c.freq + 150, resonance: 0.4) } }
    s.process_buffer while s.frame < 48_000 * 7
    input = s.ui_graphs.fetch(:growl)
    sources = MB::Sound::Session::Carry.graph_nodes(input.instance_variable_get(:@nodes)).grep(MB::Sound::MIDI::ClipSource)
    expect(sources.length).to eq(2)
    expect(sources.map(&:clip)).to all(equal(later))
  ensure
    s&.close
  end

  # (fix-fuzz-1107: a carrying rebuild's player goes on as the one it
  # replaced from the swap frame, but hasn't played a frame until the next
  # render; events landing on that frame that asked whether a name's player
  # had started saw none, so a level cut instead of gliding (SessionFuzz
  # seed 327738), a cue launch dropped the rebuilt player instead of fading
  # it, and an instrument change cut it instead of spilling it.  Every
  # decision about what was heard reads Player#heard?; +started+ is read
  # only by the render mechanics listed here, each with why the carried
  # player's own state is the right one there.)
  STARTED_READS = {
    ['session.rb', 'render_span'] => 'a seek restarts the graphs that played; a carried one jumps at its own start (ClipSource#carry_seeked)',
    ['session.rb', 'render_player'] => "starting a graph's timeline nodes, and the clock wait of one that played",
    ['strip.rb', 'catch_up_waiting'] => 'graphs whose input nothing has read yet',
    ['strip.rb', 'read_kept_graphs'] => 'graphs read by their own player',
  }.freeze

  it 'reads what was heard of a player through Player#heard?, and +started+ only in the render mechanics' do
    root = File.expand_path('../../../../../lib/mb/sound', __dir__)
    reads = Hash.new(0)
    [File.join(root, 'session.rb'), *Dir[File.join(root, 'session', '*.rb')]].each do |f|
      method = nil
      File.foreach(f) do |line|
        next if line.match?(/\A\s*#/)

        method = line[/\A\s*def (?:self\.)?([\w?!=]+)/, 1] || method
        # (players are p, o, q, player, old, or np; chains, read through
        # c, chain, or x, have a +started+ of their own)
        line.scan(/(?<![\w.])(?:p|o|q|player|old|np)\.started(?![\w?!]|\s*=[^=])/) { reads[[File.basename(f), method]] += 1 }
      end
    end
    expect(reads.keys.sort).to eq(STARTED_READS.keys.sort)
    expect(MB::Sound::Session::Player.new(started: nil, carried: [0, 0, 0]).heard?).to eq(true)
    expect(MB::Sound::Session::Player.new(started: true).heard?).to eq(true)
    expect(MB::Sound::Session::Player.new.heard?).to eq(false)
  end
end
