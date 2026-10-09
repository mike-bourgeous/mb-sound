# Synth lanes' shared controllers read once per block and handed to every
# lane's fused regions (MB::Sound::Plan::SharedInputs).
RSpec.describe(MB::Sound::Plan::SharedInputs) do
  around do |ex|
    old = MB::Sound::Plan.precision
    MB::Sound::Plan.precision = :exact
    ex.run
  ensure
    MB::Sound::Plan.precision = old
  end

  # A synth whose lanes read the mod wheel and bend in several places;
  # +extra+ adds to each lane's graph.
  def make_synth(file = 'spec/test_data/dense_modulated.mid', voices: 4, skip_idle: true, &extra)
    MB::Sound.seed(0)
    MB::Sound.synth(file, voices: voices, skip_idle: skip_idle) { |v|
      base = v.hz.glide(50.ms)
      mod = v.cc(1, range: 1.0..2.0)
      e = v.fm_env(0, 1, 0.5, 0.3) * base.transpose(12).sine.pm(mod * base.sine)
      out = v.amp_env * base.sine.pm(e * mod + v.bend) * 0.1
      extra ? extra.call(v, out) : out
    }
  end

  def render(synth, sizes, unshared: false, &each_block)
    synth.instance_variable_set(:@shared_inputs, nil) if unshared
    out = []
    sizes.each_with_index do |n, i|
      each_block&.call(synth, i)
      b = synth.sample(n)
      break if b.nil?

      out.concat(b.to_a)
    end
    out
  end

  let(:sizes) { [128, 1, 37, 512, 800, 128, 64] * 6 }

  it 'shares the controllers and bend read by several lanes' do
    s = make_synth
    s.sample(128)
    labels = s.shared_inputs.sources.map { |x| MB::Sound::Plan.class_label(x) }
    expect(labels).to include('Notes::Control', 'Notes::Bend')
    expect(s.shared_inputs.blocks).to eq(1)
  end

  it 'gives the same samples as reading every Tee branch, at any block sizes' do
    a = render(make_synth, sizes)
    b = render(make_synth, sizes, unshared: true)
    expect(a.length).to be > 10000
    expect(a).to eq(b)
  end

  it 'gives the same samples with idle lanes skipped and not' do
    %w[spec/test_data/c_major.mid spec/test_data/dense_modulated.mid].each do |f|
      [true, false].each do |skip|
        a = render(make_synth(f, skip_idle: skip), sizes)
        b = render(make_synth(f, skip_idle: skip), sizes, unshared: true)
        expect(a).to eq(b)
      end
    end
  end

  it "leaves a lane's own nodes with the lane (skipped lanes advance them)" do
    # A lane's trigger read by two regions (two key-synced tones and a
    # boundary shaper between them); c_major.mid leaves lanes idle, so
    # they are skipped (a double advance once changed the sound and kept
    # the synth from ending: bin/synths/fm_kick.rb)
    make = -> {
      MB::Sound.seed(0)
      MB::Sound.synth('spec/test_data/c_major.mid', voices: 4) { |v|
        a = (v.freq * 1.01).tone.sine.reset(v.trigger).filter(:lowpass, cutoff: 3000) * v.env(0, 0.2, 0, 0.1)
        b = v.freq.tone.ramp.reset(v.trigger) * v.amp_env(0, 0.3, 0, 0.1)
        a * 0.3 + b * 0.2
      }
    }
    s = make.call
    s.sample(128)
    expect(s.shared_inputs.sources.grep(MB::Sound::Notes::Node).select { |n| n.notes }).to be_empty
    expect(render(make.call, [128] * 300)).to eq(render(make.call, [128] * 300, unshared: true))
  end

  it 'gives the same samples in check mode' do
    old = MB::Sound::Plan.check
    MB::Sound::Plan.check = :raise
    a = render(make_synth, sizes.first(12))
    MB::Sound::Plan.check = old
    b = render(make_synth, sizes.first(12), unshared: true)
    expect(a).to eq(b)
  end

  it 'leaves out a controller read by a node outside every region' do
    s = make_synth { |v, out| out * v.cc(1, range: 1.0..2.0).proc { |x| x } }
    s.sample(64)
    shared = s.shared_inputs.sources
    expect(shared.map { |x| MB::Sound::Plan.class_label(x) }).to include('Notes::Bend')
    mod = s.notes[0].cc(1, range: 1.0..2.0)
    expect(shared.select { |x| x.equal?(mod) }).to be_empty
    expect(shared.length).to be >= 2

    a = render(make_synth { |v, out| out * v.cc(1, range: 1.0..2.0).proc { |x| x } }, sizes.first(20))
    b = render(make_synth { |v, out| out * v.cc(1, range: 1.0..2.0).proc { |x| x } }, sizes.first(20), unshared: true)
    expect(a).to eq(b)
  end

  it 'stays exact when a region stops planning in the middle of a block' do
    stop = ->(s, i) { s.plans[2].regions.last.disable('spec') if i == 5 }
    a = render(make_synth, sizes.first(20), &stop)
    b = render(make_synth, sizes.first(20), unshared: true, &stop)
    expect(a).to eq(b)
  end

  it 'stays exact when a lane rebuilds its plans in the middle of a block' do
    rebuild = ->(s, i) { s.plans[1].stale! if i == 4 || i == 9 }
    a = render(make_synth, sizes.first(20), &rebuild)
    b = render(make_synth, sizes.first(20), unshared: true, &rebuild)
    expect(a).to eq(b)
  end

  it 'is off with plans off' do
    old = MB::Sound::Plan.enabled
    MB::Sound::Plan.enabled = false
    expect(make_synth.shared_inputs).to be_nil
  ensure
    MB::Sound::Plan.enabled = old
  end
end
