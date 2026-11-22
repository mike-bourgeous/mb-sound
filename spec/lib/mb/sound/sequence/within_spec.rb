# Clip#within, Seq#within, generators, and MIDI::Stream#within / Notes
# (note-within-1): notes moved into a note or frequency range by octaves,
# keeping their pitch class (MB::Sound::OctaveFold).
RSpec.describe('within on clips, generators, and streams', :midi_transforms, :aggregate_failures) do
  let(:s) { MB::Sound }
  let(:lead) { s.seq(s::E4, s::G4, !s::B4, s::D5.n4, s::Fs3, s::C6).n8 }

  def number(v) = MB::Sound::Sequence::Clip.ghost_number(v)
  def numbers(clip) = clip.events.map { |e| number(e.value) }

  describe 'Clip#within' do
    it 'moves every note into the range, keeping pitch classes, rhythm, velocities, and marks' do
      bass = lead.within(s::E1..s::E2)
      expect(numbers(bass)).to eq([40, 31, 35, 38, 30, 36]) # E4 to E2: the fewest octaves, the top edge kept
      expect(numbers(bass).zip(numbers(lead)).map { |a, b| (a - b) % 12 }.uniq).to eq([0])
      expect(bass.events.map(&:start)).to eq(lead.events.map(&:start))
      expect(bass.events.map(&:length)).to eq(lead.events.map(&:length))
      expect(bass.events.map(&:velocity)).to eq(lead.events.map(&:velocity))
      expect(bass.events.map(&:accented)).to eq(lead.events.map(&:accented))
    end

    it 'takes frequency ranges and moves fixed frequencies in Hz' do
      c = s.seq(s::C4, 440.hz).n8.loop
      w = c.within(60.hz..120.hz)
      expect(number(w.events[0].value)).to eq(36)
      expect(w.events[1].value.frequency).to eq(110.0)
      expect(w).to be_looping
    end

    it 'remembers its source, so swaps rederive it' do
      bass = lead.within(s::E1..s::E2)
      expect(bass.source).to equal(lead)
      other = s.seq(s::A4, s::C5).n8
      expect(numbers(bass.rederive(other))).to eq([33, 36])
    end

    it 'keeps Seqs as Seqs, with chords and nested clips' do
      sq = s.seq([s::C4, s::E4, s::G4], s::A5, s.seq(s::B5, s::D6).n16).n4.within(s::C2..s::C3)
      expect(sq).to be_a(MB::Sound::Sequence::Seq)
      expect(numbers(sq)).to eq([48, 40, 43, 45, 47, 38])
    end

    it 'raises for drum names and pitch-marked hits' do
      drums = MB::Sound::Sequence::Clip.new([MB::Sound::Sequence::Event.new(start: 0r, length: 1/8r, value: :kick, velocity: 1.0)])
      expect { drums.within(s::E1..s::E2) }.to raise_error(ArgumentError, /no pitch/)
      expect(numbers(s.seq(s::E4.n8, 81).within(s::E1..s::E2))).to eq([40, 33]) # Notes and numbers alike
      expect { lead.within(s::E1) }.to raise_error(ArgumentError, /within\(E1\.\.E2\)/)
    end
  end

  describe 'generators' do
    it 'moves every generated cycle and keeps generating' do
      base = s.motifs(s.scale(:minor, :a), 8, seed: 5, range: s::A2..s::A5, evolve: 2)
      gen = base.within(s::C4..s::C5)
      expect(gen.variations.map { |v| v.block }).to all(be_a(MB::Sound::Generative::Producer))
      cycles = (0...12).map { |cy| gen.events_for(cy) }
      expect(cycles.uniq.length).to be > 1 # still varying cycle by cycle
      cycles.each_with_index do |events, cy|
        ref = base.events_for(cy)
        expect(events.map { |e| number(e.value) }).to all(be_between(60, 72))
        expect(events.map { |e| number(e.value) % 12 }).to eq(ref.map { |e| number(e.value) % 12 })
        expect(events.map(&:start)).to eq(ref.map(&:start))
      end
      expect(gen.to_ruby).to eq('motifs(scale(:minor, A4), 8, seed: 5, range: A2..A5, evolve: 2).within(C4..C5)')
    end
  end

  describe 'MIDI::Stream#within and Notes' do
    def run_stream
      list_stream(*[64, 79, 47, 28, 100].flat_map.with_index { |n, i| [ev.note_on(n, 0.5, time: i / 4r), ev.note_off(n, time: i / 4r + 1/8r)] })
    end

    it 'moves notes and their note-offs, read at once or in small live chunks' do
      out = read_all(run_stream.within(s::E1..s::E2))
      expect(ons(out).map { |e| e[1] }).to eq([40, 31, 35, 28, 40])
      expect(out.select { |e| e[0] == :note_off }.map { |e| e[1] }).to eq([40, 31, 35, 28, 40])
      expect_balanced(out)
      expect(read_all(run_stream.within(s::E1..s::E2), chunk: 1/32r)).to eq(out)
      expect(ons(read_all(run_stream.within(60.hz..120.hz))).map { |e| e[1] }).to eq([40, 43, 35, 40, 40])
    end

    it 'gives a clip baked through the stream transform the notes of Clip#within' do
      fx = MB::Sound::MIDI::Transform::Spec.new.within(s::E1...s::E2)
      expect(numbers(lead.bake(fx))).to eq(numbers(lead.within(s::E1...s::E2)))
    end

    it 'mirrors on Notes: a voice plays the moved note' do
      n = s.seq(s::A4).n2.loop.notes.within(s::E1..s::E2)
      expect(n).to be_a(MB::Sound::Notes)
      n.gate.sample(800)
      expect(n.number.sample(800)[-1]).to eq(33)
    end
  end
end
