# Note names in clip prints and text views of clips and kits (parity-1,
# 2026-10-30; backlog 12.5: views for people and agents reading music).
RSpec.describe(MB::Sound::Sequence::View, :aggregate_failures) do
  let(:s) { MB::Sound }
  let(:riff) { s.seq(s::A3, s::C4, s::E4.n4, s::G4, !s::A4, s::Fs2.n2).n8 }
  let(:beat) { s.grid(16, kick: 'X...x...x..x....', snare: '....X.......X..?', hat: 'x.x.x.x.x.x.x5xf') }

  describe 'Event#to_s and Clip#to_s' do
    it 'print note numbers as note names' do
      expect(riff.events.first.to_s).to eq('A3@0+n8')
      expect(riff.events.first.inspect).to eq('#<Event A3@0+n8>')
      expect(riff.to_s).to eq('Seq(5/4: A3@0+n8, C4@1/8+n8, E4@1/4+n4, G4@1/2+n8, A4@5/8+n8 v1.0 !, Fs2@3/4+n2)')
      expect(beat.to_s).to start_with('Kit(:kick => Seq(n1: C2@0+n16 v1.0 !, C2@1/4+n16')
    end

    it 'keep numbers for clips of other values, one way per clip' do
      expect(s.seq(0, 7, 12).n4.to_s).to eq('Seq(3/4: 0.0@0+n4, 7@1/4+n4, 12@1/2+n4)')
      expect(s.seq(200, 800).n4.to_s).to eq('Seq(n2: 200@0+n4, 800@1/4+n4)')
      expect(s.seq(0.5, 61.5).n4.to_s).to eq('Seq(n2: 0.5@0+n4, 61.5@1/4+n4)')
      expect(MB::Sound::Sequence::Event.new(start: 0r, length: 1/4r, value: 5, velocity: 0.75).to_s).to eq('5@0+n4')
    end
  end

  describe 'Clip#show and Kit#show' do
    it 'shows a kit as grid rows that parse back' do
      v = beat.show
      expect(v.to_s).to eq(<<~TEXT.chomp)
        grid in steps of 1/16, n1 long
        kick   X...x...x..x....
        snare  ....X.......X..?
        hat    x.x.x.x.x.x.x5xf
      TEXT
      expect(v.rows).to eq(kick: 'X...x...x..x....', snare: '....X.......X..?', hat: 'x.x.x.x.x.x.x5xf')
      expect(s.grid(16, **v.rows).to_s).to eq(beat.to_s)
      expect(v.inspect).to eq('#<MB::Sound::Sequence::View :grid, 4 lines>')
    end

    it 'shows a clip as a grid of note rows, a piano roll, and scale degrees' do
      expect(riff.show.to_s).to eq(<<~TEXT.chomp)
        grid in steps of 1/16, 5/4 long
        A4   ..........X-....|....
        G4   ........x-......|....
        E4   ....x---........|....
        C4   ..x-............|....
        A3   x-..............|....
        Fs2  ............x---|----
      TEXT

      roll = riff.show(:roll).to_s.lines
      expect(roll[1]).to eq("     1                2\n")
      expect(roll.length).to eq(2 + (s::A4.number - s::Fs2.number + 1))
      expect(roll[3]).to eq("Gs4  ................|....\n")

      expect(riff.show(:degrees, scale: s.scale(:minor, :a)).to_s).to eq(<<~TEXT.chomp)
        degrees in steps of 1/16, 5/4 long, A4 minor, 1 = A3
        bar 1  1    -    3    -    5    -    -    -    7    -    1'   -    #6,, -    -    -
        bar 2  -    -    -    -
      TEXT
    end

    it 'joins chords with / and reads the session key by default' do
      chords = s.seq([s::C3, s::E3, s::G3], [s::D3, s::F3, s::A3]).n2
      expect(chords.show(:degrees, scale: s.scale(:major, :c)).to_s.lines.last).to start_with('bar 1  1/3/5 -     -')
      expect(chords.show(:degrees).to_s).to include(s.scale.to_s)
    end

    it 'finds triplet steps, and says when notes fall between steps' do
      expect(s.seq(s::C4, s::D4, s::E4).n8.t.show.to_s).to start_with('grid in steps of 1/48, n4 long')
      loose = s.seq(s::C4, s::E4).n8.humanize(3.ms, seed: 2)
      expect(loose.show.to_s).to start_with('grid in steps of 1/32 (about: some notes are between steps)')
      expect(loose.show(step: 16).to_s).to start_with('grid in steps of 1/16 (about')
    end

    it 'wraps long clips at bar lines' do
      long = s.seq(s::A2, s::C3, s::E3, s::A3).n8 * 16
      lines = long.show(width: 60).to_s.lines
      expect(lines.map { |l| l.chomp.length }.max).to be <= 60
      expect(lines.count { |l| l.start_with?('A3') }).to be > 1
    end

    it 'shows one cycle of a looping clip, and refuses unknown views with a hint' do
      expect(s.seq(s::C4).n4.loop.show.to_s).to include('C4  x---')
      expect { riff.show(:rol) }.to raise_error(ArgumentError, /did you mean :roll/)
      expect { beat.show(:degrees) }.to raise_error(ArgumentError, /no scale degrees/)
      expect(MB::Sound::Sequence::Clip.new([]).show.to_s).to eq('(empty clip)')
    end
  end
end
