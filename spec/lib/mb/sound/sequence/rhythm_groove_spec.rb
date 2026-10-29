require_relative '../../../../support/midi_writer'

# Rhythm templates (pitches poured into another clip's rhythm) and feel
# templates (timing and velocity against a grid), midi-import-1.
RSpec.describe('rhythm and groove templates') do
  let(:s) { MB::Sound }
  let(:bass) { s.seq(s::A1, !s::A1, ~s::C2, s::A1.n8, s::Rest, s::E2).n16.loop }

  describe MB::Sound::Sequence::Rhythm do
    it 'takes hits, lengths, velocities, accents, and slides from any clip, chords as one hit' do
      r = bass.rhythm
      expect(r.length).to eq(7/16r)
      expect(r).to be_looping
      expect(r.onsets).to eq([0r, 1/16r, 1/8r, 3/16r, 3/8r])
      expect(r.hits.map(&:accented)).to eq([false, true, false, false, false])
      expect(r.hits.map(&:slid)).to eq([false, false, true, false, false])
      expect(r.steps).to eq('xXxx-.x')
      chords = s.seq([s::C3, s::E3, s::G3], s::Rest, [s::D3, s::F3]).n8
      expect(chords.rhythm.count).to eq(2)
      expect(s.grid(16, 'x..X').rhythm.steps).to eq('x..X')
    end

    it 'pours pitches in, cycling, with chords, rests, and ties' do
      c = bass.rhythm.notes(s::C1, s::F1, [s::A1, s::E2], nil, s::G1)
      expect(c.events.map { |e| [e.start, e.value] }).to eq([[0r, 24], [1/16r, 29], [1/8r, 33], [1/8r, 40], [3/8r, 31]])
      expect(c.events.map(&:length)).to eq(bass.events.values_at(0, 1, 2, 2, 4).map(&:length))
      expect(c.events.map(&:velocity)).to eq([0.75, 1.0, 0.75, 0.75, 0.75])
      expect(c).to be_looping
      two = bass.rhythm.notes(40, s::Tie, 43)
      expect(two.events.map(&:value)).to eq([40, 40, 43, 40, 40])
      expect(bass.rhythm.notes(s.seq(50, 52)).events.map(&:value)).to eq([50, 52, 50, 52, 50])
      expect(bass.rhythm.to_clip(36).events.map(&:value).uniq).to eq([36])
      expect(bass.rhythm.notes(40, velocity: 0.5).events.map(&:velocity).uniq).to eq([0.5])
      expect { bass.rhythm.notes }.to raise_error(ArgumentError, /needs pitches/)
      expect { bass.rhythm.notes('C1') }.to raise_error(ArgumentError, /Notes, numbers/)
    end

    it 'pours scale degrees in (the session key by default)' do
      c = bass.rhythm.pitches(0, 2, [0, 2, 4], scale: s.scale(:minor, :a))
      expect(c.events.map(&:value)).to eq([69, 72, 69, 72, 76, 69, 72])
    end

    it 'works on imported clips and prints back as Ruby' do
      path = MidiWriter.reese_song(tmp_path('reese.mid'))
      r = s.midi_clip(path, track: 1, bars: 2).rhythm
      expect(r.hits.map(&:slid)).to eq([false, true, true, false])
      line = r.notes(s::C1, s::F1, s::A1, s::G1)
      expect(line.events.map(&:value)).to eq([24, 29, 33, 31])
      expect(line.to_ruby).to eq(%(midi_clip(#{path.inspect}, track: 1, bars: 2).rhythm.notes(C1, F1, A1, G1)))
      text = MB::Sound::Sequence::Rhythm.new(r.hits, length: r.length, loop: true).to_ruby
      expect(text).to start_with('rhythm_template([0r, 1r/2, ')
      expect(MB::Sound::GraphIO.load(text)).to eq(r)
    end
  end

  describe MB::Sound::Sequence::Groove do
    # A played 16th line: offbeats late by a 128th, downbeats a 512th
    # early, beats louder (a take with feel)
    let(:take) do
      rows = 16.times.map { |i| [(i * 1/16r + (i.odd? ? 1/128r : -1/512r)) % 1, 1/32r, 60, i % 4 == 0 ? 1.0 : 0.6] }
      s.events(*rows, length: 1r, loop: true)
    end

    it 'measures mean offsets and levels per grid step' do
      feel = take.groove
      expect(feel.steps).to eq(16)
      expect(feel.offsets.values_at(0, 1, 2)).to eq([-1/512r, 1/128r, -1/512r])
      expect(feel.levels[0]).to be_within(1e-9).of(1.0 / 0.7)
      expect(feel.levels[1]).to be_within(1e-9).of(0.6 / 0.7)
      expect(feel.to_s).to start_with('groove(n16, 16 steps: -3% 1.43, +13% 0.86')
      expect(take.groove(grid: 8).steps).to eq(8)
      expect(take.groove(grid: 8, triplets: true).grid).to eq(1/12r)
    end

    it 'moves other notes onto its positions and levels, amount of the way, sharing quantize' do
      feel = take.groove
      beat = s.grid(16, 'xxxx').loop
      full = beat.groove(feel)
      # (the early downbeat wraps to the end of the quarter-note loop, like quantize)
      expect(full.events.map(&:start)).to eq([1/16r + 1/128r, 1/8r - 1/512r, 3/16r + 1/128r, 1/4r - 1/512r])
      half = beat.groove(feel, amount: 0.5, velocity: 0)
      expect(half.events.map(&:start)).to eq([1/16r + 1/256r, 1/8r - 1/1024r, 3/16r + 1/256r, 1/4r - 1/1024r])
      expect(half.events.map(&:velocity).uniq).to eq([0.75])
      expect(beat.groove(feel, amount: 0).events.map(&:start)).to eq(beat.events.map(&:start))
      # The template can be a clip, measured on the grid
      expect(beat.groove(take).events.map(&:start)).to eq(full.events.map(&:start))
      expect(s.grid(16, kick: 'x...', hat: 'xxxx').loop.groove(feel)[:hat].events.length).to eq(4)
    end

    it 'measures loose live takes without hiding their timing' do
      rng = Random.new(5)
      rows = 16.times.map { |i| [i * 1/16r + Rational(rng.rand(-31..31), 64 * 16), 1/32r, 48, 0.7] }.map { |a, *r| [a % 1, *r] }
      feel = s.events(*rows, length: 1r, loop: true).groove
      expect(feel.offsets.map(&:abs).max).to be > 1/64r * 0.6
      expect(feel.offsets.all? { |o| o.abs <= 1/32r }).to be(true)
    end

    it 'delays stream notes onto its positions (streams only delay)' do
      feel = take.groove
      st = s.grid(16, 'xxxx').loop.stream(transport: MB::Sound::Sequence::Transport.new(bpm: 120)).groove(feel)
      ons = st.reader.next(1/2r).select(&:note_on?)
      # (offbeats a 128th = 1/64 s late; early downbeats can't move earlier)
      expect(ons.map(&:time)).to eq([0r, 1/8r + 1/64r, 1/4r, 3/8r + 1/64r])
      expect(ons.map { |e| e.velocity.round(3) }).to eq([1.0, 0.643, 0.643, 0.643])
    end

    it 'prints as the call that made it, or as groove_template' do
      feel = take.groove
      expect(s.grid(16, 'xxxx').loop.groove(feel).to_ruby).to include('.groove(events(')
      text = MB::Sound::Sequence::Groove.new(feel.grid, feel.offsets, feel.levels).to_ruby
      expect(text).to start_with('groove_template(16, offsets: [-1r/512, 1r/128,')
      expect(MB::Sound::GraphIO.load(text)).to eq(feel)
      expect { s.groove_template(16, offsets: [1/8r]) }.to raise_error(ArgumentError, /within half a step/)
    end
  end
end
