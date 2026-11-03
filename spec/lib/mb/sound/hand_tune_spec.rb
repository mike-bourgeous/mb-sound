# The infer step (hand-tune-1, a prototype): his path through a take scored
# with the comparison loss against the reference, step by step, and where
# the loss calls his steps worse.  A synthetic reference: the fit patch
# itself at other settings, so a step toward them is closer by
# construction.
RSpec.describe(MB::Sound::HandTune, :aggregate_failures) do
  HT_CODE = 'synth(CLIP, voices: 1) { |v| v.hz.saw.lp4(1234.5, resonance: 0.25) * v.amp_env(0.01, 0.2, 0.5, 0.1) }'.freeze

  after { MB::Sound.rewind }

  let(:fit) { MB::Sound::FitPatch.save(:infer_fit, HT_CODE, { cutoff: (100.0..8000.0).at(1234.5), resonance: (0.0..1.0).at(0.25) }) }
  let(:reference) { described_class.render(fit.path, { cutoff: 500.0, resonance: 0.25 }, note: 45, hold: 0.3, seconds: 0.4)[0] }

  # A take of his: the cutoff toward the reference's, the resonance away
  # from it and back, a level (not a param).
  let(:take_text) {
    <<~RUBY
      MB::Sound::Take::Replay.new(bpm: 120, ends: 2r) do |r|
        r.line 1/4r, [1/4r], <<~'X'
          turn :"lead/cutoff", 700.hz
        X
        r.line 1/2r, [1/2r], <<~'X'
          turn :"lead/resonance", 0.9
        X
        r.line 3/4r, [3/4r], <<~'X'
          level :lead, -3.db
        X
        r.line 1r, [1r], <<~'X'
          turn :"lead/resonance", 0.25; turn :"lead/cutoff", 500
        X
      end.main(ARGV, __FILE__)
    RUBY
  }

  it 'scores each step of his path and names the ones the loss calls worse' do
    turns = MB::Sound::Take.read(take_text, patch: { lead: fit.path })
    inf = described_class.infer(turns, track: :lead, reference: reference, note: 45, hold: 0.3, seconds: 0.4, line: [0.5])
    expect(inf.steps.map { |st| [st.row.knob, st.row.to] }).to eq([[:"lead/cutoff", 700.0], [:"lead/resonance", 0.9], [:"lead/resonance", 0.25], [:"lead/cutoff", 500]])
    expect(inf.steps.map(&:agrees)).to eq([true, false, true, true])
    expect(inf.disagreements.map { |st| st.row.knob }).to eq([:"lead/resonance"])
    expect(inf.finish.total).to be < 1e-6 # (his end is the reference)
    expect(inf.start.total).to be > inf.finish.total
    expect(inf.steps.first.before).to eq(inf.start.total)
    expect(inf.steps.last.after).to eq(inf.finish.total)
    expect(inf.line.map(&:first)).to eq([0.0, 0.5, 1.0])
    expect(inf.monotone?).to eq(true)
    expect(inf.weighted.keys).to eq(%i[spectral modulation attack])
    expect(inf.to_s).to include('the loss agrees with 3 of his 4 steps; calls worse:', 'lead/resonance  0.25 -> 0.9', 'DISAGREES')
  end

  it 'renders the same samples for the same values' do
    a = described_class.render(fit.path, { cutoff: 900.0 }, note: 45, seconds: 0.2)
    expect(described_class.render(fit.path, { cutoff: 900.0 }, note: 45, seconds: 0.2)).to eq(a)
    expect(a[0].length).to eq(9600)
  end
end
