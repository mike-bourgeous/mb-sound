RSpec.describe(MB::Sound::GraphNode::Dynamics::TransientShaper, :aggregate_failures) do
  let(:klass) { MB::Sound::GraphNode::Dynamics::TransientShaper }

  # A synthetic drum hit: 50 ms of silence, then seeded noise decaying
  # with an 80 ms time constant (+level+ at its start).
  def hit(level: 1.0, length: 24000, seed: 1)
    rng = Random.new(seed)
    Numo::SFloat.cast(Array.new(length) { |i| i < 2400 ? 0 : (rng.rand * 2 - 1) * level * Math.exp(-(i - 2400) / 3840.0) })
  end

  def arr(*data)
    MB::Sound::ArrayInput.new(data: data)
  end

  # Every output of +node+ (a node or bundle) rendered in buffers cycling
  # through +sizes+ until it ends; one SFloat per channel.
  def render(node, sizes = [800], limit = 200_000)
    outs = node.is_a?(MB::Sound::GraphNode::Channels) ? node.outputs : [node]
    lists = outs.map { [] }
    n = 0
    i = 0
    while n < limit
      bufs = outs.map { |o| o.sample(sizes[i % sizes.length]) }
      break if bufs.any?(&:nil?)
      bufs.each_with_index { |b, k| lists[k] << b.dup }
      n += bufs[0].length
      i += 1
    end
    lists.map { |l| SpecBuffers.join(l) }
  end

  # The gain in dB the shaper applied at each sample of +input+ from
  # +from+ on (where the input is not silent).
  def gain_db(out, input, from = 2401)
    20 * Numo::NMath.log10((Numo::DFloat.cast(out[from..]) / Numo::DFloat.cast(input[from..])).abs)
  end

  describe 'kernel' do
    def compare(ins, params, amounts, ndet)
      n = ins[0].length
      outs_c = ins.map { Numo::SFloat.zeros(n) }
      outs_r = ins.map { Numo::SFloat.zeros(n) }
      st_c = Numo::DFloat.zeros(ndet * 4)
      st_r = Numo::DFloat.zeros(ndet * 4)
      # two calls, so the carried state is compared too
      [0...(n / 3), (n / 3)...n].each do |r|
        oc = outs_c.map { |o| o[r].dup }
        orr = outs_r.map { |o| o[r].dup }
        ic = ins.map { |x| x.is_a?(Numo::NArray) ? x[r].dup : x }
        am = amounts.map { |a| a.is_a?(Numo::NArray) ? a[r].dup : a }
        MB::Sound::FastDynamics.transient(oc, ic, params, am, st_c)
        klass.process_ruby(orr, ic, params, am, st_r)
        oc.each_with_index { |o, c| outs_c[c][r] = o }
        orr.each_with_index { |o, c| outs_r[c][r] = o }
      end
      expect(outs_c).to eq(outs_r)
      expect(st_c).to eq(st_r)
    end

    it 'matches the Ruby mirror for one channel, linked and unlinked stereo, and moving amounts' do
      shaper = klass.new(arr(hit), attack: 6.db, sustain: -6.db)
      params = shaper.kernel_params
      compare([hit], params, [6.0, -6.0], 1)
      ramp = Numo::SFloat.linspace(-12, 12, 24000)
      compare([hit, hit(seed: 2) * 0.3], params, [ramp, ramp.reverse], 1)
      unlinked = params.dup
      unlinked[5] = 0
      compare([hit, hit(seed: 2) * 0.3], unlinked, [3.0, ramp], 2)
      compare([hit, 0.25], params, [0.0, 0.0], 1)
    end

    it 'raises for bad arguments' do
      params = klass.new(arr(hit)).kernel_params
      out = [Numo::SFloat.zeros(10)]
      expect { MB::Sound::FastDynamics.transient(out, [], params, [0, 0], Numo::DFloat.zeros(4)) }.to raise_error(ArgumentError, /inputs/)
      expect { MB::Sound::FastDynamics.transient(out, [0], params, [0], Numo::DFloat.zeros(4)) }.to raise_error(ArgumentError, /two amounts/)
      expect { MB::Sound::FastDynamics.transient(out, [0], params, [0, 0], Numo::DFloat.zeros(2)) }.to raise_error(ArgumentError, /State/)
      expect { MB::Sound::FastDynamics.transient(out, [0], Numo::DFloat[1, 2], [0, 0], Numo::DFloat.zeros(4)) }.to raise_error(ArgumentError, /Params/)
    end
  end

  describe 'on a synthetic drum hit' do
    it 'turns the attack up by up to the amount, back to 0 dB as the hit decays' do
      x = hit
      g = gain_db(render(arr(x).transients(attack: 12.db))[0], x)
      at = ->(ms) { g[(ms * 48).round] }
      expect(at.(0)).to be_between(10, 12)
      expect(at.(1)).to be > 9
      expect(at.(10)).to be_between(3, 7)
      expect(at.(50)).to be < 2.5
      expect(at.(300)).to be < 0.3
      expect(g.max).to be <= 12
      expect(g.min).to be >= -1e-6
    end

    it 'turns the tail up with sustain, leaving the onset alone' do
      x = hit
      g = gain_db(render(arr(x).transients(sustain: 12.db))[0], x)
      expect(g[48]).to be < 0.2
      expect(g[200 * 48]).to be > 6
      expect(g.max).to be <= 12
    end

    it 'cuts by exactly the dB a positive amount boosts' do
      x = hit
      up = gain_db(render(arr(x).transients(attack: 9.db, sustain: 6.db))[0], x)
      down = gain_db(render(arr(x).transients(attack: -9.db, sustain: -6.db))[0], x)
      expect((up + down).abs.max).to be < 1e-4
    end

    it 'shapes a quiet hit as it shapes a loud one (level independent)' do
      loud = hit
      quiet = hit(level: 0.01)
      a = gain_db(render(arr(loud).transients(attack: 9.db, sustain: -6.db))[0], loud)
      b = gain_db(render(arr(quiet).transients(attack: 9.db, sustain: -6.db))[0], quiet)
      expect((a - b)[0...20000].abs.max).to be < 1e-3
    end
  end

  it 'leaves a steady tone nearly alone' do
    # (peaks of the second half: a 60 Hz sine's ripple in the followers
    # leaves a little attack gain; see TransientShaper::PEAK_RELEASE)
    { 60 => 0.6, 440 => 0.2 }.each do |hz, limit|
      g = render(hz.hz.sine.at(0.5).transients(attack: 12.db, sustain: 12.db), [800], 48000)[0]
      ref = render(hz.hz.sine.at(0.5), [800], 48000)[0]
      expect(20 * Math.log10(g[24000..].abs.max / ref[24000..].abs.max)).to be_between(-0.01, limit), "#{hz} Hz"
    end
  end

  it 'links stereo channels by default (one gain for both) and unlinks them on request' do
    l = hit
    r = hit(seed: 2, level: 0.01)
    lo, ro = render(MB::Sound::GraphNode::Channels.new([arr(l), arr(r)]).transients(attack: 12.db))
    gl = gain_db(lo, l)
    gr = gain_db(ro, r)
    expect((gl - gr)[0...20000].abs.max).to be < 1e-3
    lo, ro = render(MB::Sound::GraphNode::Channels.new([arr(l), arr(r)]).transients(attack: 12.db, link: false))
    expect(lo).to eq(render(arr(l).transients(attack: 12.db))[0])
    expect(ro).to eq(render(arr(r).transients(attack: 12.db))[0])
  end

  it 'gives the same output at any buffer size, with moving amounts' do
    make = -> {
      x = hit(length: 48000)
      MB::Sound::GraphNode::Channels.new([arr(x), arr(x * 0.5)]).transients(attack: 0.7.hz.lfo.at(0.5..4), sustain: 3.db)
    }
    a = render(make.(), [1, 7, 128, 33])
    b = render(make.(), [800])
    expect(a).to eq(b)
  end

  it 'reads bare numbers as linear gains and Decibels exactly, and nodes as linear gains' do
    x = hit
    expect(render(arr(x).transients(attack: 2))[0]).to eq(render(arr(x).transients(attack: (20 * Math.log10(2.0)).db))[0])
    expect { 1.constant.transients(attack: -6) }.to raise_error(ArgumentError, /attack.*linear gain/)
    knob = render(arr(x).transients(attack: 4.0.constant))[0]
    num = render(arr(x).transients(attack: (20 * Math.log10(4.0)).db))[0]
    expect((knob - num).abs.max).to be < 1e-5
  end

  it 'ends with its input and prints back as Ruby, loading from a graph document with the same samples' do
    x = hit
    expect(render(arr(x).transients(attack: 6.db))[0].length).to eq(x.length)
    g = -> { 110.hz.saw.at(0.3).until(0.2).transients(attack: 6.db, sustain: -3.db, attack_time: 5.ms) }
    code = g.().to_ruby
    expect(code).to include('transients(attack: 6.db, sustain: -3.db, attack_time: 5.ms)')
    ref = RecipeHelpers.render(g.(), buffers: 30)
    expect(RecipeHelpers.max_diff(ref, RecipeHelpers.render(RecipeHelpers.eval_recipe(code), buffers: 30))).to eq(0)
    expect(RecipeHelpers.max_diff(ref, RecipeHelpers.render(MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(g.())), buffers: 30))).to eq(0)
    expect(1.constant.transient_shaper(attack: 3.db).to_s).to eq('TransientShaper attack 3.0 dB, sustain 0.0 dB')
  end

  it 'rejects bad times' do
    expect { 1.constant.transients(attack_time: -1) }.to raise_error(ArgumentError, /attack_time/)
    expect { 1.constant.transients(release: 0.1.hz.lfo) }.to raise_error(ArgumentError, /length of time/)
  end
end
