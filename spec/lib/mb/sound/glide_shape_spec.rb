RSpec.describe('Glide shapes (Notes::Glide with a Curve)') do
  let(:ev) { MB::Sound::MIDI::Event }

  def notes_for(*events)
    MB::Sound::Notes.new(MIDIListSource.new(events, ev.cc(99, 0, time: 1000r)))
  end

  # Note numbers of a Glide from 60 to 72 (second note at 0.01 s).
  def glide_out(buffers: 6, **opts)
    n = notes_for(ev.note_on(60, 100, time: 0r), ev.note_on(72, 100, time: 0.01r))
    g = MB::Sound::Notes::Glide.new(n.note_stream, notes: n, **opts)
    buffers.times.map { g.sample(480).dup }.reduce(:concatenate).cast_to(Numo::DFloat)
  end

  it 'follows the curve from the old note to the new one' do
    [:squiggle, :elastic, :bounce, :back, :s, :sine_in].each do |shape|
      out = glide_out(time: 0.02, shape: shape)
      curve = MB::Sound::Curve[shape]
      t = (Numo::DFloat.new(960).seq + 1) / 960.0
      expect((out[480...1440] - (60 + 12 * curve.map(t))).abs.max).to be < 1e-4, shape.to_s
      expect(out[1440..].to_a.uniq).to eq([72.0])
    end
  end

  it 'passes the target with overshooting shapes, scaled by overshoot: and cycles:' do
    expect(glide_out(time: 0.02, shape: :squiggle).max).to be > 72.5
    expect(glide_out(time: 0.02, shape: :elastic, overshoot: 0.25).max).to be_within(0.01).of(75)
    expect(glide_out(time: 0.02, shape: :bounce).max).to be <= 72
    s3 = glide_out(time: 0.02, shape: :steps, cycles: 3)[480...1440].to_a.uniq
    expect(s3).to eq([64.0, 68.0, 72.0])
  end

  it 'takes a Curve object or a Proc' do
    out = glide_out(time: 0.02, shape: MB::Sound::Curve.power(2))
    expect(out[480 + 479]).to be_within(1e-4).of(60 + 12 * 0.25)
    expect(glide_out(time: 0.02, shape: ->(x) { x })[480 + 479]).to be_within(1e-4).of(66)
  end

  it 'rejects cycles without a shape and options with a Curve object' do
    expect { glide_out(time: 0.02, cycles: 3) }.to raise_error(ArgumentError, /shape/)
    expect { glide_out(time: 0.02, shape: MB::Sound::Curve[:elastic], overshoot: 0.2) }.to raise_error(ArgumentError, /shape name/)
  end

  it 'glides a Notes pitch with a shape' do
    n = notes_for(ev.note_on(60, 100, time: 0r), ev.note_on(72, 100, time: 0.01r))
    f = n.hz.glide(20.ms, shape: :elastic).freq
    out = 6.times.map { f.sample(480).dup }.reduce(:concatenate)
    expect(out.max).to be > MB::Sound::Note.new(72).frequency * 1.05
    expect(out[-1]).to be_within(0.01).of(MB::Sound::Note.new(72).frequency)
  end

  it 'gives swarm copies their own shapes and cycles' do
    n = notes_for(ev.note_on(50, 100, time: 0r))
    seen = []
    n.hz.swarm(4, glide: 0.1, shape: MB::Sound.channels(:squiggle, :bounce), cycles: 2..6, seed: 3) { |p| seen << p; p.sine }
    curves = seen.map { |p| p.freq.graph.grep(MB::Sound::Notes::Glide).first.curve }
    expect(curves.map { |c| c.to_s[/\A[a-z]+/] }).to eq(%w[squiggle bounce squiggle bounce])
    expect(curves.map { |c| c.options[:cycles] }.uniq.length).to be > 1
  end

  it 'rejects shapes on fixed pitches' do
    expect { 110.hz.swarm(3, glide: nil, shape: :squiggle) }.to raise_error(ArgumentError, /Notes pitch/)
  end
end
