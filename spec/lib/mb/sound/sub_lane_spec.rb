# Synth sub-lanes (GraphNode::SubLane): the layers of a layered sampler
# instrument sleep in synth voices while they have nothing to play, with the
# same samples as rendering them every buffer, at any buffer size.
RSpec.describe(MB::Sound::GraphNode::SubLane, :aggregate_failures) do
  let(:m) { MB::Sound }

  # Two layers like the GM piano's: A plays every key; B only 61..90, with
  # per-zone envelope and filter values (ZoneValues), a modulation envelope
  # on its cutoff, and a vibrato LFO whose delay changes from zone to zone
  # (read through a FadeIn, a Notes node a sleeping sub-lane advances).
  def layered(b_regions: nil)
    d = Numo::SFloat.cast(Array.new(4000) { |i| Math.sin(i * 0.05) + 0.3 * Math.sin(i * 0.31) })
    smp = m::Sample[d].looped(1000...3900)
    zm = ->(a, b) { m::Sampler::ZoneMap.new([[0..72, 0..127, a], [73..127, 0..127, b]]) }
    a = m::Sampler::Instrument.new(envelope: [0.002, 0.05, 0.6, 0.03]) { |i| i.region(smp, veltrack: 1) }
    mod = {
      sources: { menv: { env: { segments: [[1, 0.01], [0, 0.05]], release_at: 1 } }, vib: { lfo: zm.(5.0, 6.5), delay: zm.(0.0, 0.02), depth: 20, wheel: 30 } },
      pitch: [[:vib, 1]], cutoff: [[:menv, zm.(1200, 600)]],
    }
    b = m::Sampler::Instrument.new(
      envelope: { segments: [[1, zm.(0.001, 0.004), 0], [zm.(0.5, 0.3), 0.05, 6], [0, 0.02, 100]], release_at: 2, sensitivity: nil },
      filter: { cutoff: zm.(900, 3000), quality: 0.9 }, modulation: mod, name: 'B'
    ) { |i| b_regions ? b_regions.call(i, smp) : i.region(smp[0...3000].looped(500...2900), keys: 61..90, tune: 12) }
    m::Sampler::Instrument.layered(a, b, name: 'AB')
  end

  # Notes below, inside, and above layer B's keys, overlapping, with a gap
  let(:riff) {
    (m.seq(m::C3, m::A4, m::E3, m::Cs5, m::G3, nil, m::C4, m::D6).n8.vel(0.8) & m.seq(m::G2, nil, m::B4, nil).n4.vel(0.5)).loop
  }

  def render(make, sizes, total, sub: true)
    old = m::Synth.sub_lanes
    m::Synth.sub_lanes = sub
    m.seed(5)
    node = make.call
    outs = node.respond_to?(:outputs) ? node.outputs : [node]
    synth = outs[0].is_a?(m::Synth) ? outs[0] : outs[0].sources[:synth]
    bufs = outs.map { Numo::SFloat.zeros(total) }
    n = 0
    i = 0
    while n < total
      c = [sizes[i % sizes.length], total - n].min
      outs.each_with_index { |o, k| bufs[k][n...(n + c)] = o.sample(c) }
      n += c
      i += 1
    end
    [bufs, synth]
  ensure
    m::Synth.sub_lanes = old
    m.rewind
  end

  def expect_same(ref, got, label)
    ref.zip(got).each_with_index do |(r, g), c|
      diff = (r - g).ne(0).where.to_a
      expect(diff.first(3)).to eq([]), "#{label} channel #{c}: #{diff.length} samples differ, max #{(r - g).abs.max}"
    end
  end

  it 'puts each layer of a layered instrument in a sub-lane of its synth voice' do
    inst = layered
    _, synth = render(-> { riff.synth(voices: 4) { |v| inst.play(v) } }, [800], 800)
    parts = synth.sub_lanes
    expect(parts.length).to eq(synth.lanes.length)
    expect(parts.map(&:length).uniq).to eq([2])
    expect(parts.flatten.map(&:reason).compact).to eq([])
    expect(parts.flatten).to all(be_skippable)
    expect(parts[0].map(&:to_s)).to eq(['Sub-lane layer 1', 'Sub-lane B'])
  end

  it 'sleeps while a layer has no region for the notes, with the same samples as rendering it, at any buffer size' do
    inst = layered
    make = -> { riff.synth(voices: 4) { |v| inst.play(v) } }
    total = 96_000
    ref, plain = render(make, [800], total, sub: false)
    expect(plain.sub_lanes.flatten).to eq([])
    expect(ref[0].abs.max).to be > 0.1

    counts = [[800], [128], [367, 368], [1, 7, 333, 801, 64]].map { |sizes|
      got, synth = render(make, sizes, total)
      expect_same(ref, got, "sizes #{sizes}")
      b = synth.sub_lanes.map { |l| l[1] }
      expect(b.sum(&:skipped_samples)).to be > total / 2, "sizes #{sizes}"
      expect(b.sum(&:wakes)).to be > 0
      expect(synth.sub_lanes.map { |l| l[0] }.sum(&:skipped_samples)).to be < b.sum(&:skipped_samples) / 4
      synth.sub_lanes.flatten.map { |p| [p.skipped_samples, p.wakes] }
    }
    # (asleep on the same samples at every size)
    expect(counts.uniq.length).to eq(1)
  end

  it 'gives the same samples with plans checked against unfused nodes' do
    inst = layered
    make = -> { riff.synth(voices: 3) { |v| inst.play(v) } }
    ref, _ = render(make, [800], 48_000, sub: false)
    old = m::Plan.check
    m::Plan.check = :raise
    begin
      got, _ = render(make, [128, 313], 48_000)
    ensure
      m::Plan.check = old
    end
    expect_same(ref, got, 'check mode')
  end

  it 'wakes for every note of layers with random or sequential round robins, and in mono lanes' do
    rr = ->(i, smp) {
      i.region(smp, keys: 61..90, rand: 0..0.5)
      i.region(smp[0...2000], keys: 61..90, rand: 0.5..1)
      i.region(smp, keys: 40..50, seq: [1, 2], vel: 0..63)
      i.region(smp[100..], keys: 40..50, seq: [2, 2], vel: 0..63)
    }
    inst = layered(b_regions: rr)
    [[4, -> { riff.synth(voices: 4) { |v| inst.play(v) } }], [1, -> { riff.synth(voices: 1) { |v| inst.play(v) } }]].each do |voices, make|
      ref, _ = render(make, [800], 60_000, sub: false)
      got, synth = render(make, [367, 368], 60_000)
      expect_same(ref, got, "#{voices} voices")
      expect(synth.sub_lanes.flatten.sum(&:wakes)).to be > 0
    end

    check = inst.layers[1].wake_check
    expect(check.call(m::MIDI::Event.note_on(20, 0.5))).to eq(true) # random round robins: every note-on
    expect(check.call(m::MIDI::Event.note_off(20, 0.5))).to eq(false)
    plain = layered.layers[1].wake_check
    expect(plain.call(m::MIDI::Event.note_on(60, 0.5))).to eq(false)
    expect(plain.call(m::MIDI::Event.note_on(61, 0.5))).to eq(true)
    expect(layered.layers[1].wake_check(mono: true).call(m::MIDI::Event.note_off(20, 0.5))).to eq(true)
  end

  it 'passes its inputs through outside a Synth lane, and with Synth.sub_lanes off' do
    inst = layered
    notes = m.seq(m::C3, m::A4).n4.notes
    out = inst.play(notes)
    expect(out.graph.none? { |n| n.is_a?(described_class) }).to eq(true)

    sig = 440.hz.at(0.5)
    part = described_class.new(sig, notes: notes)
    expect(part.skippable?).to eq(false)
    expect(part.reason).to match(/not in a Synth lane/)
    expect(part.outputs[0].sample(100)).to eq(440.hz.at(0.5).sample(100))
  end

  # A node that reads its input without get_sampler (breaking the rule that
  # every consumer branches through a Tee), so two of them share it bare
  class BareReader
    include MB::Sound::GraphNode
    include MB::Sound::GraphNode::SampleRateHelper

    def initialize(input)
      @input = input
      @sample_rate = 48000.0
    end

    def sample(count) = @input.sample(count)
    def sources = { input: @input }
  end

  it 'stays awake if it reads lane nodes without a Tee, naming the reason' do
    inst = layered
    _, synth = render(-> {
      riff.synth(voices: 2) { |v|
        shared = v.gate * 0.25
        part = described_class.new(BareReader.new(shared), notes: v)
        part.outputs[0] + BareReader.new(shared) + inst.play(v)
      }
    }, [800], 1600)
    reasons = synth.sub_lanes.flatten.map(&:reason).compact
    expect(reasons.length).to eq(synth.lanes.length)
    expect(reasons[0]).to match(/reads .* without a Tee/)
  end

  it 'keeps idle lanes whose LFO delay changes from zone to zone skippable (ZoneValue.separate)' do
    inst = layered
    # Before, an idle skipped lane read the delay's ZoneValue through its
    # FadeIn while the other values of its Index paused: "readers out of step"
    clip = m.seq(m::A4, nil, nil, nil, nil, nil, nil, nil).n4.loop
    got, _ = render(-> { clip.synth(voices: 3) { |v| inst.play(v) } }, [800], 6 * 48_000)
    expect(got[0].abs.max).to be > 0.05
    ref, _ = render(-> { clip.synth(voices: 3, skip_idle: false) { |v| inst.play(v) } }, [800], 6 * 48_000)
    expect((got[0] - ref[0]).abs.max).to be < 1e-3
  end
end
