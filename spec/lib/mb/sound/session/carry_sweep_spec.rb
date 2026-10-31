# The carry sweep (sound-design-2; the carry check of carry-1, see
# spec/support/carry_check.rb): every shipped instrument preset, played on a
# track and rebuilt mid-note with its running state carried
# (Session::Carry, what a bind or a build knob's turn does), plays the
# samples it played without the rebuild, bit for bit, when every stateful
# node matched and nothing with memory no carry moves is in it (the swap
# is a cut); the others crossfade and keep sounding.  Presets after the
# first few are in the slow tier (SLOW=1).
RSpec.describe('Session::Carry over the shipped presets', :aggregate_failures) do
  after { MB::Sound.rewind }

  SWEEP_PRESETS = MB::Sound::Library.index.entries(kind: :instrument).select { |e| e.location.to_s.include?('/presets/') }.map(&:name).sort
  SWEEP_FRAMES = 96_000 + 120_000 # (past the next note after the swap, where a sleeping voice wakes)

  # Presets whose rebuilds may crossfade, with the reason (state no carry
  # moves yet).  Since carry-1's adoption every shipped preset is a cut, bit
  # for bit (22 of 41 before; the research-snapshot-mutability study's
  # goal was 31), at 800- and 367-frame buffers: a new preset with a node
  # kind that starts fresh (NodeTraits' fresh:) goes here or gets that kind
  # an adoption.
  CROSSFADE_PRESETS = {}.freeze

  it 'sweeps the shipped instrument presets' do
    expect(SWEEP_PRESETS).to include(:init, :dnb_reese, :tine_piano)
    expect(CROSSFADE_PRESETS.keys - SWEEP_PRESETS).to eq([])
  end

  # (dnb_neuro: its squeeze's crossover, hidden from the walk behind its
  # bands, was cut with its state left behind; ambient_drone: sleeping
  # voices' drifts caught up at no rate after a carry; both found by the
  # carry check, carry-1)
  [:init, :dnb_reese, :dnb_neuro, :ambient_drone, *SlowTier.slow_tier(SWEEP_PRESETS - %i[init dnb_reese dnb_neuro ambient_drone], keep: 0)].each do |name|
    it "carries #{name} across a rebuild" do
      clip = CarryCheck.drums?(name) ? CarryCheck::DRUMS : CarryCheck::NOTES
      r = CarryCheck.compare(name, clip: clip, frames: SWEEP_FRAMES)
      expect(r.plan).not_to be_nil
      expect(r).to be_same_before
      expect(r.plan).to be_full, "#{name}: #{r.plan}" unless CROSSFADE_PRESETS.key?(name)
      if r.plan.full?
        expect(r).to be_exact, "#{name}: #{r}"
      else
        # (crossfaded: what starts fresh is state no carry moves yet, a kit
        # voice's idle state or a shaper's; the voices play on)
        expect(r.plan.uncarried).to be > 0
        expect(r.plan.matched).to eq(r.plan.stateful), "#{name} (#{r.plan})"
        expect(r.carried.isnan.count_true).to eq(0)
      end
    end
  end

  # Effects after a voice, each carried by adoption (NodeTraits' carry
  # :adopt): the swap is a cut and the tail plays on bit for bit, also where
  # the swap splits a 367-frame buffer.  Multi-output effects (multitap,
  # ping_pong) once counted as fully carried because they weren't
  # GraphNodes, so their echoes stopped on a hard cut (research-snapshot-
  # mutability); a new effect kind belongs in this list.
  SWEEP_VOICE = ->(c) { c.synth(voices: 2) { |v| v.hz.saw.lp4(1500.hz, resonance: 0.2) * v.amp_env(0.01, 0.2, 0.6, 0.3) } }
  SWEEP_EFFECTS = {
    multitap: ->(x) { x.multitap(0.2, 0.35) },
    multitap_feedback: ->(x) { x.multitap(0.2, 0.35, feedback: 0.4) },
    ping_pong: ->(x) { x.ping_pong(0.25, feedback: 0.5) },
    delay: ->(x) { x.delay(0.3, feedback: 0.6) },
    reverb: ->(x) { x.reverb(:hall, mix: 0.5) },
    reverb_predelay: ->(x) { x.reverb(:plate, mix: 0.5, predelay: 0.03) },
    stereo_reverb: ->(x) { MB::Sound.stereo(x, x * 0.7).reverb(:room, mix: 0.4) },
    chorus: ->(x) { x.chorus(:juno2) },
    tape_echo: ->(x) { x.tape_echo(:dub) },
    formant: ->(x) { x.formant(:a, :o) },
    squeeze: ->(x) { x.squeeze(:default, depth: 0.7, split: [250, 2500]) },
  }.freeze

  SWEEP_EFFECTS.each do |name, fx|
    sizes = [800, *SlowTier.slow_tier([367], keep: 0)]
    it "carries a voice through #{name} bit for bit (#{sizes.join(', ')}-frame buffers)" do
      patch = ->(c) { fx.(SWEEP_VOICE.(c)) }
      sizes.each do |size|
        r = CarryCheck.compare(patch, size: size, frames: 96_000 + 48_000)
        expect(r.plan).to be_full, "#{name}: #{r.plan}"
        expect(r).to be_exact, "#{name} at #{size}: #{r}"
      end
    end
  end
end
