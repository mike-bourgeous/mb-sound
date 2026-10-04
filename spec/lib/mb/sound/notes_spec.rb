RSpec.describe(MB::Sound::Notes) do
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:ev) { MB::Sound::MIDI::Event }
  let(:rate) { 48000 }

  # A Notes instance on a list of events (Event#at times in seconds), with
  # an extra event at 1000 s so the source doesn't end during the example.
  def notes_for(*events)
    MB::Sound::Notes.new(MIDIListSource.new(events, ev.cc(99, 0, time: 1000r)))
  end

  # A Notes instance on +clip+ following the spec's transport.
  def clip_notes(clip)
    MB::Sound::Notes.new(MB::Sound::MIDI::ClipSource.new(clip, transport: transport))
  end

  # Samples each node in +nodes+ (a Hash) +buffers+ times, calling the block
  # (if given) with the buffer index first.  Returns a Hash of concatenated
  # outputs.
  def run(nodes, buffer:, buffers:)
    out = nodes.transform_values { [] }
    buffers.times do |b|
      yield b if block_given?
      nodes.each { |k, n| out[k] << n.sample(buffer).dup }
    end
    out.transform_values { |l| l.reduce(:concatenate) }
  end

  # Clip nodes and Notes nodes for +clip+, by name.
  def compare_nodes(clip)
    v = clip_notes(clip)
    cn = MB::Sound::Sequence::ClipNode
    [
      {
        gate: cn::Gate.new(clip, transport: transport),
        trigger: cn::Trigger.new(clip, range: 0.0..1.0, transport: transport),
        number: cn::Number.new(clip, transport: transport),
        velocity: cn::Velocity.new(clip, range: 0.0..1.0, transport: transport),
      },
      { gate: v.gate, trigger: v.trigger, number: v.number, velocity: v.velocity },
      v,
    ]
  end

  def expect_same(a, b, label = nil)
    a.each_key do |k|
      expect(b[k].to_a).to eq(a[k].to_a), "#{k} #{label}"
    end
  end

  describe 'clip sources' do
    let(:clip) { MB::Sound.seq(MB::Sound::C4, MB::Sound.seq(MB::Sound::E4).vel(0.4), MB::Sound::G4.n16).n8.t.legato(0.7).loop }

    it 'puts every edge on the same sample as ClipNode' do
      [441, 800, 1000].each do |buffer|
        cnodes, nnodes, _ = compare_nodes(clip)
        a = run(cnodes, buffer: buffer, buffers: 48000 * 3 / buffer)
        b = run(nnodes, buffer: buffer, buffers: 48000 * 3 / buffer)
        expect_same(a, b, "buffer #{buffer}")
        expect(a[:trigger].ne(0).count_true).to be > 10
      end
    end

    it 'follows tempo changes like ClipNode' do
      cnodes, nnodes, _ = compare_nodes(clip)
      nodes = cnodes.transform_keys { |k| :"c_#{k}" }.merge(nnodes)
      out = run(nodes, buffer: 800, buffers: 150) { |b| transport.bpm = { 20 => 97, 50 => 143.5, 90 => 61 }.fetch(b, transport.bpm) }
      expect_same(cnodes.keys.to_h { |k| [k, out[:"c_#{k}"]] }, out.slice(*cnodes.keys))
    end

    it 'chases held values at timeline jumps like ClipNode' do
      cnodes, nnodes, v = compare_nodes(clip)
      jumps = { 7 => 5/16r, 20 => 1/3r, 33 => 0r, 41 => 17/24r }
      a = run(cnodes, buffer: 600, buffers: 60) { |idx| cnodes.each_value { |n| n.start_at(jumps[idx]) } if jumps.key?(idx) }
      b = run(nnodes, buffer: 600, buffers: 60) { |idx| v.stream.source.start_at(jumps[idx]) if jumps.key?(idx) }
      expect_same(a, b)
      expect(b[:number].to_a.uniq.sort).to eq([60.0, 64.0, 67.0])
    end

    it 'chases at clip swaps like ClipNode' do
      cnodes, nnodes, v = compare_nodes(clip)
      other = MB::Sound.seq(MB::Sound::D4, MB::Sound::A3).n4.legato(0.5).loop
      a = run(cnodes, buffer: 500, buffers: 40) { |b| cnodes.each_value { |n| n.swap_clip(other, time: 1/6r) } if b == 3 }
      b = run(nnodes, buffer: 500, buffers: 40) { |idx| v.stream.source.swap_clip(other, time: 1/6r) if idx == 3 }
      expect_same(a, b)
      expect(b[:number].to_a.uniq).to include(62.0)
    end

    it 'shows the clip source in the graph, so Session can follow the timeline' do
      v = clip_notes(clip)
      expect(v.gate.graph).to include(v.stream.source)
      expect(v.freq.graph.grep(MB::Sound::Sequence::TimelineNode)).to eq([v.stream.source])
    end
  end

  describe 'mono note bookkeeping' do
    let(:v) {
      notes_for(
        ev.note_on(60, 0.5, time: 0r), ev.note_on(64, 0.8, time: 1/100r), ev.note_off(64, 0.25, time: 2/100r),
        ev.note_off(60, 0.75, time: 3/100r), ev.note_on(67, 1.0, time: 4/100r)
      )
    }

    it 'follows the newest held note and returns to the previous one' do
      out = run({ gate: v.gate, trigger: v.trigger, number: v.number, velocity: v.velocity, lift: v.lift }, buffer: 240, buffers: 10)
      at = ->(k, ms) { out[k][ms * 48] }

      expect([0, 5, 15, 25, 35, 45].map { |ms| at.(:gate, ms) }).to eq([1, 1, 1, 1, 0, 1])
      expect(out[:trigger].ne(0).where.to_a).to eq([0, 480, 1920])
      expect(out[:trigger][[0, 480, 1920]].to_a.map { |f| f.round(4) }).to eq([0.5, 0.8, 1.0])
      expect([5, 15, 25, 35, 45].map { |ms| at.(:number, ms) }).to eq([60, 64, 60, 60, 67])
      expect([5, 15, 25, 45].map { |ms| at.(:velocity, ms).round(3) }).to eq([0.5, 0.8, 0.8, 1.0])
      expect([5, 25, 35].map { |ms| at.(:lift, ms).round(3) }).to eq([0.504, 0.25, 0.75])
      expect(out[:gate].ne(0).where.to_a.values_at(0, -1)).to eq([0, 2399])
      expect(out[:gate][1439]).to eq(1)
      expect(out[:gate][1440]).to eq(0)
    end

    it 'counts overlapping notes on one key' do
      v = notes_for(
        ev.note_on(60, time: 0r), ev.note_on(60, time: 1/100r), ev.note_off(60, time: 2/100r), ev.note_off(60, time: 3/100r)
      )
      g = run({ gate: v.gate }, buffer: 480, buffers: 4)[:gate]
      expect(g[0...1440].to_a.uniq).to eq([1])
      expect(g[1440..].to_a.uniq).to eq([0])
    end

    it 'keeps notes on different channels apart' do
      v = notes_for(ev.note_on(60, channel: 0, time: 0r), ev.note_off(60, channel: 1, time: 1/100r))
      expect(run({ gate: v.gate }, buffer: 960, buffers: 1)[:gate].to_a.uniq).to eq([1])
    end

    it 'releases every note at chokes and all notes off, with choke impulses' do
      v = notes_for(
        ev.note_on(60, time: 0r), ev.choke(nil, time: 1/100r),
        ev.note_on(62, time: 2/100r), ev.cc(123, 0, time: 3/100r),
        ev.note_on(64, time: 4/100r), ev.cc(120, 0, time: 5/100r)
      )
      out = run({ gate: v.gate, choke: v.choke }, buffer: 480, buffers: 6)
      expect(out[:choke].ne(0).where.to_a).to eq([480, 2400])
      expect(out[:gate].to_a.each_slice(480).map(&:first)).to eq([1, 0, 1, 0, 1, 0])
    end

    it 'starts the note number at the first note of the source, or C4' do
      expect(clip_notes(MB::Sound.seq(nil, MB::Sound::G2)).number.sample(10)[0]).to eq(43)
      expect(MB::Sound::Notes.new('spec/test_data/c_major.mid').number.sample(10)[0]).to eq(24) # C1, before it plays at 0.1 s
      expect(notes_for(ev.cc(1, 0)).number.sample(10)[0]).to eq(60)
    end

    it 'puts events on exact samples at any sample rate' do
      v = MB::Sound::Notes.new(MIDIListSource.new(ev.note_on(60, time: 1/3r), ev.cc(1, 0, time: 10r)), sample_rate: 44100)
      t = v.trigger
      out = 11.times.map { t.sample(1470).dup }.reduce(:concatenate)
      expect(out.ne(0).where.to_a).to eq([14700])
    end

    it 'puts several Notes nodes on one sample when read in different buffer sizes' do
      v = notes_for(ev.note_on(60, time: 1/7r))
      a = 8.times.map { v.trigger.sample(1000).dup }.reduce(:concatenate)
      w = notes_for(ev.note_on(60, time: 1/7r))
      b = 20.times.map { w.trigger.sample(400).dup }.reduce(:concatenate)
      expect(a.ne(0).where.to_a).to eq([6857])
      expect(b.ne(0).where.to_a).to eq([6857])
    end
  end

  describe '#freq' do
    it 'follows the note, the bend, and the tuning' do
      v = notes_for(ev.note_on(69, time: 0r), ev.bend(0.5, time: 1/100r), ev.bend(-1.0, time: 2/100r))
      f = v.freq
      out = 3.times.map { f.sample(480).dup }
      expect(out[0][10]).to be_within(0.01).of(440)
      expect(out[1][10]).to be_within(0.01).of(440 * 2 ** (1 / 12.0))
      expect(out[2][10]).to be_within(0.01).of(440 * 2 ** (-2 / 12.0))
      expect(f.value).to be_within(0.01).of(392)

      MB::Sound.tuning(a4: 442)
      expect(f.sample(480)[0]).to be_within(0.01).of(442 * 2 ** (-2 / 12.0))
    ensure
      MB::Sound.tuning.reset
    end

    it 'uses the stream bend range' do
      v = MB::Sound::Notes.new(MB::Sound::MIDI::Stream.new(MIDIListSource.new(ev.note_on(60), ev.bend(1.0))).bend_range(12.st))
      f = v.freq
      b7 = v.bend_semitones(7)
      b = v.bend
      expect(f.sample(100)[50]).to be_within(0.01).of(MB::Sound.tuning.frequency_of(72))
      expect(b7.sample(100)[0]).to be_within(1e-6).of(7)
      expect(b.sample(100)[0]).to eq(1)
    end
  end

  describe 'channel-wide nodes' do
    it 'share one node per stream' do
      stream = MB::Sound::MIDI::Stream.new(MIDIListSource.new(ev.bend(0.5)))
      a = MB::Sound::Notes.new(stream)
      b = MB::Sound::Notes.new(stream)
      expect(a.bend).to equal(b.bend)
      expect(a.pressure).to equal(b.pressure)
      expect(a.bend_semitones).to equal(b.bend_semitones)
      expect(a.bend_semitones(12)).not_to equal(a.bend_semitones)
      expect(a.gate).not_to equal(b.gate)
      expect(a.gate).to equal(a.gate)
    end

    it 'share nodes with the control parent of a lane stream' do
      root = MB::Sound::MIDI::Stream.new(MIDIListSource.new(ev.bend(0.5)))
      lane_source = Class.new(MIDIListSource) {
        attr_accessor :control_parent
      }.new
      lane_source.control_parent = root
      lanes = 2.times.map { MB::Sound::Notes.new(MB::Sound::MIDI::Stream.new(lane_source)) }
      expect(lanes[0].control_stream).to equal(root)
      expect(lanes[0].bend).to equal(lanes[1].bend)
      expect(lanes[0].bend.stream).to equal(root)
      expect(lanes[0].bend.sample(10)[0]).to eq(0.5)
    end

    it 'resets bend and pressure on reset all controllers' do
      v = notes_for(ev.bend(0.5), ev.channel_pressure(0.25), ev.cc(121, 0, time: 1/100r))
      out = run({ bend: v.bend, pressure: v.pressure }, buffer: 480, buffers: 2)
      expect(out[:bend][[0, 480]].to_a).to eq([0.5, 0])
      expect(out[:pressure][[0, 480]].to_a).to eq([0.25, 0])
    end
  end

  describe 'controllers' do
    it 'map CCs through their specs, starting at the default' do
      v = notes_for(ev.cc(74, 0, time: 1/100r), ev.cc_raw(74, 127, time: 2/100r), ev.cc_raw(1, 64, time: 1/100r))
      out = run({ b: v.brightness, m: v.mod, e: v.expression, g: v.cc(16, range: 200..2000, default: 127) }, buffer: 480, buffers: 3)
      expect(out[:b][[0, 480, 960]].to_a).to eq([1, 0.25, 4])
      expect(out[:m][[0, 480]].to_a.map { |x| x.round(4) }).to eq([0, (64 / 127.0).round(4)])
      expect(out[:e][0]).to eq(1)
      expect(out[:g][0]).to eq(2000)
    end

    it 'scale envelope times x1/8..x1..x8 for .gm' do
      spec = MB::Sound::Notes::GM_CONTROLS[:attack_time]
      expect([0, 32, 64, 96, 127].map { |r| spec.value(r).round(4) }).to eq([0.125, 0.3536, 1, 2.8755, 8]) # 8 ** (32 / 63.0) above 64
    end

    it 'gives every GM control a spec with its standard number' do
      c = MB::Sound::Notes::GM_CONTROLS
      expect(c.transform_values(&:number)).to include(
        mod: 1, breath: 2, foot: 4, portamento_time: 5, expression: 11, resonance: 71, brightness: 74,
        vibrato_rate: 76, vibrato_depth: 77, vibrato_delay: 78, release_time: 72, attack_time: 73, decay_time: 75,
      )
      v = notes_for
      expect(v.vibrato_rate.sample(10)[0]).to eq(5.5)
      expect(v.vibrato_delay.sample(10)[0]).to eq(0)
      expect(v.resonance.spec.value(127)).to eq(4)
      expect(v.mod).to equal(v.modulation)
    end

    it 'are shared by every Notes on a stream and listed in controls' do
      stream = MB::Sound::MIDI::Stream.new(MIDIListSource.new(ev.cc(1, 1)))
      a = MB::Sound::Notes.new(stream)
      b = MB::Sound::Notes.new(stream)
      m = a.mod
      c = a.cc(20, name: 'Wobble')
      expect(b.mod).to equal(m)
      expect(b.cc(20, name: 'Wobble')).to equal(c)
      expect(b.cc(20, range: 0..2)).not_to equal(c)
      expect(b.controls.map(&:number)).to eq([1, 20, 20])
      expect(m.spec.name).to eq('Modulation')
      expect(m.graph).to include(stream)
    end

    it 'reset modulation and expression on reset all controllers, but not others' do
      v = notes_for(ev.cc(1, 1), ev.cc(11, 0), ev.cc(74, 1), ev.cc(121, 0, time: 1/100r))
      out = run({ m: v.mod, e: v.expression, b: v.brightness }, buffer: 480, buffers: 2)
      expect(out[:m][[0, 480]].to_a).to eq([1, 0])
      expect(out[:e][[0, 480]].to_a).to eq([0, 1])
      expect(out[:b][[0, 480]].to_a).to eq([4, 4])
    end
  end

  describe 'ending' do
    let(:clip) { MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n8 } # 0.5 s at 120 BPM

    it 'reports ended? after the last event and ends gates and triggers' do
      v = clip_notes(clip)
      g = v.gate
      n = v.number
      t = v.trigger
      expect(g.ended?).to eq(false)
      30.times { expect(g.sample(800)).not_to eq(nil); t.sample(800); n.sample(800) }
      expect(g.ended?).to eq(true)
      expect(n.ended?).to eq(true)
      expect(g.sample(800)).to eq(nil)
      expect(t.sample(800)).to eq(nil)
      expect(n.sample(800)).not_to eq(nil)
    end

    it 'keeps going while envelopes are sounding, up to the tail limit' do
      v = clip_notes(clip)
      g = v.gate
      env = Struct.new(:idle) { def idle? = idle }.new(false)
      v.register(env)
      31.times { expect(g.sample(800)).not_to eq(nil) }
      env.idle = true
      expect(g.sample(800)).to eq(nil)
    end

    it 'gives up after the tail limit' do
      stub_const('MB::Sound::Notes::Node::TAIL_SECONDS', 0.1)
      v = clip_notes(clip)
      v.register(Struct.new(:x) { def idle? = false }.new)
      g = v.gate
      expect(40.times.count { g.sample(800) }).to eq(35) # 30 buffers of clip, 5 of tail
    end

    it 'never ends looping clips' do
      g = clip_notes(clip.loop).gate
      100.times { expect(g.sample(800)).not_to eq(nil) }
      expect(g.ended?).to eq(false)
    end
  end

  it 'never modifies shared buffers', :check_shared do
    v = notes_for(ev.note_on(60), ev.bend(0.5, time: 1/100r), ev.note_off(60, time: 2/100r))
    f = v.freq
    n = v.number.get_sampler
    g1 = v.gate.get_sampler
    g2 = v.gate.get_sampler
    5.times do
      n.sample(480)
      f.sample(480)
      g1.sample(480)
      g2.sample(480)
    end
  end
end
