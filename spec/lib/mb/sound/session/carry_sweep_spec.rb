# The carry sweep (sound-design-2): every shipped instrument preset, played
# on a track and rebuilt mid-note with its running state carried
# (Session::Carry, what a bind or a build knob's turn does), plays the
# samples it played without the rebuild, bit for bit, when every stateful
# node matched (and nothing with uncopied memory, such as a reverb, is in
# it); the others crossfade and keep sounding.  Presets after the first few
# are in the slow tier (SLOW=1).
RSpec.describe('Session::Carry over the shipped presets', :aggregate_failures) do
  after { MB::Sound.rewind }

  SWEEP_PRESETS = MB::Sound::Library.index.entries(kind: :instrument).select { |e| e.location.to_s.include?('/presets/') }.map(&:name).sort
  SWEEP_NOTES = MB::Sound.seq(MB::Sound::C3.n2, MB::Sound::E3.n1).loop
  SWEEP_DRUMS = MB::Sound.seq(*(35..81).map { |k| MB::Sound::Note.new(k) }).n16.loop # (every GM drum note: any kit's voices)
  SWEEP_REBUILD = ->(s) {
    arr = s.arrangement
    tr = arr.tracks.values.first
    s.command('rebuild') { arr.send(:start_track, tr, tr.clip, arr.send(:resolve, tr.q || arr.quant, tr, MB::Sound::LaunchPoint::NONE), nil, carry: true) }
  }
  SWEEP_SWAP = 96_000

  def play(name, clip, rebuild)
    MB::Sound.rewind
    MB::Sound.seed(1)
    out = MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: 800)
    s = MB::Sound::Session.new(output: out, realtime: false)
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.track(:lead, name)
      MB::Sound.bg(:lead, clip)
    end
    4.times { s.process_buffer }
    MB::Sound::Session.with_context(session: s) { SWEEP_REBUILD.(s) } if rebuild
    150.times { s.process_buffer }
    [Numo::DFloat.cast(out.captured[0]), s.last_carry]
  ensure
    s&.close
  end

  def drums?(name)
    MB::Sound.keeping_random_state { MB::Sound.preset(name, midi: SWEEP_NOTES) }
    false
  rescue MB::Sound::GraphIO::LoadError => e
    raise unless e.message.include?('SourceMismatch')
    true
  end

  it 'sweeps the shipped instrument presets' do
    expect(SWEEP_PRESETS).to include(:init, :dnb_reese, :tine_piano)
  end

  [:init, :dnb_reese, :square_bass, *SlowTier.slow_tier(SWEEP_PRESETS - %i[init dnb_reese square_bass], keep: 0)].each do |name|
    it "carries #{name} across a rebuild" do
      clip = drums?(name) ? SWEEP_DRUMS : SWEEP_NOTES
      plain, = play(name, clip, false)
      carried, plan = play(name, clip, true)
      expect(plan).not_to be_nil
      expect(carried[0...SWEEP_SWAP]).to eq(plain[0...SWEEP_SWAP])
      if plan.full?
        expect(carried).to eq(plain), "#{name} (#{plan}): #{(carried - plain).abs.max}"
      else
        # (crossfaded: what starts fresh is a tail, a reverb's or a delay's
        # or a kit voice's idle state; the voices play on)
        expect(plan.uncarried).to be > 0
        expect(plan.matched).to eq(plan.stateful), "#{name} (#{plan})"
        expect(carried.isnan.count_true).to eq(0)
      end
    end
  end

  # Effects after a voice, each with state no carry copies yet (NodeTraits'
  # carry :fresh): the swap must crossfade, never cut.  Multi-output effects
  # (multitap, ping_pong) once counted as fully carried because they aren't
  # GraphNodes, so their echoes stopped on a hard cut (research-snapshot-
  # mutability); a new effect kind belongs in this list.
  SWEEP_VOICE = ->(c) { c.synth(voices: 2) { |v| v.hz.saw.lp4(1500.hz, resonance: 0.2) * v.amp_env(0.01, 0.2, 0.6, 0.3) } }
  SWEEP_EFFECTS = {
    multitap: ->(x) { x.multitap(0.2, 0.35) },
    multitap_feedback: ->(x) { x.multitap(0.2, 0.35, feedback: 0.4) },
    ping_pong: ->(x) { x.ping_pong(0.25, feedback: 0.5) },
    delay: ->(x) { x.delay(0.3, feedback: 0.6) },
    reverb: ->(x) { x.reverb(:hall, mix: 0.5) },
    chorus: ->(x) { x.chorus(:juno2) },
    tape_echo: ->(x) { x.tape_echo(:dub) },
    formant: ->(x) { x.formant(:a, :o) },
  }.freeze

  def play_patch(patch, rebuild)
    MB::Sound.rewind
    MB::Sound.seed(1)
    out = MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: 800)
    s = MB::Sound::Session.new(output: out, realtime: false)
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.track(:lead, &patch)
      MB::Sound.bg(:lead, SWEEP_NOTES)
    end
    4.times { s.process_buffer }
    MB::Sound::Session.with_context(session: s) { SWEEP_REBUILD.(s) } if rebuild
    150.times { s.process_buffer }
    [Numo::DFloat.cast(out.captured[0]), s.last_carry]
  ensure
    s&.close
  end

  SWEEP_EFFECTS.each do |name, fx|
    it "crossfades a voice through #{name} (state no carry copies)" do
      patch = ->(c) { fx.(SWEEP_VOICE.(c)) }
      plain, = play_patch(patch, false)
      carried, plan = play_patch(patch, true)
      expect(plan).not_to be_full, "#{name}: #{plan}"
      expect(plan.uncarried).to be > 0
      expect(plan.matched).to eq(plan.stateful), "#{name} (#{plan})"
      expect(carried[0...SWEEP_SWAP]).to eq(plain[0...SWEEP_SWAP])
      expect(carried.isnan.count_true).to eq(0)
    end
  end
end
