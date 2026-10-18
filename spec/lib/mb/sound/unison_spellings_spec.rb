# The three spellings of a unison (maintainer, omnibus8 2026-10-17): the
# block form, the blockless form with a shape (Unison::Shapes), and a tone's
# own #unison (Unison::ToneMethods), bit for bit the same.
RSpec.describe('unison spellings') do
  let(:ev) { MB::Sound::MIDI::Event }

  # +n+ 800-sample buffers of each channel of +node+, joined.
  def render(node, n = 12)
    outs = node.outputs
    Array.new(n) { outs.map { |o| o.sample(800).dup } }.transpose.map { |l| SpecBuffers.join(l) }
  end

  # Renders the graph each lambda builds after the same seed.
  def same_seed(*builders)
    builders.map { |b|
      MB::Sound.seed(77)
      render(b.call)
    }
  end

  def expect_identical(results)
    ref = results.first
    results.drop(1).each_with_index do |r, i|
      expect(r.length).to eq(ref.length)
      r.each_with_index { |c, ch| expect(c).to eq(ref[ch]), "spelling #{i + 2}, channel #{ch}" }
    end
    expect(ref.map { |c| c.abs.max }.max).to be > 0.1
  end

  it 'gives the same mono ramps all three ways' do
    expect_identical(same_seed(
      -> { 110.hz.unison(5, detune: 20.cents) { |p| p.ramp } },
      -> { 110.hz.unison(5, detune: 20.cents).ramp },
      -> { 110.hz.ramp.unison(5, detune: 20.cents) },
    ))
  end

  it 'gives the same stereo spread, with settings and a random phase drawn by the tone' do
    expect_identical(same_seed(
      -> { 98.hz.unison(6, spread: 0.5, mix: 1.2) { |p| p.square.pwm(0.3).rnd.at(0.5) } },
      -> { 98.hz.unison(6, spread: 0.5, mix: 1.2).square.pwm(0.3).rnd.at(0.5) },
      -> { 98.hz.square.pwm(0.3).rnd.at(0.5).unison(6, spread: 0.5, mix: 1.2) },
    ))
  end

  it 'gives the same naive shapes, wavetables, and FM' do
    table = MB::Sound::Wavetable.from_harmonics([1, 0.5, 0.25])
    expect_identical(same_seed(
      -> { 220.hz.unison(3) { |p| p.atriangle } },
      -> { 220.hz.unison(3).atriangle },
      -> { 220.hz.atriangle.unison(3) },
    ))
    expect_identical(same_seed(
      -> { 110.hz.unison(3) { |p| p.wavetable(table) } },
      -> { 110.hz.unison(3).wavetable(table) },
      -> { 110.hz.wavetable(table).unison(3) },
    ))
    expect_identical(same_seed(
      -> { m = 220.hz.at(100); 110.hz.unison(3) { |p| p.fm(m) } },
      -> { m = 220.hz.at(100); 110.hz.unison(3).fm(m) },
      -> { m = 220.hz.at(100); 110.hz.fm(m).unison(3) },
    ))
  end

  it 'keeps the blockless unison a saw unison when used as a signal' do
    expect_identical(same_seed(
      -> { 110.hz.unison(5) { |p| p.saw } * 0.5 },
      -> { 110.hz.unison(5) * 0.5 },
    ))
    expect_identical(same_seed(
      -> { 110.hz.unison(4, spread: 1) { |p| p.saw }.filter(:lowpass, cutoff: 900) },
      -> { 110.hz.unison(4, spread: 1).filter(:lowpass, cutoff: 900) },
    ))
    MB::Sound.seed(77)
    u = 110.hz.unison(4, spread: 1)
    expect(u).to be_a(MB::Sound::GraphNode::Channels)
    expect(u.channel_count).to eq(2)
  end

  it 'draws the same seeds as the block form, so later randomness matches too' do
    after = ->(make) { MB::Sound.seed(5); make.call; MB::Sound.next_seed }
    block = after.(-> { 110.hz.unison(3) { |p| p.ramp } })
    expect(after.(-> { 110.hz.unison(3).ramp })).to eq(block)
    expect(after.(-> { 110.hz.ramp.unison(3) })).to eq(block)
    expect(after.(-> { 110.hz.ramp.rnd.unison(3) })).to eq(after.(-> { 110.hz.unison(3) { |p| p.ramp.rnd } }))
  end

  it 'prints each spelling the way it was written, and the printed Ruby rebuilds the same samples' do
    cases = {
      -> { 110.hz.unison(5).ramp * 0.5 } => '110.hz.unison(5).ramp * 0.5',
      -> { 110.hz.unison(5, spread: 1).square.pwm(0.3).at(0.5) } => '110.hz.unison(5, spread: 1).square.pwm(0.3).at(0.5)',
      -> { 110.hz.square.pwm(0.3).unison(5) * 0.5 } => '110.hz.square.pwm(0.3).unison(5) * 0.5',
      -> { 110.hz.unison(5) * 0.5 } => '110.hz.unison(5) * 0.5',
      -> { 110.hz.unison(3) { |p| p.ramp } * 0.5 } => "110.hz.unison(3) { |p|\n  p.ramp\n} * 0.5",
    }
    cases.each do |build, text|
      MB::Sound.seed(3)
      g = build.call
      expect(g.to_ruby).to eq(text)
      MB::Sound.seed(3)
      a = render(build.call)
      MB::Sound.seed(3)
      b = render(MB::Sound.module_eval(text))
      a.each_with_index { |c, ch| expect(b[ch]).to eq(c), text }
    end
  end

  it 'points to the block form for a tone it cannot make again' do
    tone = MB::Sound::GraphNode::Constant.new(220, sample_rate: 48000).tone
    expect { tone.unison(3) }.to raise_error(ArgumentError, /block form, e\.g\. pitch\.unison\(3\) \{ \|p\| p\.saw \}/)
  end

  describe 'in synth voices' do
    let(:events) { [ev.note_on(48, 100), ev.note_on(55, 100, time: 0.05r), ev.note_off(48, time: 0.1r), ev.note_on(52, 100, time: 0.12r)] }

    def synth(&block)
      src = MIDIListSource.new(events, [ev.cc(99, 0, time: 1000r)])
      MB::Sound::Synth.new(src, voices: 2, spares: 0, seed: 9, &block)
    end

    it 'gives the same voices all three ways (key-synced tones, plans on)' do
      expect_identical(same_seed(
        -> { synth { |v| v.hz.unison(4, detune: 15.cents, spread: 0.6) { |p| p.saw.at(0.7) } * v.gate } },
        -> { synth { |v| v.hz.unison(4, detune: 15.cents, spread: 0.6).saw.at(0.7) * v.gate } },
        -> { synth { |v| v.hz.saw.at(0.7).unison(4, detune: 15.cents, spread: 0.6) * v.gate } },
      ))
    end

    it 'makes copies of a Notes::KeyedTone that keep key sync' do
      tones = []
      allow(MB::Sound::Unison).to receive(:apply_phase).and_wrap_original { |m, t, ph| tones << t; m.call(t, ph) }
      synth { |v| v.hz.ramp.unison(3) * v.gate }
      expect(tones.length).to eq(6)
      expect(tones).to all(be_a(MB::Sound::Notes::KeyedTone))
      expect(tones).to all(be_key_sync)
    end
  end
end
