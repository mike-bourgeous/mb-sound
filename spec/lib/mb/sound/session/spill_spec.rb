# Spill-over (carry-1; research-snapshot-mutability's option 1, the
# maintainer's "Adopt + spill", 2026-10-31): where a rebuild's state can't
# move (another reverb size or decay, a new instrument, a redefined patch),
# the graph it replaces rings out under the new one with its notes choked
# on the swap frame (Session::Tails' spill rings), so the old room keeps
# ringing instead of vanishing; it ends on its quiet run like any ring-out
# (the same at any buffer size).  Undo spills back.
RSpec.describe('Session spill-over', :aggregate_failures) do
  after { MB::Sound.rewind }

  SPILL_VOICE = ->(c, decay) {
    c.synth(voices: 4) { |v| v.hz.saw.lp4(1200.hz, resonance: 0.25) * v.amp_env(0.05, 0.2, 0.7, 0.3) }.reverb(room_size: 0.8, decay: decay, mix: 0.6)
  }

  # A note in bar 1, then rests: the rebuild at bar 2:1 lands in the tail
  SPILL_CLIP = MB::Sound.seq(MB::Sound::E3.n2, MB::Sound::R.n2, MB::Sound::R.n1, MB::Sound::R.n1, MB::Sound::R.n1).loop

  def rms_db(x) = 20 * Math.log10(Math.sqrt((x**2).mean) + 1e-30)

  def redefine(decay)
    ->(_s) { MB::Sound.track(:lead) { |c| SPILL_VOICE.(c, decay) } }
  end

  it 'rebuilds a playing track for its redefined patch, a cut when nothing changed' do
    plain, = CarryCheck.play(->(c) { SPILL_VOICE.(c, 4.0) }, clip: SPILL_CLIP, frames: 150_000)
    same, plan, spills = CarryCheck.play(->(c) { SPILL_VOICE.(c, 4.0) }, clip: SPILL_CLIP, act: redefine(4.0), frames: 150_000)
    expect(plan).to be_full
    expect(spills).to eq(0)
    expect(same).to eq(plain)
  end

  it 'lets a reverb whose decay changed ring out under the new one, ending on its quiet run' do
    plain, = CarryCheck.play(->(c) { SPILL_VOICE.(c, 4.0) }, clip: SPILL_CLIP, frames: 240_000)
    spilled, plan, spills = CarryCheck.play(->(c) { SPILL_VOICE.(c, 4.0) }, clip: SPILL_CLIP, act: redefine(1.0), frames: 240_000)
    expect(plan).not_to be_full
    expect(plan.unfit.length).to eq(1) # (the reverb: another design)
    expect(spills).to eq(1)
    expect(spilled[0...CarryCheck::SWAP]).to eq(plain[0...CarryCheck::SWAP])
    # (the old 4 s room rings on in the rest, as if uninterrupted: without
    # spill-over it vanished on the swap)
    [96_000, 120_000, 192_000].each do |f|
      expect(rms_db(spilled[f...(f + 4800)])).to be_within(0.1).of(rms_db(plain[f...(f + 4800)]))
    end
  end

  it 'spills the same at any buffer size, and the spilling graph retires once quiet' do
    s800, = CarryCheck.play(->(c) { SPILL_VOICE.(c, 1.0) }, clip: SPILL_CLIP, act: redefine(0.5), frames: 240_000)
    s367, = CarryCheck.play(->(c) { SPILL_VOICE.(c, 1.0) }, clip: SPILL_CLIP, act: redefine(0.5), size: 367, frames: 240_000)
    expect((s800 - s367).abs.max).to be < 1e-4 * s800.abs.max

    MB::Sound.rewind
    s = MB::Sound::Session.new(output: MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: 800), realtime: false)
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.track(:lead) { |c| SPILL_VOICE.(c, 1.0) }
      MB::Sound.bg(:lead, SPILL_CLIP)
      4.times { s.process_buffer }
      redefine(0.5).(s)
      s.process_buffer while s.frame < 100_000
      expect(s.instance_variable_get(:@players).values.count { |p| p.name == :lead }).to eq(2) # (the new graph, and the old ringing)
      s.process_buffer while s.frame < 240_000
      expect(s.instance_variable_get(:@players).values.count { |p| p.name == :lead }).to eq(1)
      expect(s.journal.entries.map(&:kind)).to include(:rung_out)
    end
  ensure
    s&.close
  end

  it 'replays a take with adopted and spilled rebuilds bit for bit' do
    verb = 'c.synth(voices: 2) { |v| v.hz.saw.lp4(1200.hz, resonance: 0.25) * v.amp_env(0.05, 0.2, 0.5, 0.3) }'
    lines = {
      0 => ["track(:lead) { |c| #{verb}.reverb(room_size: 0.7, decay: 2, mix: 0.5) }", 'bg :lead, seq(E3, G3, R, R).n4.loop'],
      30 => ['bind :lead, lp4: :resonance'],
      150 => ["track(:lead) { |c| #{verb}.reverb(room_size: 0.7, decay: 0.5, mix: 0.5) }"],
      300 => ['undo'],
    }
    session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), channels: 2, buffer_size: 800, realtime: false, raise_errors: true)
    b = MB::Sound::Take.console_binding
    out = []
    MB::Sound.seed(5)
    t = MB::Sound::Take.new(session: session)
    420.times do |i|
      lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: session) { t.line(code, b) } }
      out << session.process_buffer[0].dup
    end
    expect(session.spills).to be >= 1
    live = SpecBuffers.join(out)
    [800, 367].each do |size|
      MB::Sound.seed(5)
      data = []
      t.replay.render(MB::Sound::NullOutput.new(channels: 2, sleep: false), buffer_sizes: [size], tail: 0) { |mix| data << mix[0].dup }
      data = SpecBuffers.join(data)
      expect((data[0...live.length] - live).abs.max).to eq(0), "replayed in #{size}-frame buffers"
    end
  ensure
    session&.close
  end

  it 'spills an instrument change on a playing track, and undo spills back' do
    MB::Sound.rewind
    out = MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: 800)
    s = MB::Sound::Session.new(output: out, realtime: false)
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.track(:lead, :dnb_pad)
      MB::Sound.bg(:lead, SPILL_CLIP)
      4.times { s.process_buffer }
      MB::Sound.track(:lead, :jungle_pad)
      s.process_buffer while s.frame < 100_000
      expect(s.spills).to eq(1)
      MB::Sound.undo(on: :now)
      s.process_buffer while s.frame < 110_000
      expect(s.spills).to eq(2)
      expect(MB::Sound::Arrangement::InstrumentPatch.entry_of(s.arrangement.tracks[:lead].patch).name).to eq(:dnb_pad)
    end
    mix = Numo::DFloat.cast(out.captured[0])
    expect(mix.isnan.count_true).to eq(0)
    # (no click at the swap: the largest step is the sound's own size)
    expect(mix[95_000...97_000].diff.abs.max).to be < 2 * mix[80_000...95_000].diff.abs.max + 1e-3
  ensure
    s&.close
  end
end
