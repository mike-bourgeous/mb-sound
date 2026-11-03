# refine's job (hand-tune-2): the trust region in each knob's own scale,
# JSON for the worker, and the document's blocks (refine's stages).
RSpec.describe(MB::Sound::HandTune::RefineJob, :aggregate_failures) do
  let(:job) {
    described_class.new(name: :x, document: '', reference: '', values: { cutoff: 1000.0, level: 0.5, other: 3 },
                        free: [[:cutoff, 100.0, 10_000.0, :exp, 0.4, 0.6], [:level, 0.0, 1.0, :linear, 0.25, 0.75]],
                        note: 36, velocity: 0.8, hold: nil, seconds: 0.5, weights: nil, evals: 10, budget: nil, seed: 1, stages: [[:cutoff], [:level]])
  }

  it 'maps the unit cube onto each knob\'s trust region in its curve, his values in the middle' do
    expect(job.start_point.map { |x| x.round(12) }).to eq([0.5, 0.5]) # (1000 Hz is position 0.5 of 100..10000 Hz exp, the middle of 0.4..0.6)
    v = job.values_at([0.0, 1.0])
    expect(v[:cutoff]).to be_within(1e-9).of(100.0 * 100.0**0.4)
    expect(v[:level]).to eq(0.75)
    expect(v[:other]).to eq(3)
    expect(job.params).to eq(%i[cutoff level])
  end

  it 'goes through JSON unchanged' do
    back = described_class.from_json_data(JSON.parse(JSON.generate(job.to_json_data)))
    expect(back).to eq(job)
  end

  it "groups the document's params by the calls they are arguments of" do
    text = "kit(midi, seed: 1) { voice(:kick) { |h| body = h.body(tune, decay: decay, sweep: sweep); d = drive_gain; " \
           'h.mix((body * d).softclip(clip, 1.0), h.click(click, tone: click_tone), h.noise(decay: tick_decay, highpass: tick_hp) * tick) } }'
    params = %i[tune decay sweep drive_gain clip click click_tone tick_decay tick_hp tick]
    expect(MB::Sound::HandTune.blocks(text, params)).to eq([%i[tune decay sweep], [:drive_gain], [:clip], %i[click click_tone], %i[tick_decay tick_hp tick]])
  end
end
