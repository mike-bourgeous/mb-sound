require_relative '../../../support/ui_helpers'

# A/B against a reference (hand-tune-1): the reference on its own track
# playing the patch track's clip, muted, its level matched to the patch's
# loudness; `ab` flips which one is heard.  Synthetic references only.
RSpec.describe(MB::Sound::Reference, :aggregate_failures) do
  REF_SPEC_CODE = 'synth(CLIP, voices: 1) { |v| v.hz.saw.lp4(1234.5, resonance: 0.25) * v.amp_env(0.01, 0.2, 0.5, 0.1) }'.freeze

  before { @sessions = [] }
  after {
    @sessions.each(&:close)
    MB::Sound.rewind
  }

  let(:fit) { MB::Sound::FitPatch.save(:lead_fit, REF_SPEC_CODE, { cutoff: (100.0..8000.0).at(1234.5), resonance: (0.0..1.0).at(0.25) }) }
  let(:clip) { MB::Sound.seq(MB::Sound::A2).n4.loop }
  # The reference: the same voice darker and 6 dB down (a sound to match).
  let(:reference) {
    a = MB::Sound::HandTune.render(fit.path, { cutoff: 500.0 }, note: 45, hold: 0.5, seconds: 0.5)
    MB::Sound::Sample.new(a.map { |c| c * 10**(-6 / 20.0) }, name: 'darker')
  }

  def session
    MB::Sound.rewind
    MB::Sound.seed(1)
    out = MB::Sound::Sampler::CaptureOutput.new(channels: 1, buffer_size: 800)
    s = MB::Sound::Session.new(output: out, realtime: false)
    @sessions << s
    [s, out]
  end

  # The LUFS of what +out+ captured from frame +from+ to +to+.
  def lufs(out, from, to)
    MB::Sound.loudness([Numo::SFloat.cast(out.captured[0][from...to])], sample_rate: 48000, true_peak: false).integrated
  end

  it 'puts the reference on its own track, muted, playing the clip, loudness-matched' do
    s, out = session
    pair = nil
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.track(:lead, fit)
      MB::Sound.bg(:lead, clip)
      pair = MB::Sound.ab(:lead, reference)
    end
    expect(pair).to have_attributes(track: :lead, ref: :lead_ref, hearing: :patch, note: nil)
    expect(pair.level_db).to be_within(1e-9).of(pair.patch_lufs - pair.ref_lufs)
    expect(pair.level_db).to be > 3
    expect(s.arrangement.tracks.keys).to include(:lead_ref)
    120.times { s.process_buffer }
    expect(s.muted?(:lead_ref)).to eq(true) if s.respond_to?(:muted?)
    patch = lufs(out, 48000, 96000)
    expect(pair.to_s).to match(/hearing the patch \(:lead\); patch -?\d+\.\d LUFS, reference -?\d+\.\d LUFS, reference level \+\d+\.\d dB/)

    MB::Sound::Session.with_context(session: s) { expect(MB::Sound.ab).to equal(pair) }
    expect(pair.hearing).to eq(:ref)
    120.times { s.process_buffer }
    ref = lufs(out, 48000 + 96000, 96000 + 96000)
    expect(ref).to be_within(1.0).of(patch)
    expect(s.journal.changes.select { |e| %i[mute unmute].include?(e.kind) }.map { |e| [e.kind, e.subject] }.last(2)).to eq([%i[mute lead], %i[unmute lead_ref]])

    MB::Sound::Session.with_context(session: s) { MB::Sound.ab(:lead) }
    expect(pair.hearing).to eq(:patch)
    MB::Sound::Session.with_context(session: s) { MB::Sound.ab(:lead, :off) }
    expect(MB::Sound::Reference.pair(s, :lead)).to be_nil
  end

  it 'matches again on a flip to the reference after the knobs moved' do
    s, = session
    pair = nil
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.track(:lead, fit)
      MB::Sound.bg(:lead, clip)
      pair = MB::Sound.ab(:lead, reference)
    end
    10.times { s.process_buffer }
    first = pair.patch_lufs
    MB::Sound::Session.with_context(session: s) { MB::Sound.turn(:"lead/cutoff", 300.0, smooth: 0) }
    10.times { s.process_buffer }
    MB::Sound::Session.with_context(session: s) { MB::Sound.ab }
    expect(pair.values).to eq(cutoff: 300.0, resonance: 0.25)
    expect(pair.patch_lufs).not_to be_within(0.1).of(first)
    want = MB::Sound::Reference.lufs(MB::Sound::Reference.patch_audio(s, :lead, 0.5), 48000)
    expect(pair.patch_lufs).to be_within(1e-9).of(want)
  end

  it 'flips a patch block it cannot render offline, saying it is not matched' do
    s, = session
    pair = nil
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.track(:lead) { |c| c.synth { |v| v.hz.saw * v.amp_env } }
      MB::Sound.bg(:lead, clip)
      pair = MB::Sound.ab(:lead, reference)
    end
    expect(pair.note).to match(/not loudness-matched: :lead's patch isn't a graph document/)
    expect(pair.level_db).to eq(0.0)
    MB::Sound::Session.with_context(session: s) { MB::Sound.ab }
    expect(pair.hearing).to eq(:ref)
  end

  it 'says how to set one up' do
    s, = session
    MB::Sound::Session.with_context(session: s) do
      expect { MB::Sound.ab }.to raise_error(ArgumentError, /no reference set up/)
      expect { MB::Sound.ab(:nope, reference) }.to raise_error(ArgumentError, /no track :nope/)
    end
  end

  it 'has console names (ab, fit_patch, tune) that are no Kernel, Object, GraphNode, or Pry names' do
    require 'pry'
    pry_commands = Pry::Commands.keys.map(&:to_s)
    { ab: MB::Sound::ReferenceMethods, fit_patch: MB::Sound::FitPatchMethods, tune: MB::Sound::HandTuneMethods }.each do |n, owner|
      expect(MB::Sound.method(n).owner).to eq(owner), "#{n} is defined by #{MB::Sound.method(n).owner}"
      expect(Object.new.respond_to?(n, true)).to eq(false), "#{n} is an Object method"
      expect(pry_commands).not_to include(n.to_s)
      expect(MB::Sound::GraphNode.method_defined?(n)).to eq(false), "#{n} is a GraphNode method"
    end
  end

  describe 'on a screen' do
    after do
      @tiles&.stop
      @term&.close
      MB::Sound::UI::Inspect.target = nil
    end

    it 'flips with b in the inspector, one ab line' do
      s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
      @sessions << s
      pair = nil
      MB::Sound::Session.with_context(session: s) do
        MB::Sound.track(:lead, fit)
        MB::Sound.bg(:lead, clip)
        pair = MB::Sound.ab(:lead, reference)
      end
      20.times { s.process_buffer }
      MB::Sound::UI::Inspect.target = { track: :lead }.freeze
      @tiles, @term = ui_tiles(:sound, rows: 40, cols: 120, session: s)
      stop = false
      pump = Thread.new { until stop; s.process_buffer; sleep 0.005; end }
      expect(@term.wait_for('lp4')).to eq(true), @term.text
      @term.write("\x1d")
      expect(@term.wait_for(' NAV ')).to eq(true)
      @term.type('d')
      expect(wait_until { @tiles.router.mode == :pane && @tiles.tiler.focus == :inspector }).to eq(true)
      expect(wait_until { @tiles.instance_variable_get(:@states)[:inspector][:snap]&.inspector&.track == :lead }).to eq(true)
      @term.type('b')
      expect(wait_until { pair.hearing == :ref }).to eq(true), @term.text
      expect(@term.wait_for('hearing the reference (:lead_ref)')).to eq(true), @term.text
      @term.type('b')
      expect(wait_until { pair.hearing == :patch }).to eq(true)
      expect(@tiles.mode_problems).to eq([])
    ensure
      stop = true
      pump&.join
    end
  end
end
