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

    it 'keeps a lane without envelopes busy until its output is quiet' do
      events = [ev.note_on(48), ev.note_off(48, time: 1/20r), ev.note_on(52, time: 2/10r)]
      ping = ->(q) { ->(v, _i) { v.trigger.filter(:lowpass, cutoff: v.freq, quality: q) } }

      # A damped ping is quiet long before the next note, so its lane is reused
      quick = described_class.new(source(*events), voices: 1, mono: false, spares: 1, &ping.(0.7))
      render(quick, buffers: 25)
      expect(quick.lanes.map(&:state)).to eq([:free, :sounding])

      # A resonant ping still rings, so the next note steals it like a
      # sounding voice (the old code freed it at the note-off)
      ringing = described_class.new(source(*events), voices: 1, mono: false, spares: 1, &ping.(200))
      render(ringing, buffers: 25)
      expect(ringing.lanes.map(&:state)).to eq([:choking, :sounding])
      expect(ringing.quiet_lanes).to eq([])
    end

    it 'counts lanes as quiet under -90 dB, but skips them only under -120 dB' do
      # A ping that decays through -90 dB and -120 dB a while apart
      s = described_class.new(source(ev.note_on(48), ev.note_off(48, time: 1/100r)), voices: 1, mono: false, spares: 0) { |v|
        v.trigger.filter(:lowpass, cutoff: v.freq, quality: 30)
      }
      quiet_at = skipped_at = nil
      data = 300.times.map { |i|
        b = s.sample(480).dup
        quiet_at ||= i if s.quiet_lanes == [0]
        skipped_at ||= i if s.skipped_lanes == [0]
        b
      }.reduce(:concatenate)

      buf_peak = ->(i) { data[(i * 480)...((i + 1) * 480)].abs.max }
      expect(buf_peak.(quiet_at)).to be <= -90.db
      expect(buf_peak.(quiet_at - 1)).to be > -90.db
      expect(buf_peak.(skipped_at)).to be <= -120.db
      expect(buf_peak.(skipped_at - 1)).to be > -120.db
      expect(skipped_at).to be > quiet_at + 5
    end

    it 'gives Notes#level the measured peak of each lane, for :quietest stealing' do
      # Envelope-less voices: the quiet one is stolen, not the oldest
      events = [ev.note_on(48, 1.0), ev.note_on(52, 0.1, time: 1/100r), ev.note_on(55, time: 1/10r)]
      s = described_class.new(source(*events), voices: 2, spares: 0, steal: [:quietest]) { |v|
        (v.trigger * 10).filter(:lowpass, cutoff: v.freq, quality: 100)
      }
      render(s, buffers: 9)
      levels = s.notes.map(&:level)
      expect(levels[0]).to be > levels[1] * 5
      expect(levels[0]).to eq(s.notes[0].level_check.call)
      render(s, buffers: 2)
      expect(s.lanes[0].note).to eq(48)
      expect(s.lanes[1].note).to eq(55)
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

  describe 'same-note retriggers' do
    # Two voices and one spare: 52 and 48 (velocity 1) ring with long
    # decays, then 48 is struck again at 0.5 s with +vel+.
    def ringing(vel, mode)
      events = [
        ev.note_on(52), ev.note_on(48, 1.0, time: 1/100r),
        ev.note_off(52, time: 5/100r), ev.note_off(48, time: 5/100r),
        ev.note_on(48, vel, time: 1/2r), ev.note_off(48, time: 6/10r),
      ]
      synth = described_class.new(source(*events), voices: 2, spares: 1, retrigger: mode) { |v|
        v.amp_env(0.001, 2, 0, 1, curve: :linear)
      }
      render(synth, buffers: 70, individual: true)
    end

    it 'defaults to :reuse and rejects unknown modes' do
      expect(described_class.new(source) { |v| v.gate }.retrigger).to eq(:reuse)
      expect { described_class.new(source, retrigger: :bogus) { |v| v.gate } }.to raise_error(ArgumentError, /retrigger/)
    end

    it 'with :reuse, drops a ringing note to a softer re-strike' do
      l0, l1, l2 = ringing(0.1, :reuse)
      before = peak(l1, 0.49, 0.5)
      expect(peak(l1, 0.505, 0.51)).to be < before * 0.5
      expect(peak(l0, 0.55, 0.6)).to be > 0.3 # 52 keeps ringing
      expect(peak(l2, 0, 0.7)).to eq(0)
    end

    [:louder, :new_voice].each do |mode|
      it "with #{mode}, plays a softer re-strike on a new voice, letting the ringing note ring" do
        l0, l1, l2 = ringing(0.1, mode)
        expect(peak(l1, 0.55, 0.6)).to be > 0.4 # the old 48 rings on (releasing)
        expect(peak(l2, 0.5, 0.6)).to be > 0    # the new 48
        expect(peak(l0, 0.52, 0.6)).to eq(0)    # 52 was choked
      end
    end

    it 'with :louder, restarts the ringing lane for a louder re-strike, unlike :new_voice' do
      louder = ringing(1, :louder)
      expect(peak(louder[1], 0.505, 0.51)).to be > 0.99
      expect(peak(louder[2], 0, 0.7)).to eq(0)

      new_voice = ringing(1, :new_voice)
      expect(peak(new_voice[2], 0.505, 0.51)).to be > 0.99
      expect(peak(new_voice[1], 0.55, 0.6)).to be > 0.4
    end

    it 'with :add, sets the lane envelopes to add their peaks, so re-strikes never drop' do
      seen = []
      described_class.new(source, voices: 1, retrigger: :add) { |v| (seen << v.amp_env).last }
      expect(seen.map(&:retrigger)).to all(eq(:add))

      l0, l1, l2 = ringing(0.1, :add)
      before = l1[(0.5 * 48000).round - 1]
      expect(peak(l1, 0.5, 0.505)).to be >= before # never drops (+3 dB over 0.1's peak is below the ring)
      expect(peak(l2, 0, 0.7)).to eq(0)
      expect(peak(l0, 0.55, 0.6)).to be > 0.3
    end

    describe 'key sync' do
      # The 48 lane of #ringing as [tone, envelope] channels, with a
      # key-synced sine (or a free one).
      def ringing_tone(mode, vel: 0.1, free: false)
        events = [
          ev.note_on(52), ev.note_on(48, 1.0, time: 1/100r),
          ev.note_off(52, time: 5/100r), ev.note_off(48, time: 5/100r),
          ev.note_on(48, vel, time: 1/2r), ev.note_off(48, time: 6/10r),
        ]
        synth = described_class.new(source(*events), voices: 2, spares: 1, retrigger: mode) { |v|
          MB::Sound.stereo(free ? v.hz.sine.free : v.hz.sine, v.amp_env(0.001, 2, 0, 1, curve: :linear))
        }
        70.times.map { synth.sample_individual(480)[1].map(&:dup) }.transpose.map { |l| l.reduce(:concatenate) }
      end

      # A sine at 48's frequency starting at sample +start+, for samples
      # +range+.
      def sine_from(start, range)
        f = MB::Sound.tuning.frequency_of(48)
        Numo::DFloat.cast(range.map { |n| Math.sin(2 * Math::PI * f * (n - start) / 48000.0) })
      end

      let(:fresh) { 480 }        # 48's first note-on (a fresh voice)
      let(:restrike) { 24000 }   # its re-strike at 0.5 s

      [:add, :ring, :string].each do |mode|
        it "with #{mode}, keeps the phase of a ringing lane when it is struck again" do
          tone, env = ringing_tone(mode)
          expect(env[restrike - 1]).to be > 0.5 # still ringing

          # A fresh voice resets at its note-on; the re-strike continues
          after_fresh = (fresh + 40)...restrike
          expect((tone[after_fresh] - sine_from(fresh, after_fresh)).abs.max).to be < 1e-3
          later = restrike...(restrike + 4800)
          expect((tone[later] - sine_from(fresh, later)).abs.max).to be < 1e-3
        end
      end

      it 'with :reuse (:restart envelopes), still resets a ringing lane struck again' do
        tone, env = ringing_tone(:reuse)
        expect(env[restrike - 1]).to be > 0.5
        later = (restrike + 40)...(restrike + 4800)
        expect((tone[later] - sine_from(fresh, later)).abs.max).to be > 0.5
        expect((tone[later] - sine_from(restrike, later)).abs.max).to be < 1e-3
      end

      it 'with :add, resets a lane struck after its envelopes have ended' do
        events = [
          ev.note_on(48, 1.0, time: 1/100r), ev.note_off(48, time: 5/100r),
          ev.note_on(48, 0.5, time: 1/2r), ev.note_off(48, time: 6/10r),
        ]
        synth = described_class.new(source(*events), voices: 1, mono: false, spares: 0, retrigger: :add, skip_idle: false) { |v|
          MB::Sound.stereo(v.hz.sine, v.amp_env(0.001, 0.01, 0, 0.01, curve: :linear))
        }
        tone, env = 70.times.map { synth.sample_individual(480)[0].map(&:dup) }.transpose.map { |l| l.reduce(:concatenate) }
        expect(env[(restrike - 4800)...restrike].abs.max).to eq(0)
        later = (restrike + 40)...(restrike + 4800)
        expect((tone[later] - sine_from(restrike, later)).abs.max).to be < 1e-3
      end
    end

    describe ':ring (alias :bell)' do
      # 48 rings loud on lane 0, a softer 48 on lane 1 (a voice was free),
      # then 48 again at 0.5 s with every voice busy, and 55 at 0.6 s.
      def bells(mode, **opts)
        events = [
          ev.note_on(48, 1.0), ev.note_off(48, time: 5/100r),
          ev.note_on(48, 0.3, time: 1/10r), ev.note_off(48, time: 15/100r),
          ev.note_on(48, 0.5, time: 1/2r), ev.note_off(48, time: 55/100r),
          ev.note_on(55, 0.5, time: 6/10r), ev.note_off(55, time: 65/100r),
        ]
        synth = described_class.new(source(*events), voices: 2, spares: 1, retrigger: mode, **opts) { |v|
          v.amp_env(0.001, 3, 0, 3, curve: :linear)
        }
        [synth, render(synth, buffers: 80, individual: true)]
      end

      it 'reuses the quietest lane playing the note, adding energy, then steals the quietest lane' do
        synth, (l0, l1, l2) = bells(:ring)
        expect(synth.retrigger).to eq(:ring)
        expect(synth.allocator.retrigger).to eq(:quietest)
        expect(synth.allocator.steal).to eq(described_class::RING_STEAL)

        # Lane 1 (the soft 48) gets the third strike and rises above its level
        before = l1[(0.5 * 48000).round - 1]
        expect(peak(l1, 0.5, 0.505)).to be > before
        expect(peak(l1, 0.5, 0.505)).to be < 1
        # Lane 0 (the loud 48) rings on until 55 steals the quietest lane
        expect(peak(l0, 0.55, 0.6)).to be > 0.5
        expect(peak(l2, 0.6, 0.61)).to be > 0 # 55 on the spare
        quietest_choked = [l0, l1].count { |l| peak(l, 0.62, 0.7) == 0 }
        expect(quietest_choked).to eq(1)
        expect(peak(l0, 0.62, 0.7)).to be > 0 # the loud one kept ringing
      end

      it 'is the same as :bell, and takes a steal chain' do
        expect(bells(:bell)[1].map(&:to_a)).to eq(bells(:ring)[1].map(&:to_a))
        expect(bells(:ring, steal: :oldest)[0].allocator.steal).to eq([:oldest])
      end
    end

    describe ':string' do
      it 'restarts the lane of a ringing key even with voices free, envelopes adding' do
        seen = []
        s = described_class.new(source, voices: 2, retrigger: :string) { |v| (seen << v.amp_env).last }
        expect(s.retrigger).to eq(:string)
        expect(s.allocator.retrigger).to eq(:per_key)
        expect(s.allocator.steal).to eq(MB::Sound::MIDI::Allocator::DEFAULT_STEAL)
        expect(seen.map(&:retrigger)).to all(eq(:add))

        # Every voice busy: the same as :add
        expect(ringing(0.5, :string).map(&:to_a)).to eq(ringing(0.5, :add).map(&:to_a))

        # Voices free: :add takes a new lane (doubling the key), :string doesn't
        events = [ev.note_on(48, 1.0), ev.note_off(48, time: 5/100r), ev.note_on(48, 0.2, time: 1/2r), ev.note_off(48, time: 6/10r)]
        mk = ->(mode) {
          render(described_class.new(source(*events), voices: 4, spares: 0, retrigger: mode) { |v| v.amp_env(0.001, 2, 0, 1, curve: :linear) }, buffers: 70, individual: true)
        }
        add = mk.(:add)
        string = mk.(:string)
        expect(peak(add[1], 0.5, 0.6)).to be > 0
        expect(string[1..].map { |l| peak(l, 0, 0.7) }).to all(eq(0))
        before = string[0][(0.5 * 48000).round - 1]
        expect(peak(string[0], 0.5, 0.52)).to be_between(before, before * 1.01) # 0.2 adds little to the ring
      end
    end

    it 'renders the same every time in each mode' do
      [:reuse, :louder, :new_voice, :add, :ring, :string].each do |mode|
        [0.1, 1].each do |vel|
          expect(ringing(vel, mode).map(&:to_a)).to eq(ringing(vel, mode).map(&:to_a))
        end
      end
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

    it 'lets lanes without envelopes ring out after a finite source' do
      events = [ev.note_on(48), ev.note_off(48, time: 1/100r)]
      mk = -> {
        described_class.new(source(*events, last: nil), voices: 2, tail: 0) { |v|
          v.trigger.filter(:lowpass, cutoff: v.freq, quality: 30)
        }
      }

      s = mk.()
      out = []
      ended_at = nil
      while (b = s.sample(480)) && out.length < 1000
        out << b.dup
        ended_at ||= out.length if s.ended?
      end
      data = out.reduce(:concatenate)

      # The ping rings for a while after the file's last event, and the synth
      # ends one buffer after the ring falls below -90 dB
      last_sound = (data.abs > -90.db).where.to_a.last
      expect(last_sound / 48000.0).to be > 0.2
      expect(ended_at).to eq(last_sound / 480 + 2)
      expect(out.length).to eq(ended_at)

      # Repeatable
      again = []
      s2 = mk.()
      while (b = s2.sample(480)) && again.length < 1000
        again << b.dup
      end
      expect(again.reduce(:concatenate)).to eq(data)
    end

    it 'lets an envelope into a resonant filter ring out after a finite source' do
      events = [ev.note_on(48), ev.note_off(48, time: 1/20r)]
      s = described_class.new(source(*events, last: nil), voices: 1, mono: false, spares: 0, tail: 0) { |v|
        (v.hz.saw * v.amp_env(0, 0.02, 0, 0.02, curve: :linear)).filter(:lowpass, cutoff: v.freq, quality: 300)
      }
      out = []
      while (b = s.sample(480)) && out.length < 2000
        out << b.dup
      end
      data = out.reduce(:concatenate)

      # The envelope is idle at 0.07 s, but the filter rings much longer
      # (it was cut there, the envelope ending the lane's graph)
      expect(peak(data, 0.3, 0.4)).to be > 0.1
      last_sound = (data.abs > -90.db).where.to_a.last
      expect(last_sound / 48000.0).to be > 1
      expect(out.length).to eq(last_sound / 480 + 2)
    end

    it 'ends lanes whose output settles at a constant offset' do
      # A waveshaper that outputs DC for silence (like a wavetable shaper)
      s = described_class.new(source(ev.note_on(48), ev.note_off(48, time: 1/20r), last: nil), voices: 1, mono: false, spares: 0, tail: 0) { |v|
        v.hz.saw * v.amp_env(0, 0.02, 0, 0.02, curve: :linear) + 0.01
      }
      count = 0
      count += 1 while s.sample(480) && count < 1000
      expect(count).to be < 20
      expect(s.ended?).to eq(true)
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

  describe 'from a Notes' do
    it 'reads the Notes stream when given a Notes or made with Notes#synth' do
      notes = MB::Sound::Notes.new(source(ev.note_on(60, 100, time: 0.01r), ev.note_off(60, 0, time: 0.05r)))
      expect(MB::Sound::MIDI::Stream.for(notes)).to equal(notes.stream)

      s = notes.synth(voices: 2, spares: 0, seed: 1, &patch)
      expect(s).to be_a(described_class)
      data = render(s, buffers: 10)
      expect(peak(data, 0.012, 0.05)).to be > 0.3
      expect(peak(data, 0, 0.0099)).to eq(0)
    end
  end
end
