RSpec.describe('Unison mix, per-copy settings, and swarms', :aggregate_failures) do
  let(:ev) { MB::Sound::MIDI::Event }

  def render(node, buffers: 10, buffer: 480)
    if node.channel_count > 1
      out = node.outputs.map { [] }
      buffers.times { node.outputs.each_with_index { |o, i| out[i] << o.sample(buffer).dup } }
      out.map { |l| l.reduce(:concatenate) }
    else
      buffers.times.map { node.sample(buffer).dup }.reduce(:concatenate)
    end
  end

  def rms(data)
    Math.sqrt((data.cast_to(Numo::DFloat) ** 2).mean)
  end

  def mixer(node)
    node.outputs.first.sources[:mixer]
  end

  def count_of(node, klass)
    node.graph.count { |n| n.is_a?(klass) }
  end

  # A Notes on a list of MIDI events (times in seconds).
  def notes_for(*events)
    MB::Sound::Notes.new(MIDIListSource.new(events.flatten, [ev.cc(99, 0, time: 1000r)]))
  end

  describe 'mix' do
    it 'picks the copy nearest the pitch (odd) or the two nearest (even) as center copies' do
      expect(MB::Sound::Unison.center_copies([-0.2, -0.1, 0, 0.1, 0.2])).to eq([2])
      expect(MB::Sound::Unison.center_copies([-0.3, -0.1, 0.1, 0.3])).to eq([1, 2])
      expect(MB::Sound::Unison.center_copies([-0.3, 0.02, 0.1])).to eq([1])
      expect(MB::Sound::Unison.center_copies([0.0])).to eq([0])
      expect(MB::Sound::Unison.center_copies([-0.1, 0.1])).to eq([0, 1])
    end

    it 'leaves the default (mix 1) exactly as without a mix' do
      MB::Sound.seed(3)
      a = render(110.hz.unison(7, detune: 25.cents, spread: 0.6))
      MB::Sound.seed(3)
      b = render(110.hz.unison(7, detune: 25.cents, spread: 0.6, mix: 1))
      expect(a).to eq(b)

      m = mixer(110.hz.unison(7, detune: 25.cents))
      expect(m.gains).to eq([Array.new(7, 1 / Math.sqrt(7))])
      expect(m.centers).to eq([3])
    end

    it 'plays the side copies at the mix level, normalized by the weights' do
      m = mixer(110.hz.unison(5, detune: 20.cents, layout: :even, mix: 0.5))
      g = 1 / Math.sqrt(1 + 4 * 0.25)
      expect(m.gains[0]).to match([0.5 * g, 0.5 * g, g, 0.5 * g, 0.5 * g].map { |v| be_within(1e-12).of(v) })

      peak = mixer(110.hz.unison(4, detune: 20.cents, layout: :even, mix: 0.25, normalize: :peak))
      expect(peak.gains[0]).to match([0.25, 1, 1, 0.25].map { |v| be_within(1e-12).of(v / 2.5) })

      fixed = mixer(110.hz.unison(3, detune: 20.cents, mix: 0, normalize: 1))
      expect(fixed.gains[0]).to eq([0.0, 1.0, 0.0])
    end

    it 'is the center copy alone at mix 0 (odd count)' do
      one = render(110.hz.saw.with_phase(0))
      only = render(110.hz.unison(5, detune: 20.cents, layout: :even, mix: 0, phase: 0))
      expect((only - one).abs.max).to be < 1e-6
    end

    it 'keeps the loudness about the same while the mix moves' do
      levels = [0, 0.3, 0.6, 1].map { |m| rms(render(110.hz.unison(7, detune: 30.cents, mix: m) { |p| p.sine }, buffers: 200)) }
      expect(levels).to all(be_within(0.1).of(Math.sqrt(0.5)))
    end

    it 'takes a node, clipped to 0..1, and works in stereo' do
      node = 110.hz.unison(5, detune: 20.cents, spread: 1, mix: 0.5.hz.lfo.at(-0.5..1.5))
      l, r = render(node, buffers: 50)
      expect(rms(l)).to be > 0.3
      expect(rms(r)).to be > 0.3

      const = render(110.hz.unison(5, detune: 20.cents, layout: :even, phase: 0, mix: 0.4.constant))
      num = render(110.hz.unison(5, detune: 20.cents, layout: :even, phase: 0, mix: 0.4))
      expect((const - num).abs.max).to be < 1e-6
    end

    it 'rejects bad values' do
      expect { 110.hz.unison(3, mix: 1.5) }.to raise_error(ArgumentError, /mix/)
      expect { 110.hz.unison(3, mix: :loud) }.to raise_error(ArgumentError, /mix/)
    end
  end

  describe 'timeline lock' do
    it 'keeps tempo-synced pitches synced through fixed transposes' do
      t = 1.beat.hz.transpose(12).sine
      expect(t.timeline).to be_a(MB::Sound::Sequence::TempoNode)
      expect(t.timeline.parent).to be_a(MB::Sound::Sequence::TempoNode)
      expect(t.timeline.duration.whole_notes).to eq(1r / 8)
      expect(1.beat.hz.transpose(0.1).sine.timeline).not_to be_nil
      expect(1.beat.hz.transpose(0.1).frequency).to be_within(1e-12).of(1.beat.hz.frequency * 2 ** (0.1 / 12))
    end

    it 'locks fixed-detune unison copies of tempo pitches to the timeline' do
      node = 1.beat.hz.unison(3, detune: 10.cents)
      tones = node.graph.select { |n| n.is_a?(MB::Sound::Tone) }
      expect(tones.length).to eq(3)
      expect(tones.map(&:timeline)).to all(be_a(MB::Sound::Sequence::TempoNode))
    end

    it 'jumps transposed tempo tones to their timeline phase' do
      base = MB::Sound::Sequence::TempoNode.new(1.beat, mode: :hz, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
      ph = MB::Sound::Pitch.new(base).transpose(12).phasor
      tempo = ph.timeline
      expect(tempo.parent).to equal(base)
      tempo.start_at(2.3r / 4) # 2.3 beats: 4.6 cycles of an eighth
      expect(ph.sample(1)[0]).to be_within(1e-6).of(0.6)

      detuned = MB::Sound::Pitch.new(base).transpose(0.5).phasor
      detuned.timeline.start_at(2.3r / 4)
      expect(detuned.sample(1)[0]).to be_within(1e-6).of((2.3 * 2 ** (0.5 / 12)) % 1)
    end

    it 'freewheels scaled nodes with their parent' do
      base = MB::Sound::Sequence::TempoNode.new(1.beat, mode: :hz)
      s = base.scaled(2)
      expect(s.freewheel?).to eq(false)
      base.freewheel
      expect(s.freewheel?).to eq(true)
      expect { base.scaled(0) }.to raise_error(ArgumentError)
    end
  end

  describe 'Pitch#transpose by a node' do
    it 'shifts plain pitches by semitones from the node' do
      p = 220.hz.transpose(12.constant)
      expect(render(p.freq, buffers: 1).to_a.uniq).to eq([440.0])
    end

    it 'adds the node to Notes pitches' do
      n = notes_for(ev.note_on(57, 100, time: 0r))
      f = n.hz.transpose(12.constant).freq
      out = render(f, buffers: 2)
      expect(out[-1]).to be_within(1e-3).of(440)
    end
  end

  describe 'shared glides' do
    let(:events) { [ev.note_on(57, 100, time: 0r), ev.note_on(64, 100, time: 0.05r), ev.note_on(60, 100, time: 0.1r)] }

    it 'builds one Glide for copies with the same glide settings (fixed or node detune, before or inside the block)' do
      n = notes_for(events)
      expect(count_of(n.hz.unison(5, detune: 15.cents) { |p| p.glide(50.ms).saw }, MB::Sound::Notes::Glide)).to eq(1)

      n = notes_for(events)
      expect(count_of(n.hz.glide(50.ms).unison(5, detune: 15.cents), MB::Sound::Notes::Glide)).to eq(1)

      n = notes_for(events)
      expect(count_of(n.hz.unison(5, detune: n.velocity * 0.3) { |p| p.glide(50.ms).saw }, MB::Sound::Notes::Glide)).to eq(1)

      n = notes_for(events)
      expect(count_of(n.hz.unison(5, detune: 15.cents) { |p, i| p.glide((i + 1) * 20.ms).saw }, MB::Sound::Notes::Glide)).to eq(5)
    end

    it 'renders shared glides exactly like separate ones' do
      MB::Sound.seed(2)
      shared = render(notes_for(events).hz.unison(5, detune: 15.cents) { |p| p.glide(0.03).saw }, buffers: 20)
      MB::Sound.seed(2)
      # Different keys (1e-12 s apart), the same glide length in samples
      separate = render(notes_for(events).hz.unison(5, detune: 15.cents) { |p, i| p.glide(0.03 + i * 1e-12).saw }, buffers: 20)
      expect(shared).to eq(separate)
    end
  end

  describe 'Notes settings on node-detune copies' do
    let(:events) { [ev.note_on(57, 100, time: 0r), ev.note_on(69, 100, time: 0.1r)] }

    def copies_for(n, count = 5, &block)
      seen = []
      node = n.hz.unison(count, detune: 0.2.constant, layout: :even) { |p, i| q = block.call(p, i); seen << q; q.saw }
      [node, seen]
    end

    it 'glides each copy with its own time, following the detune exactly' do
      n = notes_for(events)
      node, seen = copies_for(n) { |p, i| p.glide((i + 1) * 20.ms) }
      expect(seen).to all(be_a(MB::Sound::Notes::NotePitch))
      expect(count_of(node, MB::Sound::Notes::Glide)).to eq(5)

      freqs = seen.map(&:freq)
      out = freqs.map { [] }
      30.times { freqs.each_with_index { |f, i| out[i] << f.sample(480).dup } }
      out = out.map { |l| l.reduce(:concatenate).cast_to(Numo::DFloat) }

      # Before the second note: A3 detuned by fraction × 20 cents
      [-1, -0.5, 0, 0.5, 1].each_with_index do |a, i|
        expect(out[i][4000]).to be_within(0.01).of(220 * 2 ** (a * 0.2 / 12))
      end

      # The second note at 4800: copy i glides an octave up over (i + 1) ×
      # 20 ms, halfway (in pitch) at half the time
      5.times do |i|
        a = [-1, -0.5, 0, 0.5, 1][i] * 0.2
        half = 4800 + (i + 1) * 480
        arrive = 4800 + (i + 1) * 960
        expect(12 * Math.log2(out[i][half - 1] / 220)).to be_within(0.1).of(6 + a)
        expect(out[i][arrive + 10]).to be_within(0.05).of(440 * 2 ** (a / 12))
      end
      expect(out.map { |o| o.abs.max }).to all(be > 0)
    end

    it 'takes bend ranges, vibrato, and node transposes per copy' do
      n = notes_for(ev.note_on(57, 100, time: 0r), ev.bend(1.0, time: 0.02r))
      node, seen = copies_for(n, 3) { |p, i| i == 0 ? p.bend_range(12) : (i == 1 ? p.vibrato(6, depth: 50.cents) : p.transpose(12.constant)) }
      expect(seen).to all(be_a(MB::Sound::Notes::NotePitch))
      f = seen.map(&:freq)
      out = f.map { [] }
      10.times { f.each_with_index { |x, i| out[i] << x.sample(480).dup } }
      out = out.map { |l| l.reduce(:concatenate).cast_to(Numo::DFloat) }
      expect(out[0][-1]).to be_within(0.05).of(440 * 2 ** (-0.2 / 12))           # full bend up an octave
      expect(out[1].max / out[1].min).to be > 2 ** (0.8 / 12)                     # vibrato ±50 cents on 2 st of bend
      expect(out[2][-1]).to be_within(0.05).of(220 * 2 ** ((12 + 2 + 0.2) / 12)) # +12 from the node, 2 st bend
      expect(render(node).abs.max).to be > 0
    end

    it 'keeps plain copies on the Detune node and shares it' do
      n = notes_for(events)
      node, seen = copies_for(n) { |p| p }
      expect(seen).to all(be_a(MB::Sound::Unison::CopyPitch))
      expect(count_of(node, MB::Sound::Unison::Detune)).to eq(1)

      # Copies transposed by a number stay copies and can still glide
      n = notes_for(events)
      _, seen = copies_for(n) { |p| p.transpose(12).glide(20.ms) }
      expect(seen).to all(be_a(MB::Sound::Notes::NotePitch))
      expect(seen.map { |s| s.settings[:transpose] }).to all(eq(12.0))
    end

    it 'builds no Detune node when every copy takes its own settings' do
      n = notes_for(events)
      node, = copies_for(n) { |p| p.glide(20.ms) }
      expect(count_of(node, MB::Sound::Unison::Detune)).to eq(0)
    end

    it 'explains glides on copies of other pitches' do
      expect { 220.hz.unison(3, detune: 0.1.constant) { |p| p.glide(0.1).saw } }.to raise_error(ArgumentError, /Notes pitch/)
    end
  end

  describe 'per-copy values' do
    let(:events) { [ev.note_on(57, 100, time: 0r)] }

    def glide_times(n, count = 5, **opts, &block)
      n.hz.unison(count, detune: 15.cents, layout: :even, **opts) { |p, i| block.call(p, i).saw }
      n.send(:instance_variable_get, :@nodes).values.filter_map { |r| r.__getobj__ rescue nil }.grep(MB::Sound::Notes::Glide).map(&:time)
    end

    it 'spreads values evenly by copy with spread(a..b)' do
      times = glide_times(notes_for(events)) { |p| p.glide(MB::Sound.spread(0.1..0.5)) }
      expect(times.sort).to match([0.1, 0.2, 0.3, 0.4, 0.5].map { |v| be_within(1e-12).of(v) })

      times = glide_times(notes_for(events), 3) { |p| p.glide(MB::Sound.spread(100.ms..300.ms)) }
      expect(times.sort).to match([0.1, 0.2, 0.3].map { |v| be_within(1e-12).of(v) })
    end

    it 'draws random values from Ranges, repeatably from the seed' do
      a = glide_times(notes_for(events), seed: 4) { |p| p.glide(0.1..0.5) }
      b = glide_times(notes_for(events), seed: 4) { |p| p.glide(0.1..0.5) }
      c = glide_times(notes_for(events), seed: 5) { |p| p.glide(0.1..0.5) }
      expect(a.length).to eq(5)
      expect(a).to eq(b)
      expect(a).not_to eq(c)
      expect(a).to all(be_between(0.1, 0.5))
    end

    it 'takes one value per copy from channels(...)' do
      times = glide_times(notes_for(events), 3) { |p| p.glide(MB::Sound.channels(0.1, 0.2)) }
      expect(times.sort).to eq([0.1, 0.2])  # copies 0 and 2 share 0.1
    end

    it 'transposes plain copies per copy' do
      seen = []
      220.hz.unison(3, detune: 0, layout: :even) { |p| seen << p.transpose(MB::Sound.spread(0..24)); p.saw }
      expect(seen.map(&:frequency)).to match([220, 440, 880].map { |v| be_within(1e-9).of(v) })
    end

    it 'refuses per-copy values outside a unison' do
      expect { 220.hz.transpose(0..12) }.to raise_error(ArgumentError, /unison/)
      expect { notes_for(events).hz.glide(MB::Sound.spread(0.1..0.2)) }.to raise_error(ArgumentError, /unison/)
    end
  end

  describe 'Notes::Glide' do
    let(:events) { [ev.note_on(60, 100, time: 0r), ev.note_on(72, 100, time: 0.01r)] }

    def glide_out(**opts)
      n = notes_for(events)
      g = MB::Sound::Notes::Glide.new(n.note_stream, notes: n, **opts)
      render(g, buffers: 4).cast_to(Numo::DFloat)
    end

    it 'overshoots by the given fraction and lands on the target' do
      out = glide_out(time: 0.02, overshoot: 0.1)
      expect(out.max).to be_within(0.02).of(72 + 1.2)
      expect(out[-1]).to eq(72)
      expect(glide_out(time: 0.02).max).to eq(72)
      expect { glide_out(time: 0.02, overshoot: 2) }.to raise_error(ArgumentError, /overshoot/)
    end

    it 'finds the overshoot bump scale' do
      [0.01, 0.1, 0.3].each do |o|
        k = MB::Sound::Notes::Glide.overshoot_k(o)
        peak = (1..9999).map { |j| t = j / 10000.0; t * t * (3 - 2 * t) + k * t**3 * (1 - t)**2 }.max
        expect(peak).to be_within(1e-4).of(1 + o)
      end
    end

    it 'glides the first note from an Interval away' do
      out = glide_out(time: 0.005, from: -12.st)
      expect(out[0]).to be_within(0.1).of(48)
      expect(out[239]).to be_within(1e-3).of(60)
    end
  end

  describe 'Pitch#swarm' do
    it 'lays copies out over chord tones' do
      expect(MB::Sound::Unison.chord_offsets(6, [0, 7, 12], 10.cents, layout: :even).map { |v| v.round(9) }).to eq([-0.1, 0.1, 6.9, 7.1, 11.9, 12.1])
      expect(MB::Sound::Unison.chord_offsets(4, [0, 7, 12], 0, layout: :even)).to eq([0.0, 0.0, 7.0, 12.0])
    end

    it 'glides copies with their own times from scattered starts toward the chord' do
      n = notes_for(ev.note_on(50, 100, time: 0r))
      seen = []
      node = n.hz.swarm(6, chord: [0, 12], scatter: 1.oct, glide: 0.05..0.2, overshoot: 0..0.1, seed: 3) { |p| seen << p; p.sine }
      expect(node.channel_count).to eq(2)
      expect(count_of(node, MB::Sound::Notes::Glide)).to eq(6)

      f = seen.map(&:freq)
      out = f.map { [] }
      30.times { f.each_with_index { |x, i| out[i] << x.sample(480).dup } }
      out = out.map { |l| l.reduce(:concatenate).cast_to(Numo::DFloat) }
      starts = out.map { |o| o[0] }
      expect(starts.uniq.length).to eq(6)
      expect(starts.map { |s| 12 * Math.log2(s / MB::Sound.tuning.frequency_of(50)) }).to all(be_between(-12.01, 24.01))
      ends = out.map { |o| 12 * Math.log2(o[-1] / MB::Sound.tuning.frequency_of(50)) }.sort
      expect(ends[0..2]).to all(be_within(0.16).of(0))
      expect(ends[3..5]).to all(be_within(0.16).of(12))
      expect(render(node, buffers: 5).map { |c| c.abs.max }).to all(be > 0)
    end

    it 'drifts and works on fixed pitches without glides' do
      node = 110.hz.swarm(5, glide: nil, drift: 20.cents, spread: 0)
      expect(node.channel_count).to eq(1)
      expect(count_of(node, MB::Sound::GraphNode::SemitoneShift)).to eq(5)
      expect(rms(render(node, buffers: 20))).to be > 0.3
      expect { 110.hz.swarm(5) }.not_to raise_error
      expect { 110.hz.swarm(5, glide: 0.1) }.to raise_error(ArgumentError, /Notes pitch/)
    end

    it 'repeats from the seed' do
      mk = -> { MB::Sound.seed(1); render(notes_for(ev.note_on(50, 100, time: 0r)).hz.swarm(4, chord: [0, 7], scatter: 5.st, drift: 10.cents), buffers: 5) }
      expect(mk.call).to eq(mk.call)
    end
  end
end
