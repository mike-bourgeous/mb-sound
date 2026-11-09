# Knobs that do nothing at the settings now (tuner-fixes-2; Linux's
# research-tune-recovery on the 2026-11-07 tunings: a fit's env_decay did
# nothing under a sustain of 1.0, kick2's hat_tune and hat_decay nothing
# under a hat_level of 0): HandTune.knob_effects renders one note with each
# knob moved and the tuner marks the ones below DEAD_DB.  Synthetic fits.
RSpec.describe('MB::Sound::HandTune.knob_effects', :aggregate_failures) do
  CODE = 'synth(CLIP, voices: 1) { |v| (v.hz.saw.lp4(1234.5, resonance: 0.25) * v.env(0.002, 0.3456, 1.0, 0.05) + v.hz.transpose(12.5).sine * 0.0) * 0.5 }'.freeze
  PARAMS = { cutoff: (100.0..8000.0).at(1234.5), env_decay: (0.01..2.0).at(0.3456), hat_tune: (0.0..24.0).at(12.5), hat_level: (0.0..1.0).at(0.0) }.freeze

  let(:fit) { MB::Sound::FitPatch.save(:effects_fit, CODE, PARAMS) }

  it 'finds a decay under a full sustain and a layer at level 0 doing nothing, and the rest audible' do
    e = MB::Sound::HandTune.knob_effects(fit.path, fit.values, note: 45, velocity: 0.75, hold: 0.5, seconds: 1.0)
    expect(e.keys).to eq(%i[cutoff env_decay hat_tune hat_level])
    expect(e[:env_decay]).to eq(-Float::INFINITY)
    expect(e[:hat_tune]).to eq(-Float::INFINITY)
    expect(e[:cutoff]).to be > -20
    expect(e[:hat_level]).to be > -20
    expect(MB::Sound::HandTune.dead_knobs(e)).to eq(%i[env_decay hat_tune])

    # (a knob comes alive when another moves)
    e = MB::Sound::HandTune.knob_effects(fit.path, fit.values.merge(hat_level: 0.5), note: 45, hold: 0.5, seconds: 1.0, params: %i[hat_tune env_decay])
    expect(e[:hat_tune]).to be > -20
    expect(e[:env_decay]).to eq(-Float::INFINITY)
  end

  it "marks them in the tuner's strip data, worked out in the background" do
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), channels: 1, realtime: false)
    MB::Sound::HandTune::Wizard::Background.inline = true
    MB::Sound::Session.with_context(session: s) do
      w = MB::Sound::HandTune::Wizard.open(session: s)
      MB::Sound::HandTune.tune(:lead, CODE, play: MB::Sound.seq(MB::Sound::A2).n4.loop, **PARAMS)
      expect(w.dead_knobs(:lead)).to be_nil # (queued)
      w.background.drain
      expect(w.dead_knobs(:lead)).to eq(%i[env_decay hat_tune])
      expect(w.effects_job(:lead)).to include('do' => 'effects', 'note' => 45, 'values' => { 'cutoff' => 1234.5, 'env_decay' => 0.3456, 'hat_tune' => 12.5, 'hat_level' => 0.0 })
    end
  ensure
    MB::Sound::HandTune::Wizard.close
    MB::Sound::HandTune::Wizard::Background.inline = nil
    s&.close
    MB::Sound.rewind
  end

  it 'answers in the worker protocol' do
    out = StringIO.new
    job = { 'do' => 'effects', 'document' => fit.path, 'values' => fit.values.transform_keys(&:to_s), 'note' => 45, 'velocity' => 0.75, 'hold' => 0.5, 'seconds' => 1.0, 'id' => 3 }
    MB::Sound::HandTune::Wizard::Remote.serve(StringIO.new(JSON.generate(job) + "\n"), out)
    msg = JSON.parse(out.string.lines.last)
    expect(msg['id']).to eq(3)
    expect(msg['effects'].values_at('env_decay', 'hat_tune')).to eq([-999.0, -999.0])
    expect(msg['effects']['cutoff']).to be > -20
  end
end
