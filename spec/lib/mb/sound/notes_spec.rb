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

  # Notes nodes for +clip+ by name, and the Notes instance.
  def notes_nodes(clip)
    v = clip_notes(clip)
    [{ gate: v.gate, trigger: v.trigger, number: v.number, velocity: v.velocity }, v]
  end

  def expect_same(a, b, label = nil)
    a.each_key do |k|
      expect(b[k].to_a).to eq(a[k].to_a), "#{k} #{label}"
    end
  end

  describe 'clip sources' do
    let(:clip) { MB::Sound.seq(MB::Sound::C4, MB::Sound.seq(MB::Sound::E4).vel(0.4), MB::Sound::G4.n16).n8.t.legato(0.7).loop }

    # The expected outputs are the old ClipNode renderers' (see
    # spec/support/clip_node_reference.rb).
    it 'puts every edge on the same sample as ClipNode did' do
      [441, 800, 1000].each do |buffer|
        nnodes, _ = notes_nodes(clip)
        b = run(nnodes, buffer: buffer, buffers: 48000 * 3 / buffer)
        expect_same(ClipNodeReference["notes_edges_#{buffer}"], b, "buffer #{buffer}")
        expect(b[:trigger].ne(0).count_true).to be > 10
      end
    end

    it 'follows tempo changes like ClipNode did' do
      nnodes, _ = notes_nodes(clip)
      out = run(nnodes, buffer: 800, buffers: 150) { |b| transport.bpm = { 20 => 97, 50 => 143.5, 90 => 61 }.fetch(b, transport.bpm) }
      expect_same(ClipNodeReference[:notes_tempo], out)
    end

    it 'chases held values at timeline jumps like ClipNode did' do
      nnodes, v = notes_nodes(clip)
      jumps = { 7 => 5/16r, 20 => 1/3r, 33 => 0r, 41 => 17/24r }
      b = run(nnodes, buffer: 600, buffers: 60) { |idx| v.stream.source.start_at(jumps[idx]) if jumps.key?(idx) }
      expect_same(ClipNodeReference[:notes_jumps], b)
      expect(b[:number].to_a.uniq.sort).to eq([60.0, 64.0, 67.0])
    end

    it 'chases at clip swaps like ClipNode did' do
      nnodes, v = notes_nodes(clip)
      other = MB::Sound.seq(MB::Sound::D4, MB::Sound::A3).n4.legato(0.5).loop
      b = run(nnodes, buffer: 500, buffers: 40) { |idx| v.stream.source.swap_clip(other, time: 1/6r) if idx == 3 }
      expect_same(ClipNodeReference[:notes_swap], b)
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

  describe 'envelopes' do
    # Renders +env+ for +buffers+ buffers of 480 samples.
    def render_env(env, buffers = 80)
      buffers.times.map { env.sample(480).dup }.reduce(:concatenate)
    end

    def notes_with(*events)
      notes_for(ev.note_on(60, 1.0), *events, ev.note_off(60, time: 1/2r))
    end

    it 'are wired to the gate, trigger, velocity, and choke, and register for idle?' do
      v = notes_with
      e = v.amp_env(0.01, 0.1, 0.5, 0.1)
      expect(e).to be_a(MB::Sound::Notes::NoteEnvelope)
      expect(e.sources.keys).to include(:gate, :trigger, :velocity, :choke)
      expect(e.sources).not_to have_key(:lift)
      expect(v.envelopes).to eq([e])
      expect(v.idle?).to eq(true)
      out = render_env(e, 10)
      expect(out.max).to be_within(1e-6).of(1)
      expect(v.idle?).to eq(false)
      render_env(e, 55) # note-off at 24000, release 4800 samples
      expect(v.idle?).to eq(true)
      expect(v.filt_env).to be_a(MB::Sound::Notes::NoteEnvelope)
      expect(v.filter_env.octaves).to eq(2)
      expect(v.fm_env).to be_a(MB::Sound::Notes::NoteEnvelope)
      expect(v.envelopes.length).to eq(4)
    end

    it 'end (return nil) once the stream has ended and they are idle' do
      v = MB::Sound::Notes.new(MIDIListSource.new([ev.note_on(60, 1.0), ev.note_off(60, time: 1/10r)]))
      e = v.env(0.001, 0.01, 1, 0.05, curve: :linear)
      bufs = []
      while (b = e.sample(480)) && bufs.length < 100
        bufs << b.dup
      end
      expect(bufs.length).to be_between(10 + 5, 10 + 5 + 2) # note-off at 4800, release 2400
      expect(bufs.last.to_a.last).to eq(0)

      looping = clip_notes(MB::Sound::C4.n16.loop).env(0.001, 0.01, 1, 0.01)
      expect(Array.new(100) { looping.sample(480) }.compact.length).to eq(100)
    end

    it 'scale times by the GM2 controllers with .gm' do
      [[127, 3840, 38400], [0, 60, 600], [64, 480, 4800]].each do |raw, attack, release|
        v = notes_with(ev.cc_raw(73, raw), ev.cc_raw(72, raw))
        out = render_env(v.env(0.01, 0.1, 0.5, 0.1, curve: :linear), 140).to_a
        expect(out.index { |x| x >= 0.9999 }).to be_within(1).of(attack - 1), "attack at #{raw}"
        expect(out.rindex { |x| x > 0 }).to be_within(1).of(24000 + release - 1), "release at #{raw}"
      end
    end

    it 'turn GM2 scaling off with gm: false or .gm(false)' do
      v = notes_with(ev.cc_raw(73, 127))
      a = v.env(0.01, 0.1, 0.5, 0.1, curve: :linear, gm: false)
      b = v.env(0.01, 0.1, 0.5, 0.1, curve: :linear).gm(false)
      expect(a.gm?).to eq(false)
      expect(b.attack).to eq(0.01)
      expect(v.attack_time.get_sampler.instance_variable_get(:@tee).branches.length).to eq(1) # the dropped scaling branch is gone
      expect(render_env(a, 10).to_a).to eq(render_env(b, 10).to_a)
      expect(render_env(a, 1).to_a.index(1.0)).to eq(nil)
      b.gm
      expect(b.gm?).to eq(true)
      expect(b.attack).to be_a(MB::Sound::GraphNode)
    end

    it 'wire release velocity with lift: true' do
      fast = notes_for(ev.note_on(60, 1.0), ev.note_off(60, 1.0, time: 1/10r), ev.cc(99, 0, time: 10r))
      slow = notes_for(ev.note_on(60, 1.0), ev.note_off(60, 0.0, time: 1/10r), ev.cc(99, 0, time: 10r))
      plain = notes_for(ev.note_on(60, 1.0), ev.note_off(60, 0.0, time: 1/10r), ev.cc(99, 0, time: 10r))
      ends = [
        fast.env(0, 0.01, 1, 0.1, lift: true, curve: :linear),
        slow.env(0, 0.01, 1, 0.1, lift: true, curve: :linear),
        plain.env(0, 0.01, 1, 0.1, curve: :linear),
      ].map { |e| render_env(e, 40).to_a.rindex { |x| x > 0 } - 4800 }
      expect(ends[0]).to be_within(2).of(2400)
      expect(ends[1]).to be_within(2).of(9600)
      expect(ends[2]).to be_within(2).of(4800)
    end

    it 'choke quickly on :choke events, with no note-off' do
      v = notes_for(ev.note_on(60, 1.0), ev.choke(60, time: 1/10r), ev.cc(99, 0, time: 10r))
      e = v.amp_env(0, 0.01, 1, 2)
      out = render_env(e, 20).to_a
      expect(out[4799]).to be > 0.5
      last = out.rindex { |x| x > 0 }
      expect(last - 4800).to be_within(2).of(144) # 3 ms
      expect(v.idle?).to eq(true)
    end

    it 'keep the gate high through a note-off and legato note-on at one time' do
      v = notes_for(
        ev.note_on(60, 1.0), ev.note_off(60, time: 1/10r), ev.note_on(64, 0.5, time: 1/10r, legato: true),
        ev.note_off(64, time: 2/10r)
      )
      out = run({ gate: v.gate, number: v.number, trigger: v.trigger }, buffer: 480, buffers: 25)
      expect(out[:gate][0...9600].to_a.uniq).to eq([1])
      expect(out[:number][4800]).to eq(64)
      expect(out[:trigger].ne(0).where.to_a).to eq([0, 4800])
    end

    it 'keep a legato envelope in its stage through legato notes' do
      v = notes_for(
        ev.note_on(60, 1.0), ev.note_off(60, time: 1/10r), ev.note_on(64, 1.0, time: 1/10r, legato: true),
        ev.note_off(64, time: 2/10r), ev.cc(99, 0, time: 10r)
      )
      e = v.env(0.001, 0.01, 0.5, 0.01).legato
      out = render_env(e, 25)
      expect(out[4790..4900].to_a.map { |x| x.round(4) }.uniq).to eq([0.5])
    end

    it 'end the graph once the stream ended and the envelopes finished' do
      v = clip_notes(MB::Sound.seq(MB::Sound::C4).n8) # 0.25 s
      out = v.gate.get_sampler
      e = v.amp_env(0, 0.01, 1, 0.2) # releases from 0.25 s for 0.2 s
      n = 0
      loop do
        o = out.sample(480)
        b = e.sample(480)
        break if o.nil? || b.nil?
        n += 1
      end
      expect(n).to be_between(46, 48)
    end
  end

  describe '#hz' do
    let(:v) { notes_for(ev.note_on(69, 1.0), ev.bend(1.0, time: 1/100r), ev.note_on(57, 1.0, time: 1/7r)) }

    it 'shares one Frequency node among pitches with the same settings' do
      expect(v.hz.freq).to equal(v.freq)
      expect(v.hz.transpose(7).freq).to equal(v.hz.transpose(7).freq)
      expect(v.hz.transpose(7).freq).not_to equal(v.hz.transpose(5).freq)
      expect(v.hz.bend_range(12.st).freq).to equal(v.hz.bend_range(12).freq)

      a = v.hz.transpose(7).saw
      b = v.hz.transpose(7).square
      a1 = a.sample(480).dup
      b1 = b.sample(480).dup
      expect(a1.abs.max).to be > 0.5
      expect(b1.abs.max).to be > 0.5
      expect(v.hz.transpose(7).freq.value).to be_within(0.01).of(MB::Sound.tuning.frequency_of(69 + 7)) # bend comes at sample 480
    end

    it 'gives a Pitch following the note and bend' do
      expect(v.hz).to be_a(MB::Sound::Pitch)
      expect(v.hz).to equal(v.tone)
      expect(v.pitch).to equal(v.hz)
      f = v.hz.freq
      g = v.hz.bend_range(12.st).freq
      t = v.hz.transpose(-1.oct).freq
      out = run({ f: f, g: g, t: t }, buffer: 480, buffers: 2)
      expect(out[:f][0]).to be_within(1e-3).of(440)
      expect(out[:f][480]).to be_within(1e-2).of(440 * 2 ** (2 / 12.0))
      expect(out[:g][480]).to be_within(1e-2).of(880)
      expect(out[:t][0]).to be_within(1e-3).of(220)
      expect(v.hz.frequency).to be_within(1e-2).of(440 * 2 ** (2 / 12.0)) # the latest value
    end

    it 'makes tones that reset at every note-on' do
      v = notes_for(ev.note_on(69, 1.0), ev.bend(1.0, time: 1/100r), ev.note_on(57, 1.0, time: 1/5r + 1/96000r))
      keyed = v.hz.sine
      expect(keyed).to be_a(MB::Sound::Notes::KeyedTone)
      expect(keyed.key_sync?).to eq(true)
      free = notes_for(ev.note_on(69, 1.0), ev.bend(1.0, time: 1/100r), ev.note_on(57, 1.0, time: 1/5r + 1/96000r)).hz.sine.free
      a = 30.times.map { keyed.sample(480).dup }.reduce(:concatenate)
      b = 30.times.map { free.sample(480).dup }.reduce(:concatenate)
      reset = 9600 # the sample containing 0.2 s + half a sample
      expect(a[0...reset].to_a).to eq(b[0...reset].to_a)
      expect((a[reset...reset + 200] - b[reset...reset + 200]).abs.max).to be > 0.1
      expect(a[reset + 40]).to be_within(0.02).of(Math.sin(2 * Math::PI * 220 * 2 ** (2 / 12.0) * 40 / 48000.0)) # bent up 2 st
    end

    it 'leaves free tones, LFOs, and synced tones alone, quietly' do
      expect {
        expect(v.hz.saw.free.key_sync?).to eq(false)
        expect(v.hz.saw.free.reset_input).to eq(nil)
        expect(v.hz.free.reset_input).to eq(nil)
        expect(v.hz.ramp.lfo.reset_input).to eq(nil)
        expect(v.hz.lfo.reset_input).to eq(nil)
        expect(v.hz.saw.sync(ratio: 2).reset_input).to eq(nil) # no error from reset + sync
        expect(v.hz.saw.lfo.key_sync?).to eq(false)
      }.not_to output.to_stderr
    end

    it 'keeps key sync with a random phase, and replaces it with another reset' do
      t = v.hz.saw.rnd
      expect(t.key_sync?).to eq(true)
      expect(t.random_phase?).to eq(true)
      other = MB::Sound.seq(MB::Sound::C4).loop.trigger
      r = v.hz.saw.reset(other)
      expect(r.key_sync?).to eq(false)
      expect(r.reset_input).not_to eq(nil)
      tee = v.key_trigger.get_sampler.instance_variable_get(:@tee)
      expect(tee.branches.length).to eq(2) # the rnd tone's and this branch; dropped ones are destroyed
    end
  end

  describe '#cutoff and #quality' do
    it 'multiply the base by brightness, the envelope, and key tracking' do
      v = notes_for(ev.note_on(72, 1.0), ev.cc_raw(74, 127, time: 1/100r), ev.cc_raw(74, 0, time: 2/100r))
      c = v.cutoff(500, env: false)
      k = v.cutoff(500, env: false, keytrack: 1, gm: false)
      out = run({ c: c, k: k }, buffer: 480, buffers: 3)
      expect(out[:c][0]).to be_within(1e-3).of(500 * 2 ** 0.5)
      expect(out[:c][480]).to be_within(1e-2).of(500 * 4 * 2 ** 0.5)
      expect(out[:c][960]).to be_within(1e-3).of(500 / 4.0 * 2 ** 0.5)
      expect(out[:k].to_a.uniq).to eq([1000])
    end

    it 'adds a default filter envelope of 2 octaves' do
      v = notes_for(ev.note_on(60, 1.0), ev.note_off(60, time: 1r), ev.cc(99, 0, time: 10r))
      c = v.cutoff(200)
      expect(c.env).to be_a(MB::Sound::Notes::NoteEnvelope)
      expect(c.env.octaves).to eq(2)
      expect(v.envelopes).to include(c.env)
      out = 60.times.map { c.sample(480).dup }.reduce(:concatenate) # past the 0.4 s decay
      expect(out.max).to be_within(1).of(800) # peak: base x 2 ** 2 at full velocity
      expect(out[-1]).to be_within(5).of(200 * 2 ** (2 * 0.3))
      expect(c.gm?).to eq(true)
      expect(c.env.gm?).to eq(true)
      c.gm(false)
      expect(c.env.gm?).to eq(false)
      expect(c.sources).not_to have_key(:brightness)
    end

    it 'clamps to 1 Hz..0.49 x the sample rate' do
      v = notes_for(ev.note_on(127))
      expect(v.cutoff(20000, env: false, keytrack: 1).sample(10)[0]).to eq(0.49 * 48000)
      expect(v.cutoff(0.0, env: false).sample(10)[0]).to eq(1)
    end

    it 'scales quality by resonance' do
      v = notes_for(ev.cc_raw(71, 64), ev.cc_raw(71, 127, time: 1/100r), ev.cc_raw(71, 0, time: 2/100r))
      q = v.quality(2)
      out = run({ q: q, n: v.quality(2, gm: false) }, buffer: 480, buffers: 3)
      expect(out[:q][[0, 480, 960]].to_a).to eq([2, 8, 1])
      expect(out[:n].to_a.uniq).to eq([2])
    end

    it 'works in a filter', :check_shared do
      v = notes_for(ev.note_on(48, 1.0), ev.note_off(48, time: 1/2r), ev.cc(99, 0, time: 10r))
      sig = v.hz.saw.filter(:lowpass, cutoff: v.cutoff(400), quality: v.quality(3)) * v.amp_env
      out = 30.times.map { sig.sample(800).dup }.reduce(:concatenate)
      expect(out.abs.max).to be_between(0.1, 2)
    end
  end

  describe '#reso' do
    it 'gives the base amount at 64, 0 at 0, and 1 at 127, linear in each half' do
      v = notes_for(
        ev.cc_raw(71, 64), ev.cc_raw(71, 127, time: 1/100r), ev.cc_raw(71, 0, time: 2/100r),
        ev.cc_raw(71, 96, time: 3/100r), ev.cc_raw(71, 32, time: 4/100r)
      )
      r = v.reso(0.6)
      out = run({ r: r, n: v.resonance_amount(0.6, gm: false), hi: v.reso(2) }, buffer: 480, buffers: 5)
      expect(out[:r][0]).to be_within(1e-6).of(0.6)
      expect(out[:r][480]).to be_within(1e-6).of(1)
      expect(out[:r][960]).to eq(0)
      expect(out[:r][1440]).to be_within(1e-3).of(0.6 + 0.4 * 32 / 63.0)
      expect(out[:r][1920]).to be_within(1e-3).of(0.6 * 0.5)
      expect(out[:n].to_a.uniq).to eq([0.6.to_f.then { |x| Numo::SFloat[x][0] }])
      expect(out[:hi].max).to eq(1)
    end

    it 'takes a node as the base amount' do
      v = notes_for(ev.cc_raw(71, 64))
      expect(v.reso(0.25.constant).sample(10).to_a.uniq).to eq([0.25])
    end

    it 'shows CC 71 as a resonance amount in the controls and ACID XML' do
      v = notes_for(ev.cc_raw(71, 64))
      r = v.reso(0.6)
      spec = v.controls.find { |s| s.description&.include?('Notes#reso') }
      expect(spec.number).to eq(71)
      expect(spec.value(64)).to eq(0)
      expect(v.controls.to_acid_xml(name: 'x')).to include('71')
      expect(r.gm(false).gm?).to eq(false)
    end

    it 'drives a 4-pole filter in synth voices', :check_shared do
      clip = MB::Sound.seq(MB::Sound::A2.n4, MB::Sound::A2.n4)
      synth = clip.synth(voices: 2) { |v| v.hz.saw.lp4(v.cutoff(300), resonance: v.reso(0.7)) * v.amp_env }
      out = 20.times.map { synth.sample(800).dup }.reduce(:concatenate)
      expect(out.isfinite.all?).to eq(true)
      expect(out.abs.max).to be_between(0.05, 4)
    end

    it 'follows CC 71 in lp4 (a sine at the cutoff: -12 dB at 0, +33.8 dB at 127)' do
      levels = [0, 64, 127].map { |raw|
        v = notes_for(ev.note_on(69, 1.0), ev.cc_raw(71, raw), ev.cc(99, 0, time: 10r))
        sig = v.hz.sine.lp4(440, resonance: v.reso(0.5))
        60.times.map { sig.sample(800).dup }.reduce(:concatenate)[-4800..].abs.max
      }
      expect(levels[0].to_db).to be_within(0.3).of(-12.04)
      k = MB::Sound::Filter::FourPole.resonance_curve(0.5) * 3.9
      expect(levels[1].to_db).to be_within(0.3).of(-12.04 + 0.5 * 45.84 + 20 * Math.log10((1 + 0.375 * k) / (1 + k))) # over the passband
      expect(levels[2].to_db).to be_within(0.5).of(33.8 - 20 * Math.log10(4.9 / (1 + 0.375 * 3.9)))
    end
  end

  describe 'vibrato' do
    # Returns the min and max of +freq+ in semitones from A4 over 1 s,
    # after +skip+ buffers of 480.
    def swing(freq, skip: 0)
      out = 100.times.map { freq.sample(480).dup }.reduce(:concatenate)[skip * 480..]
      st = (out / 440).to_a.map { |f| 12 * Math.log2(f) }
      [st.min, st.max]
    end

    it 'follows the mod wheel by default, up to 50 cents' do
      [[0, 0], [64, 64 / 127.0 * 0.5], [127, 0.5]].each do |mod, depth|
        v = notes_for(ev.note_on(69), ev.cc_raw(1, mod))
        lo, hi = swing(v.hz.vibrato.freq)
        expect(lo).to be_within(0.01).of(-depth)
        expect(hi).to be_within(0.01).of(depth)
      end
    end

    it 'runs at CC 76 and scales with CC 77' do
      v = notes_for(ev.note_on(69), ev.cc_raw(1, 127), ev.cc_raw(77, 127), ev.cc_raw(76, 0))
      f = v.hz.vibrato.freq
      out = 100.times.map { f.sample(480).dup }.reduce(:concatenate)
      st = (out / 440).to_a.map { |x| 12 * Math.log2(x) }
      expect(st.max).to be_within(0.01).of(1)
      crossings = st.each_cons(2).count { |a, b| a < 0 && b >= 0 }
      expect(crossings).to be_within(1).of(1) # 1.375 Hz for 1 s
    end

    it 'fades in after each note-on with CC 78' do
      v = notes_for(ev.note_on(69), ev.cc_raw(1, 127), ev.cc_raw(78, 127))
      f = v.hz.vibrato.freq
      out = 100.times.map { f.sample(480).dup }.reduce(:concatenate)
      st = (out / 440).to_a.map { |x| 12 * Math.log2(x) }
      expect(st[0...4800].map(&:abs).max).to be < 0.06 # 0.1 s into a 2 s fade
      expect(st[24000..].map(&:abs).max).to be_between(0.1, 0.3)
    end

    it 'takes an explicit rate and depth' do
      v = notes_for(ev.note_on(69))
      lo, hi = swing(v.hz.vibrato(6, depth: 20.cents).freq)
      expect([lo, hi]).to match([be_within(0.005).of(-0.2), be_within(0.005).of(0.2)])
      expect(v.hz.vibrato(6, depth: 20.cents).freq.graph.grep(MB::Sound::Notes::FadeIn)).to eq([])
    end

    it 'works on any Pitch with a rate and depth' do
      f = MB::Sound::A4.vibrato(5, depth: 1.st).freq
      lo, hi = swing(f)
      expect([lo, hi]).to match([be_within(0.01).of(-1), be_within(0.01).of(1)])
      expect { 440.hz.vibrato }.to raise_error(ArgumentError, /rate and depth/)
      expect(440.hz.vibrato(5.hz.lfo.at(4..6), depth: 0.1).tone.sample(100).length).to eq(100)
    end
  end

  describe 'glide' do
    # Note numbers from a glide over +events+ for +buffers+ buffers of 480.
    def glide_numbers(*events, time: 0.05, legato: false, buffers: 60)
      v = notes_for(*events)
      g = MB::Sound::Notes::Glide.new(v.stream, time: time, legato: legato, notes: v)
      buffers.times.map { g.sample(480).dup }.reduce(:concatenate)
    end

    let(:gap) { [ev.note_on(60), ev.note_off(60, time: 1/10r), ev.note_on(72, time: 2/10r)] }
    let(:overlap) { [ev.note_on(60), ev.note_on(72, time: 2/10r), ev.note_off(72, time: 3/10r)] }

    it 'glides every note after the first by default, along a smoothstep in note numbers' do
      n = glide_numbers(*gap)
      expect(n[0]).to eq(60)
      expect(n[9600]).to be_within(1e-4).of(60 + 12 * (1 / 2400.0) ** 2 * (3 - 2 / 2400.0))
      expect(n[9600 + 1199]).to be_within(1e-3).of(66)
      expect(n[9600 + 2399]).to eq(72)
      expect(n[9600 + 2400]).to eq(72)
    end

    it 'glides only legato notes with legato: true' do
      expect(glide_numbers(*gap, legato: true)[9600]).to eq(72)
      n = glide_numbers(*overlap, legato: true)
      expect(n[9600 + 1199]).to be_within(1e-3).of(66)
      # releasing the newest note glides back to the held one
      expect(n[14400 + 1199]).to be_within(1e-3).of(66)
      expect(n[14400 + 2400]).to eq(60)
    end

    it 'treats legato-marked note-ons as legato (allocator mono lanes)' do
      n = glide_numbers(ev.note_on(60), ev.note_off(60, time: 2/10r), ev.note_on(72, time: 2/10r, legato: true), legato: true)
      expect(n[9600 + 1199]).to be_within(1e-3).of(66)
    end

    it 'glides the next note from a :glide event or CC 84, never moving a sounding note' do
      n = glide_numbers(ev.note_on(60), ev.note_off(60, time: 1/10r), ev.glide(48, time: 1/10r), ev.note_on(72, time: 2/10r), legato: true)
      expect(n[4800...9600].to_a.uniq).to eq([60])
      expect(n[9600]).to be_within(1e-3).of(48)
      expect(n[9600 + 1199]).to be_within(1e-3).of(60)

      n = glide_numbers(ev.note_on(60), ev.cc_raw(84, 36, time: 1/10r), ev.note_on(72, time: 2/10r), ev.cc_raw(84, 50, time: 3/10r), legato: true)
      expect(n[4800...9600].to_a.uniq).to eq([60])
      expect(n[9600 + 1199]).to be_within(1e-3).of(54)
      expect(n[14400..].to_a.uniq.last).to eq(72) # the pending 84 waits for a note
    end

    it 'uses CC 5 and CC 65 with :gm' do
      off = glide_numbers(*gap, time: :gm)
      expect(off[9600]).to eq(72)
      on = glide_numbers(ev.cc_raw(65, 127), ev.cc_raw(5, 64), *gap, time: :gm)
      len = (MB::Sound::Notes::GM_CONTROLS[:portamento_time].value(64) * 48000).round
      expect(on[9600 + len / 2 - 1]).to be_within(0.05).of(66)
      expect(on[9600 + len]).to eq(72)
      expect(on[9600 + len - 10]).to be < 72
    end

    it 'holds a from: pitch until the first note, which glides from it' do
      events = [ev.note_on(60, time: 1/10r), ev.note_off(60, time: 2/10r), ev.note_on(72, time: 3/10r)]
      v = notes_for(*events)
      g = MB::Sound::Notes::Glide.new(v.stream, time: 0.05, from: MB::Sound::A4, notes: v)
      n = 80.times.map { g.sample(480).dup }.reduce(:concatenate)
      expect(n[0...4800].to_a.uniq).to eq([69])
      expect(n[4800 + 1199]).to be_within(1e-3).of(64.5)
      expect(n[4800 + 2400]).to eq(60)
      # later notes glide as usual
      expect(n[14400 + 1199]).to be_within(1e-3).of(66)

      # Pitches, note numbers, and time 0 (holds, then jumps)
      g = MB::Sound::Notes::Glide.new(notes_for(*events).stream, time: 0, from: 48, notes: v)
      n = 20.times.map { g.sample(480).dup }.reduce(:concatenate)
      expect(n[4799]).to eq(48)
      expect(n[4800]).to eq(60)

      f = notes_for(*events).hz.glide(50.ms, from: 440.hz).freq
      expect(f.sample(480)[0]).to be_within(1e-6).of(440)
      expect { MB::Sound::Notes::Glide.new(v.stream, time: 0.1, from: 'A4') }.to raise_error(ArgumentError, /start/)
    end

    it 'reads a time node on the note-on sample' do
      n = glide_numbers(*gap, time: 0.1.constant)
      expect(n[9600 + 2399]).to be_within(1e-3).of(66)
    end

    it 'jumps at content jumps' do
      clip = MB::Sound.seq(MB::Sound::C4, MB::Sound::G4).n4.loop
      src = MB::Sound::MIDI::ClipSource.new(clip, transport: transport)
      v = MB::Sound::Notes.new(src)
      g = MB::Sound::Notes::Glide.new(v.stream, time: 0.1, notes: v)
      3.times { g.sample(480) }
      src.start_at(5/16r)
      expect(g.sample(480)[0]).to eq(67)
    end

    it 'glides the frequency of a pitch' do
      v = notes_for(*gap)
      f = v.hz.glide(50.ms).freq
      out = 60.times.map { f.sample(480).dup }.reduce(:concatenate)
      expect(out[9600 + 1199]).to be_within(0.05).of(MB::Sound.tuning.frequency_of(66))
      expect(v.hz.glide(:gm, legato: true).settings[:glide]).to eq([:gm, true])
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
      expect(g.ended?).to eq(false) # the last note-off is at 24000
      expect(g.sample(800)).not_to eq(nil); t.sample(800); n.sample(800)
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
      expect(40.times.count { g.sample(800) }).to eq(36) # 30 buffers of clip, 1 with the last note-off, 5 of tail
    end

    it 'ends with a MIDI file' do
      v = MB::Sound::Notes.new('spec/test_data/c_major.mid')
      g = v.gate
      n = 0
      n += 1 while g.sample(4800) && n < 1000
      expect(g.ended?).to eq(true)
      expect(n.to_f / 10).to be_within(0.6).of(v.stream.music_end)
    end

    it 'renders a whole voice through a Session to the end of a clip' do
      v = MB::Sound::Notes.new(MB::Sound.seq(MB::Sound::C3, MB::Sound::E3, MB::Sound::G3).n8) # 0.75 s at 120 BPM
      sig = v.hz.glide(30.ms).vibrato.saw.filter(:lowpass, cutoff: v.cutoff(600), quality: v.quality(2)) * v.amp_env(0.01, 0.2, 0.5, 0.3)
      MB::Sound.render(tmp_path('voice.flac'), sig)
      d = MB::Sound.read(tmp_path('voice.flac'))
      expect(d[0].length / 48000.0).to be_between(1.0, 1.2) # notes plus the 0.3 s release
      expect(d[0].abs.max).to be_between(0.1, 1)
    ensure
      MB::Sound.rewind
    end

    it 'ends its envelopes together, once the last one is idle after the stream ends' do
      v = MB::Sound::Notes.new(MIDIListSource.new(ev.note_on(60), ev.note_off(60, time: 0.05r)))
      short = v.env(0, 0.01, 0.5, 0.02)
      long = v.env(0, 0.01, 0.5, 0.2)
      ends = [nil, nil]
      100.times do |n|
        [short, long].each_with_index { |e, i| ends[i] ||= n if ends[i].nil? && e.sample(480).nil? }
      end
      expect(ends[0]).to eq(ends[1]) # the short envelope waits for the long one
      expect(ends[1] * 0.01).to be_within(0.03).of(0.05 + 0.2)
    end

    it 'never ends looping clips' do
      g = clip_notes(clip.loop).gate
      100.times { expect(g.sample(800)).not_to eq(nil) }
      expect(g.ended?).to eq(false)
    end
  end

  describe 'sustain pedals' do
    let(:pedaled) {
      [
        ev.cc_raw(64, 127), ev.note_on(60, time: 1/100r), ev.note_off(60, time: 1/20r),
        ev.cc_raw(64, 0, time: 1/10r), ev.cc_raw(67, 127, time: 1/10r), ev.note_on(62, 1, time: 3/20r),
      ]
    }

    it 'holds notes with the sustain pedal and softens them with the soft pedal by default' do
      v = notes_for(*pedaled)
      expect(v.sustain?).to eq(true)
      out = run({ gate: v.gate, velocity: v.velocity }, buffer: 480, buffers: 20)
      expect(out[:gate][480...4800].to_a.uniq).to eq([1]) # held past the note-off at 2400
      expect(out[:gate][4800...7200].to_a.uniq).to eq([0]) # released when the pedal lifts
      expect(out[:velocity][-1]).to be_within(1e-6).of(MB::Sound::MIDI::Transform::Sustain::SOFT_VELOCITY)
    end

    it 'ignores the pedals with sustain: false' do
      v = MB::Sound::Notes.new(MIDIListSource.new(pedaled, ev.cc(99, 0, time: 1000r)), sustain: false)
      expect(v.sustain?).to eq(false)
      expect(v.note_stream).to equal(v.stream)
      out = run({ gate: v.gate, velocity: v.velocity }, buffer: 480, buffers: 20)
      expect(out[:gate][2400...4800].to_a.uniq).to eq([0])
      expect(out[:velocity][-1]).to eq(1)
    end

    it 'keeps #stream as given, for sources and synths, while note nodes read the pedaled stream' do
      v = notes_for(*pedaled)
      expect(v.stream.source).to be_a(MIDIListSource)
      expect(MB::Sound::MIDI::Stream.for(v)).to equal(v.stream)
      g = v.gate
      expect(v.note_stream).not_to equal(v.stream)
      expect(v.note_stream.source).to be_a(MB::Sound::MIDI::Transform::Sustain)
      expect(g.stream).to equal(v.note_stream)
    end

    it 'lists the pedals in control_specs only while note nodes use them' do
      v = notes_for(*pedaled)
      v.mod
      expect(v.control_specs.map(&:number)).to eq([1])
      g = v.gate
      expect(v.control_specs.map(&:number)).to eq([1, 64, 66, 67])
      expect(MB::Sound::Notes.new(v.stream, sustain: false).control_specs.map(&:number)).to eq([1])
      g.sample(480)
    end

    it 'makes the pedaled stream only for note nodes, so controllers alone never hold the input back' do
      v = notes_for(*pedaled)
      m = v.mod
      50.times { m.sample(480) }
      expect(v.stream.pending_count).to eq(0)

      # A pedaled stream made now starts where the input has been read
      expect(v.gate.stream.source.position).to eq(m.cursor)
    end

    it 'skips the transform for clip outputs' do
      n = MB::Sound.seq(MB::Sound::C4).n8.loop.notes(transport: transport)
      expect(n.sustain?).to eq(false)
      expect(n.gate.stream).to equal(n.stream)
    end
  end

  describe '#idle? and #held?' do
    it 'are busy while a note is held, with only a gate' do
      v = notes_for(ev.note_on(60), ev.note_off(60, time: 1/10r))
      expect(v.idle?).to eq(true)
      g = v.gate
      g.sample(480)
      expect(v.held?).to eq(true)
      expect(v.idle?).to eq(false)
      10.times { g.sample(480) } # past the note-off at 4800
      expect(v.held?).to eq(false)
      expect(v.idle?).to eq(true)
    end

    it 'wait for both held notes and envelopes' do
      v = notes_for(ev.note_on(60), ev.note_off(60, time: 1/10r))
      e = v.env(0, 0.01, 1, 0.1, curve: :linear)
      e.sample(480)
      expect(v.idle?).to eq(false)
      expect(v.level).to be > 0.9
      10.times { e.sample(480) }
      expect(v.held?).to eq(false)
      expect(v.idle?).to eq(false) # releasing
      20.times { e.sample(480) }
      expect(v.idle?).to eq(true)
      expect(v.level).to eq(0)
    end

    it 'counts overlapping notes on one key' do
      v = notes_for(ev.note_on(60), ev.note_on(60, time: 1/100r), ev.note_off(60, time: 2/100r), ev.note_off(60, time: 3/100r))
      n = v.number
      n.sample(1200) # both note-ons and the first note-off
      expect(v.held?).to eq(true)
      n.sample(480)
      expect(v.held?).to eq(false)
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
