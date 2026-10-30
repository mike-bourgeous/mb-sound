# Stream versions of the clip operations, and the shared cores of the feel
# transforms (midi-consol-1, 2026-10-16: "shared core, two front ends").
RSpec.describe('MIDI clip operations on streams', :midi_transforms, :aggregate_failures) do
  let(:s) { MB::Sound }
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }

  # [value as a number, start, length, velocity] of every event of +clip+.
  def rows(clip)
    clip.events.map { |e| [MB::Sound::Sequence::Clip.ghost_number(e.value), e.start, e.length, e.velocity.round(6)] }
  end

  # Eight notes, a quarter second apart (an 8th at 120 BPM), an eighth
  # second long.
  def run_stream
    list_stream(*8.times.flat_map { |i| [ev.note_on(60 + i, 0.5, time: i / 4r), ev.note_off(60 + i, time: i / 4r + 1/8r)] })
  end

  let(:riff) { s.seq(s::C4, s::E4, s::G4, s::B4, s::A4, s::F4, s::D4, s::C4).n8 }

  describe 'the shared cores give clips and streams the same notes where both can' do
    it 'swings a clip and its baked stream alike' do
      fx = MB::Sound::MIDI::Transform::Spec.new.swing(0.6)
      expect(rows(riff.n16.bake(fx))).to eq(rows(riff.n16.swing(0.6)))
      expect(rows(riff.bake(fx.class.new.swing(2/3r, 8)))).to eq(rows(riff.swing(2/3r, 8)))
    end

    it 'ratchets with a rate alike' do
      fx = MB::Sound::MIDI::Transform::Spec.new.ratchet(3, rate: 1.n32, velocity: 1.0..0.5)
      expect(rows(riff.bake(fx))).to eq(rows(riff.ratchet(3, rate: 1.n32, velocity: 1.0..0.5)))
    end

    it 'lengthens notes alike with legato' do
      fx = MB::Sound::MIDI::Transform::Spec.new.legato(1.5)
      expect(rows(riff.legato(0.5).bake(fx))).to eq(rows(riff.legato(0.75)))
      fx = MB::Sound::MIDI::Transform::Spec.new.legato(1.n32)
      expect(rows(riff.bake(fx))).to eq(rows(riff.legato(1.n32)))
    end

    it 'snaps to ghost chords alike, with chords following the timeline' do
      hook = s.seq(s::A3, s::C4, s::Rest, s::E4, s::C4, s::Rest, s::A3, s::B3).n8.repeat(4)
      fx = MB::Sound::MIDI::Transform::Spec.new.ghost_chords(1, 4, 7, 6, scale: s.scale(:minor, :a))
      expect(rows(hook.bake(fx))).to eq(rows(hook.ghost_chords(1, 4, 7, 6, scale: s.scale(:minor, :a))))
    end

    it 'sets velocities alike, clamped to 0..1 (Feel.fixed_velocity)' do
      seq = s.seq(s::C4, s::E4, s.seq(s::G4, s::B4).n16).n8
      [-0.5, 0, 0.3, 1, 1.7, 3/4r].each do |v|
        want = v.to_f.clamp(0.0, 1.0)
        fx = MB::Sound::MIDI::Transform::Spec.new.vel(v)
        expect(rows(riff.bake(fx))).to eq(rows(riff.vel(v)))
        expect(rows(riff.vel(v)).map(&:last).uniq).to eq([want])
        expect(rows(seq.vel(v)).map(&:last).uniq).to eq([want])
        expect(ons(read_all(run_stream.vel(v))).map(&:last).uniq).to eq([want])
      end
      [nil, '0.5', Complex(0.5, 1), Float::NAN].each do |bad|
        expect { riff.vel(bad) }.to raise_error(ArgumentError, /vel takes a velocity/)
        expect { seq.vel(bad) }.to raise_error(ArgumentError, /vel takes a velocity/)
        expect { run_stream.vel(bad) }.to raise_error(ArgumentError, /vel takes a velocity/)
      end
    end

    it 'transposes by scale degrees alike' do
      fx = MB::Sound::MIDI::Transform::Spec.new.transpose(2, scale: :minor, root: :a)
      expect(rows(riff.bake(fx))).to eq(rows(riff.transpose(2, scale: :minor, root: :a)))
    end
  end

  describe 'Stream#swing' do
    it 'delays notes on the offbeat steps of the timeline, warping note-offs too' do
      out = read_all(run_stream.swing(0.75, 8, transport: transport))
      expect_balanced(out)
      # 8ths at 120 BPM are 1/4 s; every second one moves to 3/4 of the pair
      expect(ons(out).map { |e| e[2] }).to eq([0r, 3/8r, 1/2r, 7/8r, 1r, 11/8r, 3/2r, 15/8r])
      # An off at 1/8 (halfway through the first step) warps to 3/16
      expect(out.find { |e| e[0] == :note_off && e[1] == 60 }[2]).to eq(3/16r)
    end

    it 'only delays, so amounts start at 0.5' do
      expect { run_stream.swing(0.4) }.to raise_error(ArgumentError, /0\.5/)
      expect(MB::Sound::Sequence::Clip.new([]).swing(0.4)).to be_a(MB::Sound::Sequence::Clip)
    end

    it 'gives readers of any size the same events' do
      a = read_all(run_stream.swing(0.6, transport: transport))
      b = read_all(run_stream.swing(0.6, transport: transport), chunk: 128/48000r)
      expect(b).to eq(a)
    end
  end

  describe 'Stream#chance' do
    it 'drops notes (with their note-offs) repeatably from the seed' do
      a = read_all(run_stream.chance(0.5, seed: 3))
      expect_balanced(a)
      expect(ons(a).length).to be_between(1, 7)
      expect(read_all(run_stream.maybe(0.5, seed: 3), chunk: 1/10r)).to eq(a)
      expect(ons(read_all(run_stream.chance(1)))).to eq(ons(read_all(run_stream)))
      expect(ons(read_all(run_stream.chance(0)))).to eq([])
      expect { run_stream.chance(2) }.to raise_error(ArgumentError, /probability/)
    end
  end

  describe 'Stream#every' do
    it 'plays notes only in every nth bar of the timeline' do
      # One note per beat for 4 bars at 120 BPM (a bar is 2 s)
      st = list_stream(*16.times.flat_map { |i| [ev.note_on(60, time: i / 2r), ev.note_off(60, time: i / 2r + 1/4r)] })
      out = read_all(st.every(2, from: 2, transport: transport))
      expect_balanced(out)
      expect(ons(out).map { |e| e[2] }).to eq([2r, 5/2r, 3r, 7/2r, 6r, 13/2r, 7r, 15/2r])
    end
  end

  describe 'Stream#legato' do
    it 'lengthens notes by a fraction of their played length' do
      out = read_all(run_stream.legato(1.5))
      expect_balanced(out)
      expect(out.select { |e| e[0] == :note_off }.map { |e| e[2] }).to eq(8.times.map { |i| i / 4r + 3/16r })
    end

    it 'gives every note a length given one, like len' do
      expect(read_all(run_stream.legato(1.n32, transport: transport))).to eq(read_all(run_stream.len(1.n32, transport: transport)))
    end

    it 'shortens notes without a length hint only with a live_error (an error in specs and scripts)' do
      expect { read_all(run_stream.legato(0.5)) }.to raise_error(ArgumentError, /length hint/)
    end

    it 'passes notes without a hint through unchanged in live mode, with one notice' do
      MB::Sound.live = true
      out = nil
      expect { out = read_all(run_stream.legato(0.5)) }.to output(/length hint/).to_stderr
      expect(out).to eq(read_all(run_stream))
    ensure
      MB::Sound.live = false
    end
  end

  describe 'length hints and Stream#legato below 1' do
    # A note-on at +on+ with a length hint (seconds, or a Duration), and
    # its note-off at +off+.
    def hinted(note, on, off, hint = off - on)
      [ev.note_on(note, 0.5, time: on).with_length_hint(hint), ev.note_off(note, time: off)]
    end

    def offs(out)
      out.select { |e| e[0] == :note_off }.map { |e| [e[1], e[2]] }
    end

    it 'puts Duration hints on clip notes, seconds on arp, gated echo, and ratchet notes; chords and echoes copy them' do
      clip_ons = read_events(riff.stream(transport: transport)).select(&:note_on?)
      expect(clip_ons.map(&:length_hint)).to all(eq(1.n8))
      expect(clip_ons.map(&:length_hint)).to all(be_a(MB::Sound::Sequence::Duration))

      arp = read_events(list_stream(*hinted(60, 0r, 1r)).arp(:up, 8, gate: 0.5, transport: transport)).select(&:note_on?)
      expect(arp.map(&:length_hint).uniq).to eq([1/8r])

      echo = read_events(list_stream(*hinted(60, 0r, 1/10r)).echo(0.25, 2, gate: 0.5)).select(&:note_on?)
      expect(echo.map(&:length_hint)).to eq([1/10r, 1/8r, 1/8r])
      echo = read_events(list_stream(*hinted(60, 0r, 1/10r)).echo(0.25, 1)).select(&:note_on?)
      expect(echo.map(&:length_hint)).to eq([1/10r, 1/10r])

      chord = read_events(list_stream(*hinted(60, 0r, 1/10r)).chord(:maj)).select(&:note_on?)
      expect(chord.map(&:length_hint)).to eq([1/10r] * 3)

      rat = read_events(list_stream(*hinted(60, 0r, 1r)).ratchet(3, rate: 1/4r)).select(&:note_on?)
      expect(rat.map(&:length_hint)).to eq([1/4r, 1/4r, 1/2r])
    end

    it 'shortens clip notes with no added latency, like Clip#legato' do
      expect(rows(riff.bake(MB::Sound::MIDI::Transform::Spec.new.legato(0.5)))).to eq(rows(riff.legato(0.5)))
      out = read_all(riff.stream(transport: transport).legato(0.25), chunk: 1/100r)
      expect_balanced(out)
      expect(offs(out).first).to eq([60, 1/16r]) # an 8th is 1/4 s at 120 BPM
    end

    it 'keeps a re-struck note, dropping the old planned note-off' do
      st = list_stream(*hinted(60, 0r, 1r), *hinted(60, 3/10r, 13/10r))
      out = read_all(st.legato(0.5), chunk: 1/20r)
      expect(out.map { |e| e.first(3) }).to eq([[:note_on, 60, 0r], [:note_off, 60, 3/10r], [:note_on, 60, 3/10r], [:note_off, 60, 4/5r]])
    end

    it 'sends a played note-off earlier than the planned one' do
      st = list_stream(ev.note_on(60, 0.5, time: 0r).with_length_hint(1r), ev.note_off(60, time: 1/5r))
      out = read_all(st.legato(0.5), chunk: 1/20r)
      expect_balanced(out)
      expect(offs(out)).to eq([[60, 1/5r]])
    end

    it 'sends planned note-offs after the stream ends' do
      st = list_stream(ev.note_on(60, 0.5, time: 0r).with_length_hint(1r))
      out = read_all(st.legato(0.5))
      expect(offs(out)).to eq([[60, 1/2r]])
    end

    it 'reads Duration hints at the current tempo' do
      st = -> { list_stream(ev.note_on(60, 0.5, time: 0r).with_length_hint(1.n4), ev.note_off(60, time: 4r)) }
      t = MB::Sound::Sequence::Transport.new(bpm: 120)
      a = st.().legato(0.5, transport: t)
      t.bpm = 60
      expect(offs(read_all(a))).to eq([[60, 1/2r]]) # a quarter is 1 s at 60 BPM
    end

    it 'follows quantize(ends:) and humanize before it' do
      st = list_stream(*hinted(60, 1/100r, 1/10r))
      out = read_all(st.quantize(16, ends: true, transport: transport).legato(0.5))
      # quantized to [1/8, 1/4) s, so half is 1/16 s
      expect(out.map { |e| e.first(3) }).to eq([[:note_on, 60, 1/8r], [:note_off, 60, 3/16r]])

      st = list_stream(*hinted(60, 0r, 1/10r))
      out = read_all(st.humanize(0.02, seed: 4).legato(0.5))
      on, off = out.map { |e| e[2] }
      expect(on).to be > 0
      expect(off - on).to eq(1/20r)
    end
  end

  describe 'Stream#ratchet' do
    it 'strikes each held note up to count times, rate apart, the last hit ending with the key' do
      st = list_stream(ev.note_on(60, 0.8, time: 0r), ev.note_off(60, time: 1r))
      out = read_all(st.ratchet(3, rate: 0.25, velocity: 0.8..0.4))
      expect_balanced(out)
      expect(out.map { |e| e.first(3) }).to eq([
        [:note_on, 60, 0r], [:note_off, 60, 1/4r], [:note_on, 60, 1/4r], [:note_off, 60, 1/2r], [:note_on, 60, 1/2r], [:note_off, 60, 1r],
      ])
      expect(ons(out).map(&:last)).to eq([0.8, 0.6, 0.4])
    end

    it 'stops striking when the key comes up' do
      st = list_stream(ev.note_on(60, time: 0r), ev.note_off(60, time: 0.3r))
      out = read_all(st.ratchet(8, rate: 0.25), chunk: 1/20r)
      expect_balanced(out)
      expect(out.map { |e| e.first(3) }).to eq([[:note_on, 60, 0r], [:note_off, 60, 1/4r], [:note_on, 60, 1/4r], [:note_off, 60, 3/10r]])
    end

    it 'needs a rate' do
      expect { run_stream.ratchet(3) }.to raise_error(ArgumentError, /rate:/)
    end
  end

  describe 'Stream#ghost_chords' do
    it 'snaps notes to the chord of each bar of the timeline' do
      # One A3..B3 note per beat at 120 BPM: bar 1 is Am, bar 2 Dm
      st = list_stream(*8.times.flat_map { |i| [ev.note_on(s::B3.number, time: i / 2r), ev.note_off(s::B3.number, time: i / 2r + 1/4r)] })
      out = read_all(st.ghost_chords(1, 4, scale: s.scale(:minor, :a), tie: :up, transport: transport))
      expect_balanced(out)
      expect(ons(out).map { |e| e[1] }).to eq([s::C4.number] * 4 + [s::A3.number] * 4)
    end

    it 'works on live input, following the timeline bars, and has no passing notes' do
      vin = MB::Sound::MIDI::VirtualInput.new(clock: -> { 0r })
      live = MB::Sound::MIDI::Stream.new(MB::Sound::MIDI::LiveSource.new(vin, timing: :asap))
      g = live.ghost_chords(1, 4, scale: s.scale(:minor, :a), tie: :up, transport: transport)
      r = g.reader
      vin.note_on(s::B3.number)
      first = r.next(1r).select(&:note_on?)
      r.next(1r) # into bar 2 (a bar is 2 s at 120 BPM)
      vin.note_on(s::B3.number)
      second = r.next(1/10r).select(&:note_on?)
      expect(first.map(&:note)).to eq([s::C4.number])
      expect(second.map(&:note)).to eq([s::A3.number])
      expect { run_stream.ghost_chords(1, passing: 1.n16) }.to raise_error(ArgumentError, /passing/)
    end
  end

  describe 'Stream#quantize(ends: true)' do
    it 'moves note-offs to the next step too, a fully quantized note lasting at least a step' do
      st = list_stream(ev.note_on(60, time: 1/100r), ev.note_off(60, time: 1/10r), ev.note_on(62, time: 1/8r), ev.note_off(62, time: 3/10r))
      out = read_all(st.quantize(16, ends: true, transport: transport))
      expect_balanced(out)
      # 16ths are 1/8 s: 60 starts at 1/8 and lasts a step; 62's off moves to 3/8
      expect(out.map { |e| e.first(3) }).to eq([[:note_on, 60, 1/8r], [:note_on, 62, 1/8r], [:note_off, 60, 1/4r], [:note_off, 62, 3/8r]])
    end
  end

  describe 'Stream#humanize' do
    it 'delays by up to 4 ms by default (maintainer decision 7, 2026-10-16)' do
      out = read_all(run_stream.humanize(seed: 2))
      delays = ons(out).each_with_index.map { |e, i| e[2] - i / 4r }
      expect(delays).to all(be_between(0, 0.004))
      expect(delays.max).to be > 0.002
    end
  end

  describe 'rotate and shift (parity-1, maintainer 2026-10-30: rotate wraps, shift shifts)' do
    it 'wraps a clip with rotate and drops what leaves it with shift' do
      clip = s.seq(s::C4, s::E4, s::G4, s::B4).n4
      expect(rows(clip.rotate(1.n4)).map(&:first)).to eq([71, 60, 64, 67])
      expect(rows(clip.rotate(1.n4)).map { |r| r[1] }).to eq([0r, 1/4r, 1/2r, 3/4r])
      expect(rows(clip.shift(1.n4))).to eq([[60, 1/4r, 1/4r, 0.75], [64, 1/2r, 1/4r, 0.75], [67, 3/4r, 1/4r, 0.75]])
      expect(rows(clip.shift(-1/4r))).to eq([[64, 0r, 1/4r, 0.75], [67, 1/4r, 1/4r, 0.75], [71, 1/2r, 1/4r, 0.75]])
      expect(clip.shift(1.n4).length).to eq(1r)
      expect(clip.shift(2r).events).to be_empty
      expect(riff.shift(1.n8).source).to eq(riff)
      expect(riff.rotate(1.n8).source).to eq(riff)
      expect { MB::Sound::Sequence::Clip.new([]).shift(1/4r) }.to raise_error(ArgumentError, /length/)
    end

    it 'shifts a stream later only, and refuses to rotate one, pointing to shift' do
      out = read_all(run_stream.shift(0.1))
      expect(ons(out).map { |e| e[2] }).to eq(8.times.map { |i| i / 4r + 0.1 })
      expect { run_stream.shift(-0.1) }.to raise_error(ArgumentError, /only shift notes later/)
      expect { run_stream.rotate(0.1) }.to raise_error(ArgumentError, /can't rotate.*did you mean shift/)
      expect { s.echo(1.n8, 1).rotate(1.n8) }.to raise_error(ArgumentError, /did you mean shift/)
    end

    it 'warns in live mode and plays the stream unchanged' do
      MB::Sound.live = true
      stream = run_stream
      result = nil
      expect { result = stream.rotate(0.1) }.to output(/can't rotate.*live mode: ignored/).to_stderr
      expect(result).to equal(stream)
    ensure
      MB::Sound.live = false
    end

    it 'loads clip shift in documents before format 6 as rotate (it was its alias)' do
      body = "seq(C4, E4, G4, B4).n4.shift(1.n4).synth { |v| v.hz.saw }\n"
      old = MB::Sound::GraphIO.load("graph 5\n#{body}")
      now = MB::Sound::GraphIO.load("graph 6\n#{body}")
      expect(old.to_ruby).to include('.rotate(1.n4)')
      expect(now.to_ruby).to include('.shift(1.n4)')
    end
  end

  describe 'the Clip front end' do
    it 'transposes by scale degrees, keeping Note values and chromatic results' do
      t = riff.transpose(2, scale: :minor, root: :a)
      expect(rows(t).map(&:first)).to eq([s::E4, s::G4, s::B4, s::D5, s::C5, s::A4, s::F4, s::E4].map(&:number))
      expect(rows(riff.transpose([1, 1.oct]))).to eq(rows(riff.transpose(13)))
      expect(riff.transpose(7.st).events.map(&:value)).to eq(riff.transpose(7).events.map(&:value))
      seq_t = s.seq(s::C4, s::E4).transpose(1, scale: :major, root: :c)
      expect(seq_t).to be_a(MB::Sound::Sequence::Seq)
      expect(seq_t.n8.events.map(&:value)).to eq([s::D4, s::F4].map(&:number))
      expect(riff.transpose(2, scale: :minor, root: :a).source).to eq(riff)

      notes = MB::Sound::Sequence::Clip.new([MB::Sound::Sequence::Event.new(start: 0r, length: 1/8r, value: s::C4, velocity: 1.0)])
      moved = notes.transpose(2, scale: :major, root: :c).events[0].value
      expect(moved).to be_a(MB::Sound::Note)
      expect(moved.number).to eq(s::E4.number)
    end

    it 'moves pitch-marked hits by semitones only' do
      hit = MB::Sound::Sequence::Clip.new([MB::Sound::Sequence::Event.new(start: 0r, length: 1/8r, value: 36, velocity: 1.0, pitch: 0.0)])
      expect(hit.transpose(3).events[0].pitch).to eq(3.0)
      expect { hit.transpose(2, scale: :minor) }.to raise_error(ArgumentError, /semitones/)
    end

    it 'quantizes only notes within window: of their step' do
      c = MB::Sound::Sequence::Clip.new([MB::Sound::Sequence::Event.new(start: 1/128r, length: 1/16r, value: 60, velocity: 1.0),
                                         MB::Sound::Sequence::Event.new(start: 5/32r, length: 1/16r, value: 62, velocity: 1.0)], length: 1)
      expect(c.quantize(16, window: 1/64r).events.map(&:start)).to eq([0r, 5/32r])
      expect(c.quantize(16).events.map(&:start)).to eq([0r, 3/16r])
    end

    it 'ratchets with a rate, the last hit lasting to the end of the note' do
      r = s.seq(s::C4.n4).ratchet(3, rate: 1.n16)
      expect(r.events.map { |e| [e.start, e.length] }).to eq([[0r, 1/16r], [1/16r, 1/16r], [1/8r, 1/8r]])
      expect(s.seq(s::C4.n16).ratchet(3, rate: 1.n32).events.length).to eq(2)
    end

    it 'gives every note a fixed length with note_length or a legato length' do
      expect(riff.note_length(1.n32).events.map(&:length).uniq).to eq([1/32r])
      expect(rows(riff.legato(1.n32))).to eq(rows(riff.note_length(32)))
      expect(riff.n4.loop.legato(1.n16).looping?).to eq(true)
    end
  end

  describe 'generator clips, per cycle (decision 5)' do
    let(:gen) { s.melody(s.scale(:minor, :a), 8, vary: true, seed: 3).loop }

    def nums(events)
      events.map { |e| MB::Sound::Sequence::Clip.ghost_number(e.value) }
    end

    it 'snaps every cycle to its place in the ghost progression' do
      g = gen.ghost_chords(1, 4, 7, 6, scale: s.scale(:minor, :a), tie: :down)
      expect(g.length).to eq(gen.length)
      repeated = nil
      expect { repeated = gen.repeat(4) }.to output(/finite/).to_stderr
      unrolled = repeated.ghost_chords(1, 4, 7, 6, scale: s.scale(:minor, :a), tie: :down)
      expect((0..3).flat_map { |c| nums(g.events_for(c)) }).to eq(nums(unrolled.events))
      expect(nums(g.events_for(17))).not_to eq(nums(gen.events_for(17))) # not just cycle 0
    end

    it 'permutes every cycle with the seed' do
      pm = gen.permute(seed: 5)
      changed = (0..7).count { |c|
        expect(nums(pm.events_for(c)).sort).to eq(nums(gen.events_for(c)).sort)
        expect(pm.events_for(c).map(&:start)).to eq(gen.events_for(c).map(&:start))
        nums(pm.events_for(c)) != nums(gen.events_for(c))
      }
      expect(changed).to be > 4
      expect { gen.permute([1, 0]) }.to raise_error(ArgumentError, /seed/)
    end

    it 'ratchets and truncates every cycle' do
      expect(gen.ratchet(2).events_for(5).length).to eq(gen.events_for(5).length * 2)
      t = gen.truncate(1/4r)
      expect(t.events_for(9).map(&:end_time).max).to be <= 1/4r
      expect(nums(t.events_for(9))).to eq(nums(gen.events_for(9).select { |e| e.start < 1/4r }))
    end
  end

  describe 'Transform::Spec' do
    it 'chains clip operations and applies them to streams' do
      fx = MB::Sound.echo(1.n8, 1).swing(0.6).chance(1).every(1).legato(1.2).ratchet(2, rate: 1.n32).ghost_chords(1).humanize(0)
      expect(fx.to_s).to start_with('echo(').and include('swing(0.6)', 'ghost_chords(1)')
      out = read_all(fx.apply(run_stream))
      expect_balanced(out)
      expect(ons(out)).not_to be_empty
    end

    it 'round-trips clip operations through recipes and graph documents' do
      c = s.seq(s::C4, s::E4).n8.loop.transpose(2, scale: s.scale(:minor, :a)).shift(1.n16).ratchet(2, rate: 1.n32).legato(1.n32)
      expect(c.to_ruby).to eq('seq(C4, E4).n8.loop.transpose(2, scale: scale(:minor, A4)).shift(1.n16).ratchet(2, rate: 1.n32).legato(1.n32)')
      text = "graph 3\nseq(C4, E4).n8.loop.bake(echo(1.n8, 1).swing(0.6).ratchet(2, rate: 1.n32).ghost_chords(1, 4)).synth { |v| v.hz.saw }\n"
      g = MB::Sound::GraphIO.load(text)
      expect(g.to_ruby).to include('bake(echo(1.n8, 1).swing(0.6).ratchet(2, rate: 1.n32).ghost_chords(1, 4))')
    end
  end
end
