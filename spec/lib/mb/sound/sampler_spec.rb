RSpec.describe(MB::Sound::Sampler, :aggregate_failures) do
  let(:ones) { MB::Sound::Sample[Numo::SFloat.ones(9600)] }
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  # Samples of +node+ in buffers of +size+ (dup'd and joined).
  def take(node, n, size = 800)
    out = []
    got = 0
    while got < n
      b = node.sample([size, n - got].min)
      break if b.nil?
      out << b.dup
      got += b.length
    end
    Numo::SFloat.hstack(out)
  end

  describe MB::Sound::Sampler::Instrument do
    it 'reads region options' do
      s = ones
      inst = described_class.new { |i|
        i.region(s, keys: MB::Sound::C2..MB::Sound::B3, vel: 0.0..0.5, root: MB::Sound::C3)
        i.region(s, keys: 70, vel: 64...100, seq: [2, 3], rand: 0.25..0.5, keytrack: 0, veltrack: 1, tune: 1, gain: -6.db)
      }
      a, b = inst.regions
      expect(a.keys).to eq([36, 59])
      expect(a.vel).to eq([0, 64])
      expect(a.root).to eq(48)
      expect(b.keys).to eq([70, 70])
      expect(b.vel).to eq([64, 99])
      expect(b.seq).to eq([2, 3])
      expect(b.rand).to eq([0.25, 0.5])
      expect(b.gain).to be_within(1e-3).of(0.501)
      expect(inst.channel_count).to eq(1)
      expect(inst).to be_one_shot
      expect(inst.regions).to be_frozen
      expect { inst.region(s) }.to raise_error(FrozenError)
      expect { described_class.new { |i| i.region(s, seq: [3, 2]) } }.to raise_error(ArgumentError, /seq/)
      expect { described_class.new }.to raise_error(ArgumentError, /at least one/)
    end

    it 'plays from a synth on the exact note-on sample, holding one-shot voices until the sample ends' do
      transport = MB::Sound::Sequence::Transport.new(bpm: 120)
      clip = MB::Sound.seq(MB::Sound::C4.n32, MB::Sound::Rest.n4.d, MB::Sound::E4.n32).stream(transport: transport)
      s = ones
      syn = MB::Sound.synth(clip, voices: 1) { |v| s.play(v) }
      out = take(syn, 48000)
      on = (out.abs > 0.5).where
      expect(on[0]).to be <= 1
      # The 1/32 note is 3000 samples, but the one-shot plays all 9600
      expect(out[9000...9500].abs.min).to be > 0.5
      start = ((1/32r + 3/8r) * 2 * 48000).round # whole notes are 2 s at 120 BPM
      rise = (out[11000..].abs > 0.5).where[0] + 11000
      expect(rise).to be_within(1).of(start)
    end

    it 'plays stereo samples as a Channels bundle' do
      st = MB::Sound::Sample[[Numo::SFloat.ones(100), Numo::SFloat.ones(100) * -1]]
      out = st.node
      expect(out).to be_a(MB::Sound::GraphNode::Channels)
      l = take(out[0], 200)
      expect(l[10]).to be > 0.9
    end

    it 'plays a sample once as a node, then ends' do
      n = ones[0...1000].node
      a = n.sample(800)
      expect(a[100]).to be_within(1e-3).of(1)
      b = n.sample(800)
      expect(b[199]).to be_within(1e-3).of(1) if b
      expect(n.sample(800)).to be_nil
    end

    it 'chokes notes by group and off_by in synth voices, fading voices without an envelope like ChokeGate' do
      m = MB::Sound
      half = m::Sample[Numo::SFloat.new(9600).fill(0.5)]
      inst = described_class.new { |i|
        i.region(ones, keys: m::As2, group: :open, off_by: :closed) # cut by the closed hat, not by itself
        i.region(half, keys: m::Fs2, choke: :closed)                # cuts the open hat and itself
        i.region(half, keys: m::C2, choke: 0)                        # no group
      }
      expect(inst.regions.map { |r| [r.group, r.off_by] }).to eq([[:open, :closed], [:closed, :closed], [nil, nil]])
      expect { described_class.new { |i| i.region(ones, choke: 'hats') } }.to raise_error(ArgumentError, /choke group/)
      expect(described_class.new { |i| i.region(ones) }.choke_map).to be_nil

      transport = m::Sequence::Transport.new(bpm: 120)
      run = ->(*rows) {
        clip = m.events(*rows.map { |t, note| [t, 1/32r, note, 1.0] }, length: 1)
        take(m.synth(clip.stream(transport: transport), voices: 4) { |v| inst.play(v) }, 12000, 128)
      }
      open = run.([0, m::As2])
      closed = run.([0, m::Fs2])
      # the closed hat at 6000 samples cuts the open hat over 144 samples
      cut = run.([0, m::As2], [1/16r, m::Fs2])
      ramp = Numo::SFloat.new(144).seq(144, -1) / 144
      expect(cut[0...6000]).to eq(open[0...6000])
      expect((cut[6000...6144] - open[6000...6144] * ramp - closed[0...144]).abs.max).to be < 1e-6
      expect((cut[6144..] - closed[144...6000]).abs.max).to eq(0)
      # the open hat doesn't cut the closed one, nor itself; the closed hat cuts itself
      both = run.([0, m::Fs2], [1/16r, m::As2])
      expect((both[6000..] - closed[6000..] - open[0...6000]).abs.max).to be < 1e-6
      expect((run.([0, m::As2], [1/16r, m::As2])[6000..] - open[6000..] - open[0...6000]).abs.max).to be < 1e-6
      expect(run.([0, m::Fs2], [1/16r, m::Fs2])[6144..]).to eq(closed[144...6000])
      expect((run.([0, m::As2], [1/16r, m::C2])[6000..] - open[6000..] - run.([0, m::C2])[0...6000]).abs.max).to be < 1e-6

      # without a synth lane (no allocator), nothing chokes
      notes = m.events([0, 1/32r, m::As2, 1.0], [1/16r, 1/32r, m::Fs2, 1.0], length: 1).notes
      solo = take(inst.play(notes, seed: 1), 7000)
      expect(solo[6500]).to be_within(1e-3).of(0.5) # (one voice: the closed hat restrikes it)
    end

    it 'plays chop clips with slice and pitch apart' do
      rec = MB::Sound::Sample[Numo::SFloat.cast(Numo::DFloat.new(4800).seq.map { |i| Math.sin(i * 0.05) })]
      brk = rec.slices(4)
      transport = MB::Sound::Sequence::Transport.new(bpm: 120)
      a = take(brk.chop(1, MB::Sound::Rest).stream(transport: transport).then { |c| brk.sampler(c) }, 4000)
      b = take(brk.chop(1, MB::Sound::Rest).transpose(12).stream(transport: transport).then { |c| brk.sampler(c) }, 4000)
      expect((a.abs > 0).where[-1]).to be_within(2).of(1199)
      expect((b.abs > 0).where[-1]).to be_within(2).of(599)
    end
  end

  describe 'pitch marks' do
    it 'travel as per-note pitch, and as a bend at 24 semitones before the note-on in MIDI 1.0 bytes' do
      e = MB::Sound::MIDI::Event.note_on(38, 0.75, channel: 2, pitch: 3.0)
      expect(e.pitch).to eq(3.0)
      bend, note = MB::Sound::MIDI::Event.parse_all(e.bytes)
      expect(bend.type).to eq(:bend)
      expect(bend.channel).to eq(2)
      expect(bend.value).to be_within(1e-3).of(3 / 24.0)
      expect([note.type, note.note]).to eq([:note_on, 38])
      expect(MB::Sound::MIDI::Event.note_on(38, 0.75).bytes.bytesize).to eq(3)
      expect(MB::Sound::MIDI::Event.note_on(38, 0.75, pitch: 0.0).bytes.bytesize).to eq(6)
    end

    it 'reach a voice as Notes#pitch_mark from a clip, held from each note-on' do
      notes = MB::Sound.seq(MB::Sound::C4.pitch(2), MB::Sound::D4, MB::Sound::E4.pitch(-1.5)).n8.notes
      m = take(notes.pitch_mark, 72000)
      expect(m[0]).to eq(2)
      expect(m[18000]).to eq(0)
      expect(m[30000]).to eq(-1.5)
    end

    it 'pitch keyboard slices played live with bend, and split keyboards play the last slice above the split' do
      rec = MB::Sound::Sample[Numo::SFloat.cast(Numo::DFloat.new(4800).seq.map { |i| Math.sin(i * 0.05) })]
      brk = rec.slices(4)
      inst = brk.keymap(from: 36, split: 60)
      transport = MB::Sound::Sequence::Transport.new(bpm: 120)
      clip = MB::Sound.seq(37, 72).n8.stream(transport: transport) # slice 1, then slice 1 an octave up
      out = take(inst.sampler(clip), 24000)
      expect((out[0...12000].abs > 0).where[-1]).to be_within(2).of(1199)
      expect((out[12000..].abs > 0).where[-1]).to be_within(2).of(599)
    end
  end

  describe 'SFZ' do
    let(:dir) { File.dirname(tmp_path('x')) }

    def wav(name, value, n = 2000)
      FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
      MB::Sound.write(File.join(dir, name), [Numo::SFloat.new(n).fill(value)], overwrite: true)
    end

    it 'reads regions, groups, round robins, loops, and the envelope' do
      wav('s/soft.wav', 0.25)
      wav('s/hard a.wav', 0.5)
      wav('s/hard b.wav', 0.75)
      File.write(File.join(dir, 'kit.sfz'), <<~SFZ)
        // a test kit
        #define $KEY 62
        <control> default_path=s/
        <global> ampeg_attack=0.01 ampeg_release=0.3 ampeg_sustain=80 volume=-6
        <group> lokey=c4 hikey=d#4 pitch_keycenter=c4
        <region> sample=soft.wav hivel=63 loop_mode=loop_continuous loop_start=100 loop_end=900
        <group> key=$KEY seq_length=2 amp_veltrack=0 pan=-20 fil_type=lpf_2p group=2 off_by=1
        <region> sample=hard a.wav seq_position=1 lovel=64
        <region> sample=hard b.wav seq_position=2 lovel=64 tune=50 /* block
        comment */
        <region> sample=hard a.wav trigger=release
      SFZ
      inst = nil
      expect { inst = MB::Sound.sfz(File.join(dir, 'kit.sfz')) }.to output(/ignoring opcodes fil_type.*skipped 1 release/m).to_stderr
      expect(inst.regions.length).to eq(3)
      a, b, c = inst.regions
      expect(a.keys).to eq([60, 63])
      expect(a.vel).to eq([0, 63])
      expect(a.sample.loop_points).to eq([100.0, 901.0])
      expect(a.sample.loop_mode).to eq(:forward)
      expect(a.gain).to be_within(1e-3).of(0.501)
      expect(b.keys).to eq([62, 62])
      expect(b.seq).to eq([1, 2])
      expect(c.seq).to eq([2, 2])
      expect(c.tune).to eq(0.5)
      expect(b.veltrack).to eq(0)
      expect(a.veltrack).to eq(1)
      expect(c.sample.name).to eq('hard b.wav')
      expect([a.group, a.off_by, b.group, b.off_by]).to eq([nil, nil, 2, 1]) # (0 is none)
      expect(inst.envelope).to eq([0.01, 0.0, 0.8, 0.3])
      expect(inst.mips).to eq(:octave)
      expect { expect(MB::Sound.sfz(File.join(dir, 'kit.sfz'), mips: :default).mips).to eq(:default) }.to output(/ignoring/).to_stderr
      expect(MB::Sound::Sampler::SFZ.note('db3')).to eq(49)
    end

    it 'keeps sample paths inside a graph document directory' do
      ctx = MB::Sound::GraphIO::FileGuard::Context.new(dir, 'doc', nil)
      base = MB::Sound::GraphIO::FileGuard.register(+'kit.sfz', ctx)
      ok = MB::Sound::Sampler::SFZ.sample_path(base, 's/a.wav')
      expect(MB::Sound::GraphIO::FileGuard.resolve(ok)).to eq(File.join(dir, 's/a.wav'))
      bad = MB::Sound::Sampler::SFZ.sample_path(base, '../../etc/passwd')
      expect { MB::Sound::GraphIO::FileGuard.resolve(bad) }.to raise_error(MB::Sound::GraphIO::FileError)
    end
  end

  describe 'bounce' do
    it 'renders a graph or a block at a private tempo to the exact length' do
      bpm = MB::Sound.transport.bpm
      rec = MB::Sound.bounce(1.bar, bpm: 150) { 100.hz.ramp.at(0.5) }
      expect(rec.length).to eq((48000 * 60 / 150.0 * 4).round)
      expect(rec.bpm).to eq(150)
      expect(rec.peak).to be_within(0.05).of(0.5)
      expect(MB::Sound.transport.bpm).to eq(bpm)

      g = MB::Sound.bounce(200.hz.sine, 0.5.seconds, root: MB::Sound::A3)
      expect(g.length).to eq(24000)
      expect(g.root).to eq(57)
      expect(300.hz.sine.bounce(2.n16, bpm: 120).length).to eq(12000)
      expect { MB::Sound.bounce(1.bar) }.to raise_error(ArgumentError, /graph or a block/)
      expect { MB::Sound.bounce(100.hz.sine) }.to raise_error(ArgumentError, /length/)
    end

    # granular-2 found bin/songs/granular_song.rb bouncing its sources at the
    # default transport's 120 BPM in renders, after the song's `bpm 72` had
    # set only the render's own transport (fixes-14)
    it "bounces at the tempo a render's song just set, not the default transport's" do
      expect(MB::Sound::Sequence.transport.bpm).to eq(120)
      rec = nil
      size = nil
      out = MB::Sound::NullOutput.new(channels: 1, sleep: false)
      MB::Sound.render(out, seconds: 0.01, channels: 1) {
        MB::Sound.bpm 72
        rec = MB::Sound.bounce(1.bar) { 100.hz.ramp.at(0.5) }
        size = MB::Sound::Length.samples(1.n16)
      }
      expect(rec.bpm).to eq(72)
      expect(rec.length).to eq((48000 * 60 / 72.0 * 4).round)
      expect(size).to eq(48000 * 60 / 72.0 / 4)
      expect(MB::Sound::Sequence.transport.bpm).to eq(120)
    end

    it 'bounces at the tempo a scheduled block queued before it' do
      session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120), realtime: false)
      rec = nil
      read = nil
      MB::Sound::Session.with_context(session: session) {
        MB::Sound.at_bar(1) {
          MB::Sound.bpm 90
          read = MB::Sound.bpm
          rec = MB::Sound.bounce(1.beat) { 100.hz.ramp }
        }
      }
      2.times { session.process_buffer(800) }
      expect(read).to eq(90)
      expect(rec.bpm).to eq(90)
      expect(rec.length).to eq(32000)
      expect(session.transport.bpm).to eq(90)
    ensure
      session&.close
    end

    it 'presses a clip at its own tempo, its hits on the grid' do
      rec = MB::Sound.bounce(1.bar, bpm: 100) { MB::Sound.tr808(MB::Sound.grid(16, kick: 'X...X...X...X...')) }
      on = rec.onsets
      step = 48000 * 60 / 100.0
      expect(on.length).to eq(4)
      on.each_with_index { |o, i| expect(o).to be_within(40).of(i * step) }
    end
  end

  describe 'capture_audio' do
    def new_session
      out = MB::Sound::NullOutput.new(channels: 1, sleep: false)
      MB::Sound::Session.new(master_gain: 0.5, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1,
                             buffer_size: 800, realtime: false, raise_errors: true).tap { |s| sessions << s }
    end

    it 'captures the master bus from a launch point' do
      s = new_session
      cap = nil
      MB::Sound::Session.with_context(session: s) do
        s.add(1.0.constant, name: :dc, on: :now)
        cap = MB::Sound.capture_audio(4800.samples, at: MB::Sound::LaunchPoint.build(at: nil, on: 1/16r, offset: nil))
      end
      6.times { s.process_buffer(1000) }
      cap.wait(5)
      expect(cap).to be_done
      expect(cap.sample.length).to eq(4800)
      expect(cap.sample.data.to_a.uniq).to eq([0.5])
    end

    it 'captures a node with a silent player' do
      s = new_session
      cap = nil
      MB::Sound::Session.with_context(session: s) do
        cap = MB::Sound.capture_audio(1000.samples, from: 0.25.constant)
      end
      mix = Array.new(3) { s.process_buffer(800)[0].dup }
      expect(cap).to be_done
      expect(cap.sample.length).to eq(1000)
      expect(cap.sample.data.to_a.uniq).to eq([0.25])
      expect(mix.map { |m| m.abs.max }.max).to eq(0)
    end
  end
end
