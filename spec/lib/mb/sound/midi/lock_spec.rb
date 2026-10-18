RSpec.describe(MB::Sound::MIDI::Lock, :midi_transforms) do
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:white) { MB::Sound::MIDI::Lock::WHITE }

  # A cents scale (5-limit-ish, not 12-TET): pelog-like steps
  let(:cents) { MB::Sound::Scale.new([0, 120.cents, 270.cents, 540.cents, 670.cents, 790.cents, 950.cents], root: 0) }

  def scales
    {
      5 => MB::Sound::Scale[:minor_pentatonic],
      6 => MB::Sound::Scale[:blues],
      7 => MB::Sound::Scale[:dorian],
      8 => MB::Sound::Scale[:diminished],
      12 => MB::Sound::Scale[:chromatic],
      cents: cents,
    }
  end

  def map(m, note, pos = 0r)
    m.map(note, pos, transport: transport)
  end

  describe described_class::Degrees do
    it 'puts scale notes on every white key and passing notes between, for every root, size, and layout' do
      (0..11).each do |root|
        scales.each do |size, base|
          sc = base.with_root(root)
          [:flow, :fit].each do |layout|
            m = described_class.new(sc, layout: layout)
            (36..95).each do |key|
              n = map(m, key)
              within = key % 12
              where = "#{sc} #{layout} key #{key}"
              if white.include?(within)
                expect(sc.include?(n)).to eq(true), where
                next
              end
              lo = map(m, key - 1)
              hi = map(m, key + 1)
              if n.nil?
                expect(hi - lo).to be <= 1, "#{where}: silent between #{lo} and #{hi}"
              else
                expect(n).to be > lo, where
                expect(n).to be < hi, where
                expect(n).to eq(hi - 1) if hi - lo >= 3 && (hi - lo) == (hi - lo).round
                expect(n).to eq((lo + hi) / 2r) if (hi - lo) != (hi - lo).round
              end
            end
          end
        end
      end
    end

    it 'flows one degree per white key from the root on middle C' do
      scales.each_value do |sc|
        m = described_class.new(sc.with_root(2), layout: :flow)
        notes = (48..84).select { |k| white.include?(k % 12) }.map { |k| map(m, k) }
        steps = notes.each_cons(2).map { |a, b| sc.with_root(2).degree(b)[0] - sc.with_root(2).degree(a)[0] }
        expect(steps.uniq).to eq([1])
        expect(map(m, 60) % 12).to eq(2)
      end
    end

    it 'fits the root on every C' do
      (0..11).each do |root|
        scales.each_value do |base|
          sc = base.with_root(root)
          m = described_class.new(sc, layout: :fit)
          [36, 48, 60, 72, 84].each do |c|
            expect(map(m, c) % sc.period).to eq(sc.root_class), "#{sc} at #{c}"
            expect(map(m, c + 12) - map(m, c)).to eq(sc.period)
          end
        end
      end
    end

    it 'silences or lowers black keys on request' do
      sc = MB::Sound::Scale[:major]
      expect(map(described_class.new(sc, black: :silent), 61)).to be_nil
      expect(map(described_class.new(sc, black: :lower), 61)).to eq(60)
      expect(map(described_class.new(sc), 61)).to eq(61)
    end

    it 'gives cents notes as pitch marks with micro: :mark' do
      m = described_class.new(cents, micro: :mark)
      e = m.event(MB::Sound::MIDI::Event.note_on(61), 0r, transport: transport)
      expect(e.note).to be_a(Integer)
      expect(e.note + e.pitch).to be_within(1e-9).of(map(m, 61))
      expect(e.bytes).not_to be_nil
    end

    it 'follows the session key at each note' do
      transport.key_change(MB::Sound::MusicalKey.new(root: 2, mode: :dorian), at: 1r)
      m = described_class.new(layout: :fit)
      expect(map(m, 60, 0r)).to eq(60)
      expect(map(m, 60, 1r)).to eq(62)
      expect(map(described_class.new(:lydian, layout: :fit), 65, 1r)).to eq(68) # (D lydian's 4th degree on the F key: G#)
    end
  end

  describe described_class::Chord do
    it 'snaps to chord tones, extends above the voicing, avoids, and adds a bass' do
      ch = [60, 64, 67] # C major
      plain = described_class.new(from: ch)
      expect((55..76).map { |k| map(plain, k) % 12 }.uniq.sort).to eq([0, 4, 7])

      above = described_class.new(from: ch, extend: :above)
      expect((60..67).map { |k| map(above, k) % 12 }.uniq.sort).to eq([0, 4, 7])
      high = (68..90).map { |k| map(above, k) % 12 }.uniq.sort
      expect(high).to include(11, 2, 9)   # maj7, 9, 13 in C major
      expect(high).not_to include(5)      # natural 11 over a major third is avoided
      expect((68..90).map { |k| map(described_class.new(from: ch, extend: :above, avoid: false), k) % 12 }.uniq).to include(5)

      bass = described_class.new(from: ch, bass: :root_fifth)
      expect((40..59).map { |k| map(bass, k) % 12 }.uniq.sort).to eq([0, 7])
    end

    it 'reads chords from degrees per bar and from clips' do
      m = described_class.new(from: [1, 4])
      expect(map(m, 60, 0r) % 12).to eq(0)
      expect([0, 5, 9]).to include(map(m, 60, 1r) % 12)
      clip = MB::Sound::Sequence::Clip.new([60, 64, 67].map { |n| MB::Sound::Sequence::Event.new(start: 0r, length: 1r, value: n) } +
        [57, 60, 64].map { |n| MB::Sound::Sequence::Event.new(start: 1r, length: 1r, value: n) }, length: 2, loop: true)
      c = described_class.new(from: clip)
      expect(map(c, 69, 0r)).to eq(67)
      expect(map(c, 69, 1r)).to eq(69)
      expect(map(c, 69, 3r)).to eq(69)
    end
  end

  describe described_class::Style do
    it 'names the intents and prints back, with overrides' do
      expect(described_class.new(:play).to_s).to eq('lock(:play)')
      expect(described_class.new(:chord, extend: true).to_s).to eq('lock(:chord, extend: true)')
      expect { described_class.new(:plya) }.to raise_error(ArgumentError, /did you mean :play/)
      expect(described_class.new(:off).off?).to eq(true)
    end

    it 'follows a param style' do
      clip = MB::Sound.seq(:mash, :along).n1.loop rescue skip('no symbol steps')
      s = described_class.new(clip)
      expect(s.map_note(61, 0r, transport: transport)).to be_nil
      expect(s.map_note(61, 1r, transport: transport)).to eq(60)
    end
  end

  describe 'stream transforms' do
    it 'keep a held note mapped when the key changes under it' do
      transport.key_change(MB::Sound::MusicalKey.new(root: 2, mode: :dorian), at: 1/4r)
      s = list_stream(ev.note_on(60, time: 0r), ev.note_off(60, time: 1r))
      out = read_all(s.lock(:play, transport: transport))
      expect(out.map { |e| e.first(2) }).to eq([[:note_on, 60], [:note_off, 60]])
      expect_balanced(out)
    end

    it 'drop silent keys and their note-offs' do
      out = read_all(list_stream(ev.note_on(61, time: 0r), ev.note_off(61, time: 1/8r)).lock(:mash, transport: transport))
      expect(out).to eq([])
    end

    it 'print through recipes and graph documents' do
      g = MB::Sound.seq(60, 61, 62).n8.loop.notes.lock(:chord, from: [1, 4], bass: :root_fifth).degrees(:dorian, layout: :fit).snap.synth { |v| v.hz.saw * v.amp_env }
      text = g.to_ruby
      expect(text).to include('.lock(:chord, from: [1, 4], bass: :root_fifth).degrees(:dorian, layout: :fit).snap')
      g2 = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(g, name: :lock_test))
      expect(g2.to_ruby).to eq(text)
    end
  end

  describe 'the session input lock' do
    let(:session) { MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), channels: 1, realtime: false, raise_errors: true, transport: transport) }
    after { session.close }

    it 'maps live notes at their positions, keeping held notes, logging what sounded' do
      mi = session.midi_in
      mi.input = list_stream(ev.note_on(61, time: 0r), ev.note_on(62, time: 0r), ev.note_off(62, time: 1/50r), ev.note_off(61, time: 1/50r))
      MB::Sound::Session.with_context(session: session) { MB::Sound.lock(:mash) }
      session.process_buffer(800)
      expect(mi.span.events.map(&:event).select(&:note_on?).map(&:note)).to eq([62]) # (C#: silent in C major)
      MB::Sound::Session.with_context(session: session) { MB::Sound.key(:d) }
      session.process_buffer(800)
      # (D in D major would be E now; the held note ends as it sounded)
      expect(mi.span.events.map(&:event).map { |e| [e.type, e.note] }).to eq([[:note_off, 62]])
      expect(session.midi_log.map { |row| row.last[1] }).to eq([62, 62])
    end
  end
end
