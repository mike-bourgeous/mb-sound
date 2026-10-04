RSpec.describe(MB::Sound::Sequence::Clip) do
  let(:c4) { MB::Sound::C4 }
  let(:e4) { MB::Sound::E4 }

  def times(clip)
    clip.events.map { |e| [e.value, e.start, e.length] }
  end

  describe '#|' do
    it 'plays clips one after another' do
      c = c4.n8 | e4.n4
      expect(times(c)).to eq([[60, 0, 1/8r], [64, 1/8r, 1/4r]])
      expect(c.length).to eq(3/8r)
    end

    it 'includes trailing rests in the length' do
      expect((c4.n8 | MB::Sound.rest.n8).length).to eq(1/4r)
    end
  end

  describe '#&' do
    it 'plays clips at the same time, with the longer length' do
      c = c4.n8 & e4.n2
      expect(times(c)).to eq([[60, 0, 1/8r], [64, 0, 1/2r]])
      expect(c.length).to eq(1/2r)
    end
  end

  describe '#repeat and #*' do
    it 'repeats the clip' do
      expect(times(c4.n8 * 3)).to eq([[60, 0, 1/8r], [60, 1/8r, 1/8r], [60, 1/4r, 1/8r]])
      expect(c4.n8.repeat(3).length).to eq(3/8r)
    end

    it 'rejects non-positive counts' do
      expect { c4.n8 * 0 }.to raise_error(ArgumentError)
      expect { c4.n8 * 1.5 }.to raise_error(ArgumentError)
    end

    it 'warns that a repeated looping clip stops looping' do
      clip = (c4.n8 | e4.n8).loop
      expect(clip).to receive(:warn).with(/stop looping/).twice
      expect(clip.repeat(2)).not_to be_looping
      expect(clip * 2).not_to be_looping
    end

    it 'does not warn for non-looping clips or when splitting voices' do
      clip = (c4.n8 | e4.n8 | c4.n8).loop
      expect_any_instance_of(described_class).not_to receive(:warn)
      (c4.n8 | e4.n8).repeat(2)
      clip.synth(voices: 2) { 1.constant }
    end
  end

  describe '#fill' do
    it 'repeats a short clip to fill a span' do
      c = c4.n32.fill(4)
      expect(c.events.length).to eq(8)
      expect(c.length).to eq(1/4r)
    end

    it 'cuts the last repetition short' do
      c = (c4.n8 | e4.n8).fill(3/8r)
      expect(times(c)).to eq([[60, 0, 1/8r], [64, 1/8r, 1/8r], [60, 1/4r, 1/8r]])
    end
  end

  describe '#roll' do
    it 'splits each event into hits of the given length' do
      c = c4.n4.roll(32)
      expect(c.events.map(&:start)).to eq((0...8).map { |i| Rational(i, 32) })
      expect(c.events.map(&:length).uniq).to eq([1/32r])
      expect(c.length).to eq(1/4r)
    end

    it 'shortens the last hit if the event does not divide evenly' do
      c = c4.n4.roll(3/32r)
      expect(c.events.map(&:length)).to eq([3/32r, 3/32r, 1/16r])
    end

    it 'can ramp velocity' do
      c = c4.n4.roll(16, velocity: 0.2..0.8)
      expect(c.events.map(&:velocity)).to all(be_a(Float))
      expect(c.events.map { |e| e.velocity.round(3) }).to eq([0.2, 0.4, 0.6, 0.8])
    end
  end

  describe '#ratchet' do
    it 'splits each event into equal hits' do
      c = c4.n4.ratchet(3)
      expect(c.events.map(&:start)).to eq([0, 1/12r, 1/6r])
      expect(c.events.map(&:length)).to eq([1/12r] * 3)
    end
  end

  describe '#stretch and modifiers' do
    it 'multiplies times and lengths' do
      c = (c4.n8 | e4.n8).stretch(2)
      expect(times(c)).to eq([[60, 0, 1/4r], [64, 1/4r, 1/4r]])
      expect(c.length).to eq(1/2r)
    end

    it 'has dotted and triplet shortcuts' do
      expect((c4.n8 | e4.n8).d.length).to eq(3/8r)
      expect((c4.n8 | e4.n8).t.length).to eq(1/6r)
    end
  end

  describe '#transpose' do
    it 'shifts values' do
      expect((c4.n8 | e4.n8).transpose(-12).events.map(&:value)).to eq([48, 52])
    end
  end

  describe '#reverse' do
    it 'plays events backward, mirroring the rhythm' do
      c = MB::Sound.seq(c4, e4, MB::Sound::G4.n4, nil).n8.reverse
      expect(times(c)).to eq([[67, 1/8r, 1/4r], [64, 3/8r, 1/8r], [60, 1/2r, 1/8r]])
      expect(c.length).to eq(5/8r)
    end

    it 'keeps chords together, looping, and events that hang over the end inside the clip' do
      c = (MB::Sound.seq(c4.n4) & MB::Sound.seq(e4.n4)).loop.reverse
      expect(times(c)).to contain_exactly([60, 0, 1/4r], [64, 0, 1/4r])
      expect(c).to be_looping
      long = MB::Sound::Sequence::Event.new(start: 0r, length: 1/4r, value: 60, velocity: 0.75)
      expect(times(MB::Sound::Sequence::Clip.new([long], length: 1/8r).reverse)).to eq([[60, 0, 1/4r]])
    end

    it 'is also available as retrograde' do
      expect(times(MB::Sound.seq(c4, e4).n8.retrograde)).to eq([[64, 0, 1/8r], [60, 1/8r, 1/8r]])
    end
  end

  describe '#permute' do
    let(:notes) { MB::Sound.seq(c4, e4.n4, MB::Sound::G4, MB::Sound::B4.n8.vel(1)).n8 }

    it 'moves notes to other events in a given order, keeping the rhythm' do
      c = notes.permute([3, 2, 0, 1])
      expect(times(c)).to eq([[71, 0, 1/8r], [67, 1/8r, 1/4r], [60, 3/8r, 1/8r], [64, 1/2r, 1/8r]])
      expect(c.events.map(&:velocity)).to eq([1, 0.75, 0.75, 0.75])
    end

    it 'shuffles repeatably from the seed' do
      a = notes.permute.events.map(&:value)
      expect(notes.permute.events.map(&:value)).to eq(a)
      expect(a.sort).to eq([60, 64, 67, 71])
      others = (1..10).map { |s| notes.permute(seed: s).events.map(&:value) }
      expect(others.uniq.length).to be > 1
      expect(notes.shuffle(seed: 3).events.map(&:value)).to eq(notes.permute(seed: 3).events.map(&:value))
    end

    it 'rejects orders that are not permutations' do
      expect { notes.permute([0, 0, 1, 2]) }.to raise_error(ArgumentError, /indices 0 to 3/)
      expect { notes.permute([0, 1]) }.to raise_error(ArgumentError, /indices/)
    end

    it 'remembers its source, and replays on another clip' do
      c = notes.loop
      expect(c.reverse.source).to equal(c)
      p = c.permute([1, 0, 2, 3])
      expect(p.source).to equal(c)
      other = MB::Sound.seq(MB::Sound::D4, MB::Sound::F4, MB::Sound::A4, MB::Sound::C5).n8.loop
      expect(p.rederive(other).events.map(&:value)).to eq([65, 62, 69, 72])
      expect(c.reverse.rederive(other).events.map(&:value)).to eq([72, 69, 65, 62])
    end
  end

  describe '#loop' do
    it 'returns a looping copy' do
      c = c4.n8.loop
      expect(c).to be_looping
      expect(c4.n8).not_to be_looping
    end

    it 'rejects empty clips' do
      expect { MB::Sound::Sequence::Clip.new([]).loop }.to raise_error(ArgumentError, /positive length/)
    end
  end

  describe '#synth' do
    let(:chords) { MB::Sound.seq(MB::Sound::A2, MB::Sound::F2, MB::Sound::C3, MB::Sound::G2).n1 }

    # Renders +frames+ samples of +node+ in 800-sample buffers (nil buffers
    # end it early).
    def render(node, frames)
      Array.new(frames / 800) { node.sample(800)&.dup }.compact.reduce(:concatenate)
    end

    it 'returns a Synth on the clip with Notes for each lane and the lane index' do
      yielded = []
      s = chords.synth(voices: 2) { |v, idx| yielded << [v.class, idx]; v.number * v.gate }
      expect(s).to be_a(MB::Sound::Synth)
      expect(s.voices).to eq(2)
      expect(yielded).to eq(Array.new(4) { |i| [MB::Sound::Notes, i] }) # 2 voices + 2 spares
      expect(s.graph.grep(MB::Sound::MIDI::ClipSource).map(&:clip)).to eq([chords])
    end

    it 'passes options to the synth' do
      s = chords.synth(voices: 3, spares: 0) { |v| v.gate }
      expect(s.lanes.length).to eq(3)
    end

    it 'gives notes to voices at runtime, so chords play on different voices' do
      transport = MB::Sound::Sequence::Transport.new(bpm: 240) # a whole note is 1 second
      chord = (MB::Sound::C3.n1 & MB::Sound::G3.n1)
      s = MB::Sound::Synth.new(chord.stream(transport: transport), voices: 2, tail: 0) { |v| v.number * v.gate }
      data = render(s, 4800)
      expect(data[100]).to eq(MB::Sound::C3.number + MB::Sound::G3.number)
      expect(s.notes.map { |n| n.number.value }.first(2)).to contain_exactly(MB::Sound::C3.number, MB::Sound::G3.number)
    end

    it 'mixes the voice graphs together' do
      g = chords.synth(voices: 2, spares: 0) { |_, idx| (idx + 1).constant }
      expect(g.sample(10)[0]).to eq(3)
    end

    it 'mixes stereo pairs per channel' do
      g = chords.synth(voices: 2, spares: 0) { |_, idx| [(idx + 1).constant, 10.constant] }
      expect(g).to be_a(MB::Sound::GraphNode::Channels)
      expect(g.length).to eq(2)
      expect([g[0].sample(10)[0], g[1].sample(10)[0]]).to eq([3, 20])
    end

    it 'lets one voice release while the next note attacks on another, and ends after the last release' do
      transport = MB::Sound::Sequence::Transport.new(bpm: 240) # a whole note is 1 second
      g = MB::Sound.seq(MB::Sound::C3, MB::Sound::E3).n1.stream(transport: transport)
      s = MB::Sound::Synth.new(g, voices: 2, tail: 0) { |v| v.env(0.01, 0.01, 1, 0.5, sensitivity: 1..1, curve: :linear) }
      data = render(s, 48000 * 4)
      # Just after the second note starts, the first is still releasing
      expect(data[47000]).to be_within(0.01).of(1)
      expect(data[48000 + 480]).to be > 1.5
      # Two seconds of notes plus half a second of release
      expect(data.length).to be_between(120000, 120000 + 1600)
    end

    it 'requires a block' do
      expect { chords.synth }.to raise_error(ArgumentError, /block/)
    end
  end

  describe 'output methods' do
    let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) } # an eighth note is 12000 samples
    let(:clip) { MB::Sound.seq(MB::Sound::C3, nil).n8 | MB::Sound.seq(MB::Sound::E3).n8.vel(1.0) }

    def render(node, frames)
      Array.new(frames / 800) { node.sample(800)&.dup }.compact.reduce(:concatenate)
    end

    it 'plays the clip through Notes on a new ClipSource stream each time' do
      s1 = clip.stream(transport: transport)
      expect(s1).to be_a(MB::Sound::MIDI::Stream)
      expect(s1.source).to be_a(MB::Sound::MIDI::ClipSource)
      expect(s1.source.clip).to equal(clip)
      expect(clip.stream.source).not_to equal(clip.stream.source)
      expect(clip.notes).to be_a(MB::Sound::Notes)
    end

    it 'has a gate, triggers, note numbers, and velocities on exact samples' do
      gate = render(clip.gate(transport: transport), 36000)
      expect(gate[0...12000].to_a.uniq).to eq([1])
      expect(gate[12000...24000].to_a.uniq).to eq([0])
      expect(gate[24000...36000].to_a.uniq).to eq([1])

      trig = render(clip.trigger(transport: transport), 36000)
      expect(trig.ne(0).where.to_a).to eq([0, 24000])
      expect(trig[24000]).to eq(1)

      num = render(clip.number(transport: transport), 36000)
      expect([num[0], num[23999], num[24000]]).to eq([48, 48, 52])

      vel = render(clip.velocity(range: 1.0..2.0, transport: transport), 36000)
      expect(vel[0]).to be_within(1e-6).of(1 + MB::Sound::Sequence::Clip::DEFAULT_VELOCITY)
      expect(vel[24000]).to be_within(1e-6).of(2)
    end

    it 'has a pitch, a frequency node, and a period' do
      expect(clip.hz).to be_a(MB::Sound::Notes::NotePitch)
      expect(clip.tone).to be_a(MB::Sound::Notes::NotePitch)
      expect(render(clip.freq(transport: transport), 1600)[0]).to be_within(1e-3).of(MB::Sound::C3.frequency)
      expect(render(clip.period(transport: transport), 1600)[0]).to be_within(1e-6).of(1.0 / MB::Sound::C3.frequency)
      expect(render(clip.tone(transport: transport).ramp.at(1), 4800).abs.max).to be > 0.9
    end

    it 'has envelopes with Envelope options that end after a non-looping clip' do
      env = clip.env(0.001, 0.01, 1, 0.1, curve: :linear, sensitivity: 1..1, transport: transport)
      expect(env).to be_a(MB::Sound::Notes::NoteEnvelope)
      expect(env.gm?).to eq(false)
      data = render(env, 96000)
      expect(data[6000]).to be_within(1e-6).of(1)
      expect(data[12000 + 2400]).to be_within(0.01).of(0.5) # halfway through a linear release
      expect(data[18000]).to eq(0)
      # Ends a little after the last note's release (24000 + 12000 + 4800)
      expect(data.length).to be_between(40800, 40800 + 1600)
    end

    it 'has the other envelope presets' do
      expect(clip.amp_env.sensitivity).to eq(MB::Sound::Envelope::PRESETS[:amp_env][:sensitivity])
      expect(clip.fm_env.sustain).to eq(0)
      expect(clip.filt_env(depth: 3).octaves).to eq(3)
      expect(clip.env(gm: true).gm?).to eq(true)
    end

    it 'keeps a key-synced tone playing through the release of an envelope made separately' do
      g = clip.tone(transport: transport).ramp.at(1) * clip.env(0.001, 0.01, 1, 0.1, transport: transport)
      data = render(g, 96000)
      expect(data[36000 + 2400].abs).to be > 0
      expect(data.length).to be_between(40800, 40800 + 1600)
    end
  end

  describe '#edges' do
    it 'returns note-ons and note-offs within a half-open window' do
      c = c4.n8 | e4.n8
      edges = c.edges(0, 1/8r).map { |t, type, e, _| [t, type, e.value] }
      expect(edges).to eq([[0, :on, 60]])

      edges = c.edges(1/8r, 1).map { |t, type, e, _| [t, type, e.value] }
      expect(edges).to eq([[1/8r, :off, 60], [1/8r, :on, 64], [1/4r, :off, 64]])
    end

    it 'repeats looping clips' do
      c = (c4.n8 | e4.n8).loop
      ons = c.edges(0, 1).select { |_, type| type == :on }.map { |t, _, e, cycle| [t, e.value, cycle] }
      expect(ons).to eq([[0, 60, 0], [1/8r, 64, 0], [1/4r, 60, 1], [3/8r, 64, 1], [1/2r, 60, 2], [5/8r, 64, 2], [3/4r, 60, 3], [7/8r, 64, 3]])
    end

    it 'finds note-offs for notes that last longer than the loop' do
      c = MB::Sound::Sequence::Clip.new([MB::Sound::Sequence::Event.new(start: 0r, length: 3/4r, value: 60, velocity: 1.0)], length: 1/4r, loop: true)
      offs = c.edges(1/2r, 5/4r).select { |_, type| type == :off }.map { |t, _, _, cycle| [t, cycle] }
      expect(offs).to eq([[3/4r, 0], [1, 1]])
    end

    it 'decides probabilistic events the same way for the same cycle and seed' do
      c = MB::Sound.grid(16, '????????????????').loop
      a = c.edges(0, 4).map(&:first)
      b = c.edges(0, 4).map(&:first)
      expect(a).to eq(b)
      expect(a.length).to be_between(40, 88) # about half of 64 hits, on and off

      other = c.loop(seed: 5).edges(0, 4).map(&:first)
      expect(other).not_to eq(a)
    end
  end

  describe '#source, #lineage, and #rederive' do
    let(:bass) { MB::Sound.seq(MB::Sound::C2, MB::Sound::E2).n8.loop }
    let(:other) { MB::Sound.seq(MB::Sound::D2).n4.loop }

    it 'remembers the clip a transform was made from' do
      up = bass.transpose(12)
      expect(up.source).to equal(bass)
      lineage = up.transpose(1).lineage
      expect(lineage[1]).to equal(up)
      expect(lineage[2]).to equal(bass)
    end

    it 'repeats a transform on another clip' do
      up = bass.transpose(12).legato(0.5)
      steps = up.lineage.take_while { |c| !c.equal?(bass) }.reverse
      result = steps.reduce(other) { |c, step| step.rederive(c) }
      expect(times(result)).to eq([[MB::Sound::D3.number, 0, 1/8r]])
      expect(result).to be_looping
    end

    it 'tracks transforms and their aliases on Clips and Seqs' do
      clip = bass | c4.n4 # a plain Clip
      [clip, c4.n4].each do |c|
        expect((c * 2).source).to equal(c)
        expect(c.dotted.source).to equal(c)
        expect(c.vel(0.5).source).to equal(c)
        expect(c.stretch(2).source).to equal(c)
      end
      expect((clip & c4.n4).source).to equal(clip)
      expect(clip.loop.source).to equal(clip)
    end

    it 'has no source for clips made directly' do
      expect(bass.source).not_to be_nil # made by .loop
      expect(c4.n4.source).to be_nil
      expect { c4.n4.rederive(bass) }.to raise_error(ArgumentError, /wasn't made from another clip/)
    end
  end
end
