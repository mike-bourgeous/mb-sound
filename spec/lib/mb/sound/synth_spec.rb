RSpec.describe(MB::Sound::Synth) do
  let(:ev) { MB::Sound::MIDI::Event }
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }

  # A MIDIListSource of +events+, plus a CC at +last+ seconds so the source
  # doesn't end too soon (nil for no extra event).
  def source(*events, last: 1000r)
    MIDIListSource.new(events, last ? [ev.cc(99, 0, time: last)] : [])
  end

  # Samples +synth+ (or its #sample_individual with +individual+) +buffers+
  # times; returns the concatenated output (or one per lane).
  def render(synth, buffers:, buffer: 480, individual: false)
    if individual
      data = buffers.times.map { synth.sample_individual(buffer).map { |d| d&.dup || Numo::SFloat.zeros(buffer) } }
      data.transpose.map { |l| l.reduce(:concatenate) }
    else
      buffers.times.map { synth.sample(buffer).dup }.reduce(:concatenate)
    end
  end

  # The peak of +data+ in samples from..to (seconds).
  def peak(data, from, to)
    data[(from * 48000).round...(to * 48000).round].abs.max
  end

  let(:patch) { ->(v, _i) { v.hz.saw * v.amp_env(0.002, 0.05, 0.7, release, curve: :linear) } }
  let(:release) { 0.01 }

  it 'requires a block and valid controls' do
    expect { described_class.new(source) }.to raise_error(ArgumentError, /block/)
    expect { described_class.new(source, controls: [:bogus]) { |v| v.gate } }.to raise_error(ArgumentError, /bogus/)
    expect { described_class.new(source) { |v| 3 } }.to raise_error(ArgumentError, /graph node/)
  end

  it 'builds one lane per voice plus spares, calling the block with the lane index' do
    seen = []
    s = described_class.new(source, voices: 3, spares: 1) { |v, i| seen << [v.class, i]; v.gate }
    expect(seen).to eq(4.times.map { |i| [MB::Sound::Notes, i] })
    expect(s.lanes.length).to eq(4)
    expect(s.notes.map(&:stream)).to eq(s.lanes)
    expect(s.voices).to eq(3)
    expect(s.channel_count).to eq(1)
    expect(s.outputs).to eq([s])
    expect(s.graph).to include(s.notes[0].gate)
  end

  describe 'polyphony' do
    it 'plays a chord from a clip on separate lanes' do
      chord = MB::Sound.seq(MB::Sound::C3).n2 & MB::Sound.seq(MB::Sound::E3).n2 & MB::Sound.seq(MB::Sound::G3).n2
      s = described_class.new(MB::Sound::MIDI::ClipSource.new(chord, transport: transport), voices: 4, &patch)
      lanes = render(s, buffers: 10, individual: true)
      expect(lanes.map { |l| l.abs.max > 0.3 }).to eq([true, true, true, false, false, false])
      expect(s.lanes.first(3).map(&:note)).to eq([48, 52, 55])
    end

    it 'mixes the lanes' do
      s1 = described_class.new(source(ev.note_on(48), ev.note_on(52)), voices: 2, seed: 1, &patch)
      s2 = described_class.new(source(ev.note_on(48), ev.note_on(52)), voices: 2, seed: 1, &patch)
      lanes = render(s1, buffers: 5, individual: true)
      expect(render(s2, buffers: 5)).to all_be_within(1e-5).of_array(lanes.reduce(:+))
    end

    it 'steals with a choke when voices run out, playing the new note on a spare' do
      s = described_class.new(
        source(ev.note_on(48), ev.note_on(52, time: 1/10r), ev.note_on(55, time: 2/10r)),
        voices: 2, &patch
      )
      lanes = render(s, buffers: 30, individual: true)
      expect(peak(lanes[0], 0.15, 0.2)).to be > 0.5
      expect(peak(lanes[0], 0.2 + 0.004, 0.3)).to eq(0) # choked over 3 ms
      expect(peak(lanes[1], 0.2, 0.3)).to be > 0.5     # untouched
      expect(peak(lanes[2], 0.2, 0.3)).to be > 0.5     # the spare plays the new note
      expect(s.allocator.active_count).to eq(2)
    end

    it 'steals released voices first from a MIDI file' do
      # c_major.mid: single notes at 0.1, 0.361, 0.616, ... seconds
      s = described_class.new('spec/test_data/c_major.mid', voices: 2) { |v| v.hz.saw * v.amp_env(0.002, 0.05, 0.7, 1, curve: :linear) }
      active = []
      lanes = 70.times.map {
        out = s.sample_individual(480).map { |d| d&.dup || Numo::SFloat.zeros(480) }
        active << s.allocator.active_count
        out
      }.transpose.map { |l| l.reduce(:concatenate) }

      expect(active.max).to eq(2)
      expect(peak(lanes[0], 0.5, 0.61)).to be > 0.1  # the first note still rings in its release
      expect(peak(lanes[0], 0.63, 0.7)).to eq(0)      # choked by the third note at 0.616 s
      expect(peak(lanes[1], 0.6, 0.7)).to be > 0.1    # the second note keeps ringing
      expect(peak(lanes[2], 0.62, 0.7)).to be > 0.3   # the third note on a spare
    end

    it 'reuses lanes that went idle instead of choking them' do
      events = [ev.note_on(48), ev.note_off(48, time: 1/20r), ev.note_on(52, time: 2/10r)]

      quick = described_class.new(source(*events), voices: 1, mono: false, spares: 1, &patch)
      render(quick, buffers: 25)
      expect(quick.lanes.map(&:state)).to eq([:free, :sounding])

      ringing = described_class.new(source(*events), voices: 1, mono: false, spares: 1) { |v| v.hz.saw * v.amp_env(0, 0.05, 0.7, 2) }
      render(ringing, buffers: 25)
      expect(ringing.lanes.map(&:state)).to eq([:choking, :sounding])
    end

    it 'keeps a lane with only a gate busy while its note is held' do
      s = described_class.new(source(ev.note_on(48), ev.note_on(52, time: 1/10r)), voices: 1, mono: false, spares: 1) { |v| v.gate }
      first = s.sample_individual(480).map(&:dup)
      expect(s.notes[0].idle?).to eq(false) # held, with no envelope
      expect(s.notes[1].idle?).to eq(true)
      lanes = [first, *19.times.map { s.sample_individual(480).map(&:dup) }].transpose.map { |l| l.reduce(:concatenate) }
      expect(s.notes[0].idle?).to eq(true) # the choke ended it
      expect(peak(lanes[0], 0, 0.1)).to eq(1)
      expect(peak(lanes[0], 0.11, 0.2)).to eq(0) # the gate dropped at the choke
      expect(peak(lanes[1], 0.11, 0.2)).to eq(1)
    end

    it 'plays one lane in mono mode' do
      s = described_class.new(source(ev.note_on(48), ev.note_on(52, time: 1/10r)), voices: 1) { |v| v.number }
      expect(s.mono?).to eq(true)
      expect(s.lanes.length).to eq(1)
      out = render(s, buffers: 20)
      expect(out[100]).to eq(48)
      expect(out[6000]).to eq(52)
    end

    it 'passes spares= to the allocator' do
      s = described_class.new(source, voices: 2, spares: 2) { |v| v.gate }
      s.spares = 1
      expect(s.spares).to eq(1)
      expect(s.allocator.spares).to eq(1)
      expect { s.spares = 3 }.to raise_error(ArgumentError)
    end
  end

  describe 'seeds' do
    let(:events) { [ev.note_on(48), ev.note_on(52), ev.note_on(55)] }

    it 'renders the same with the same seed, and differently with another' do
      mk = ->(seed) { described_class.new(source(*events), voices: 3, seed: seed) { |v| v.hz.saw.rnd * v.gate } }
      a = render(mk.(5), buffers: 4)
      b = render(mk.(5), buffers: 4)
      c = render(mk.(6), buffers: 4)
      expect(a).to eq(b)
      expect(a).not_to eq(c)
    end

    it 'gives each lane its own seed: synth seed + lane index' do
      tones = []
      s = described_class.new(source(*events), voices: 3, spares: 0, seed: 100) { |v| (tones << v.hz.saw.rnd).last * v.gate }
      expected = 3.times.map { |i| MB::Sound.with_seed(100 + i) { MB::Sound.next_seed } }
      expect(tones.map(&:seed)).to eq(expected)
      expect(tones.map(&:seed).uniq.length).to eq(3)
      expect(s.seed).to eq(100)
    end

    it 'draws its seed from the root generator by default' do
      MB::Sound.seed(42)
      a = described_class.new(source) { |v| v.gate }.seed
      MB::Sound.seed(42)
      expect(described_class.new(source) { |v| v.gate }.seed).to eq(a)
    end

    it 'leaves the root generator where it was apart from its own seed' do
      MB::Sound.seed(9)
      MB::Sound.next_seed
      expected = MB::Sound.next_seed
      MB::Sound.seed(9)
      described_class.new(source, voices: 4) { |v| v.hz.saw.rnd * v.gate }
      expect(MB::Sound.next_seed).to eq(expected)
    end
  end

  describe 'controls' do
    let(:note) { [ev.note_on(69, 1.0)] }
    let(:dc) { ->(v) { v.gate } }

    it 'scales by volume and expression with the GM curve' do
      plain = described_class.new(source(*note), voices: 1) { |v| v.gate }
      vol = described_class.new(source(*note), voices: 1, controls: [:volume]) { |v| v.gate }
      both = described_class.new(source(*note, ev.cc_raw(7, 64), ev.cc_raw(11, 32)), voices: 1, controls: [:volume, :expression]) { |v| v.gate }
      expect(render(plain, buffers: 1)[10]).to eq(1)
      expect(render(vol, buffers: 1)[10]).to be_within(1e-6).of((100 / 127.0) ** 2) # volume starts at 100
      expect(render(both, buffers: 1)[10]).to be_within(1e-6).of((64 / 127.0) ** 2 * (32 / 127.0) ** 2)
      expect(MB::Sound::DB.from_gain((64 / 127.0) ** 2)).to be_within(1e-6).of(40 * Math.log10(64 / 127.0)) if defined?(MB::Sound::DB)
    end

    it 'pans a mono synth to stereo with CC 10' do
      s = described_class.new(source(*note, ev.cc_raw(10, 0, time: 1/100r)), voices: 1, controls: [:pan]) { |v| v.gate }
      expect(s.channel_count).to eq(2)
      expect { s.sample(480) }.to raise_error(ArgumentError, /outputs/)
      l, r = s.outputs
      l1 = l.sample(480).dup
      r1 = r.sample(480).dup
      expect(l1[10]).to be_within(1e-3).of(r1[10]) # centered at 64
      l2 = l.sample(480).dup
      r2 = r.sample(480).dup
      expect(l2[400]).to be_within(1e-3).of(1)
      expect(r2[400].abs).to be < 1e-3
    end

    it 'balances a stereo synth with CC 10' do
      s = described_class.new(source(*note, ev.cc_raw(10, 127)), voices: 2, controls: [:pan]) { |v| MB::Sound.stereo(v.gate, v.gate * 0.5) }
      expect(s.channel_count).to eq(2)
      l, r = s.outputs
      expect(l.sample(480)[10].abs).to be < 1e-3
      expect(r.sample(480)[10]).to be > 0.4
    end
  end

  it 'sets the bend range with bend_range:' do
    events = [ev.note_on(57), ev.bend(1.0, time: 1/100r)]
    wide = described_class.new(source(*events), voices: 1, bend_range: 12.st) { |v| v.freq }
    plain = described_class.new(source(*events), voices: 1) { |v| v.freq }
    w = render(wide, buffers: 2)
    p = render(plain, buffers: 2)
    expect(w[100]).to be_within(0.01).of(220)
    expect(w[900]).to be_within(0.05).of(440)
    expect(p[900]).to be_within(0.05).of(220 * 2 ** (2 / 12.0))
  end

  it 'applies the sustain pedal unless sustain: false' do
    events = [ev.cc(64, 1.0), ev.note_on(48), ev.note_off(48, time: 1/10r), ev.cc(64, 0.0, time: 2/10r)]
    held = described_class.new(source(*events), voices: 1) { |v| v.gate }
    raw = described_class.new(source(*events), voices: 1, sustain: false) { |v| v.gate }
    h = render(held, buffers: 25)
    r = render(raw, buffers: 25)
    expect(h[7200]).to eq(1)
    expect(r[7200]).to eq(0)
    expect(h[10000]).to eq(0)
  end

  it 'changes the sample rate of every lane and control' do
    s = described_class.new(source(ev.note_on(48, time: 1/10r)), voices: 2, controls: [:volume]) { |v| v.gate }
    s.sample_rate = 24000
    expect(s.notes.map { |v| v.gate.sample_rate }).to all(eq(24000))
    out = render(s, buffers: 10)
    expect(out.to_a.index { |x| x > 0 }).to eq(2400)
  end

  describe 'channels' do
    it 'mixes multichannel lanes per channel, repeating narrower lanes' do
      s = described_class.new(source(ev.note_on(48), ev.note_on(52)), voices: 2, spares: 0) { |v, i|
        i == 0 ? MB::Sound.stereo(v.gate, v.gate * 0.5) : v.gate * 0.25
      }
      expect(s.channel_count).to eq(2)
      l, r = s.outputs
      expect(l.sample(480)[10]).to be_within(1e-6).of(1.25)
      expect(r.sample(480)[10]).to be_within(1e-6).of(0.75)
      expect(l.graph).to include(s)
    end

    it 'renders in a session' do
      s = described_class.new(source(ev.note_on(48), ev.note_off(48, time: 1/10r), last: nil), voices: 2) { |v, i|
        (v.hz.saw * v.amp_env(0.001, 0.01, 0.5, 0.05)).pan(i.even? ? -0.5 : 0.5)
      }
      file = tmp_path('synth_stereo.flac')
      MB::Sound.render(file, s, seconds: 1)
      l, r = MB::Sound.read(file)
      expect(l.abs.max).to be > 0.01
      expect(l.abs.max).to be > r.abs.max * 1.5 # lane 0 is to the left
      expect(l[(0.3 * 48000).round..].abs.max).to eq(0)
    end
  end

  describe 'ending' do
    it 'ends after a finite source once every lane is idle' do
      s = described_class.new(source(ev.note_on(48), ev.note_off(48, time: 1/10r), last: nil), voices: 2, tail: 0) { |v|
        v.hz.saw * v.amp_env(0, 0.01, 0.5, 0.1, curve: :linear)
      }
      count = 0
      ended_at = nil
      while s.sample(480)
        count += 1
        ended_at ||= count if s.ended?
        break if count > 100
      end
      expect(ended_at).to be_within(1).of(21) # note-off at 4800, release 4800 samples
      expect(count).to be <= ended_at + 1
    end

    it 'outputs silence for the tail after every lane has ended' do
      s = described_class.new(source(ev.note_on(48), ev.note_off(48, time: 1/100r), last: nil), voices: 1, tail: 0.5) { |v| v.gate }
      out = []
      while (b = s.sample(480)) && out.length < 1000
        out << b.dup
      end
      expect(out.length).to be_within(1).of(2 + 50) # the note, then 0.5 s of silence
      expect(out[3..].reduce(:concatenate).abs.max).to eq(0)
      expect(s.ended?).to eq(true)
    end

    it 'never ends with a looping clip' do
      s = described_class.new(MB::Sound::MIDI::ClipSource.new(MB::Sound.seq(MB::Sound::C3).n8.loop, transport: transport), voices: 2, &patch)
      50.times { expect(s.sample(4800)).not_to eq(nil) }
      expect(s.ended?).to eq(false)
    end

    it 'stops a synth script after its tail with the runner ringdown' do
      midi_file = 'spec/test_data/c_major.mid'
      music_end = MB::Sound::MIDI::MIDIFile.new(midi_file).music_end
      outfile = tmp_path('synth_script.flac')

      r = MB::Sound::ScriptRunner.new(:synth, {}, argv: [midi_file, outfile, '-q'], script: 'bin/example.rb')
      expect {
        r.run_synth { |input| described_class.new(input, voices: 4) { |v| v.hz.saw * v.amp_env(0.005, 0.1, 0.5, 0.3) } }
      }.to output(/Rendered/).to_stdout

      data = MB::Sound.read(outfile)[0]
      last_sound = (0...data.length).select { |i| data[i].abs > 1e-4 }.last / 48000.0
      expect(last_sound).to be > music_end
      expect(last_sound).to be < music_end + 0.5
      expect(data.length / 48000.0 - last_sound).to be_within(0.15).of(1) # a second of quiet, not the 10 s tail limit
    end
  end

  describe 'idle lane skipping', :check_shared do
    let(:notes) {
      [ev.note_on(48), ev.note_off(48, time: 0.05r), ev.note_on(52, time: 0.2r), ev.note_off(52, time: 0.25r),
       ev.cc_raw(1, 100, time: 0.3r), ev.note_on(55, time: 0.4r), ev.note_off(55, time: 0.45r), ev.note_on(60, time: 0.6r)]
    }

    # A patch whose output is exactly the same with skipping (naive
    # oscillator reset to a fixed phase, no filter state).
    let(:exact_patch) {
      ->(v, _i) { v.hz.aramp * v.amp_env(0.002, 0.01, 0.5, 0.01, curve: :linear) * (1 + v.mod) * v.velocity }
    }

    def run(synth, buffers, size = 480)
      skipped = []
      out = buffers.times.map { b = synth.sample(size).dup; skipped << synth.skipped_lanes; b }
      [out.reduce(:concatenate), skipped]
    end

    it 'skips idle silent lanes, wakes them for events, and gives the same samples for an exactly resettable patch' do
      s1 = described_class.new(source(*notes), voices: 2, spares: 1, seed: 1, &exact_patch)
      s2 = described_class.new(source(*notes), voices: 2, spares: 1, seed: 1, skip_idle: false, &exact_patch)
      expect(s1.skippable_lanes).to eq([0, 1, 2])

      out1, skipped = run(s1, 80)
      out2, _ = run(s2, 80)

      expect(skipped[0]).to eq([1, 2]) # unused lanes from the first buffer
      expect(skipped[20]).to include(0) # after the first note's release
      expect(skipped.flatten.uniq.sort).to eq([0, 1, 2])
      expect(out1.abs.max).to be > 0.3
      expect(out1.to_a).to eq(out2.to_a)
    end

    it 'stays close to rendering every lane for a filtered band-limited patch' do
      s1 = described_class.new(source(*notes), voices: 2, spares: 1, seed: 1, &patch)
      s2 = described_class.new(source(*notes), voices: 2, spares: 1, seed: 1, skip_idle: false, &patch)
      out1, skipped = run(s1, 80)
      out2, _ = run(s2, 80)
      expect(skipped.flatten).not_to be_empty

      # Only the band-limited reset steps at note-ons differ (32 samples),
      # since a skipped lane's oscillator resets from where it paused
      diff = (out1 - out2).abs
      starts = [0, 9600, 19200, 28800]
      far = diff.to_a.each_index.select { |i| diff[i] > 1e-6 && starts.none? { |s| (s...(s + 40)).cover?(i) } }
      expect(far).to eq([])
      expect(diff.max).to be < 0.05
    end

    it 'never skips lanes with delays or reverbs, or with skip_idle: false' do
      s = described_class.new(source(*notes), voices: 2, spares: 0) { |v| (v.hz.saw * v.amp_env).delay(0.1) }
      expect(s.skippable_lanes).to eq([])
      s = described_class.new(source(*notes), voices: 2, spares: 0) { |v| [v.hz.saw * v.amp_env].reverb(:room) }
      expect(s.skippable_lanes).to eq([])
      s = described_class.new(source(*notes), voices: 2, skip_idle: false, &patch)
      expect(s.skippable_lanes).to eq([])
      expect(run(s, 30)[1].flatten).to be_empty
    end

    it 'keeps shared controller and glide inputs in step while lanes are skipped' do
      events = notes + 30.times.map { |i| ev.cc_raw([1, 74, 73, 76][i % 4], (i * 37) % 128, time: Rational(i, 40)) } + [ev.bend(0.5, time: 0.33r)]
      s = described_class.new(source(*events), voices: 3, spares: 1) { |v|
        tone = v.hz.glide(0.02).vibrato.saw.filter(:lowpass, cutoff: v.cutoff(900), quality: v.quality(2))
        tone * v.amp_env(0.002, 0.02, 0.5, 0.02) * (1 + v.mod)
      }
      out, skipped = run(s, 100, 256)
      expect(skipped.flatten).not_to be_empty
      expect(out.abs.max).to be > 0.1
    end
  end

  it 'never modifies shared buffers', :check_shared do
    s = described_class.new(
      source(ev.note_on(48), ev.note_on(55, time: 1/50r), ev.cc_raw(74, 90), ev.note_off(48, time: 1/10r)),
      voices: 3, controls: [:volume, :expression, :pan]
    ) { |v|
      osc = v.hz.saw.rnd + v.hz.transpose(7).square * 0.5
      osc.filter(:lowpass, cutoff: v.cutoff(500), quality: v.quality(2)) * v.amp_env(0.001, 0.05, 0.6, 0.05) * v.velocity
    }
    l, r = s.outputs
    20.times do
      l.sample(480)
      r.sample(480)
    end
    expect(s.notes.count { |v| !v.idle? }).to be >= 1
  end
end
