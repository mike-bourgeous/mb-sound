RSpec.describe('MIDI feel transforms', :midi_transforms) do
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }

  # Eight notes, a quarter second apart, an eighth second long.
  def run_stream
    list_stream(*8.times.flat_map { |i| [ev.note_on(60 + i, 0.5, time: i / 4r), ev.note_off(60 + i, time: i / 4r + 1/8r)] })
  end

  describe 'Stream#humanize' do
    it 'only delays notes, by up to the time, keeping their lengths' do
      out = read_events(run_stream.humanize(0.02, seed: 4))
      expect_balanced(out)
      ons = out.select(&:note_on?)
      ons.each_with_index do |e, i|
        expect(e.time - i / 4r).to be_between(0, 0.02)
        off = out.find { |o| o.note_off? && o.note == e.note }
        expect(off.time - e.time).to eq(1/8r)
      end
      expect(ons.map { |e| e.time - ons.index(e) / 4r }.uniq.length).to eq(8)
    end

    it 'repeats from its seed, whatever the read size' do
      a = read_all(run_stream.humanize(0.02, velocity: 0.2, seed: 4))
      b = read_all(run_stream.humanize(0.02, velocity: 0.2, seed: 4), seconds: 3, chunk: 128/48000r)
      c = read_all(run_stream.humanize(0.02, velocity: 0.2, seed: 5))
      expect(b).to eq(a)
      expect(c).not_to eq(a)
    end

    it 'draws its seed from MB::Sound by default' do
      MB::Sound.seed(9)
      a = read_all(run_stream.humanize(0.02))
      MB::Sound.seed(9)
      b = read_all(run_stream.humanize(0.02))
      expect(b).to eq(a)
    end

    it 'changes velocities by up to the given fraction' do
      vels = ons(read_all(run_stream.humanize(0, velocity: 0.2, seed: 1))).map(&:last)
      expect(vels).to all(be_between(0.4, 0.6))
      expect(vels.uniq.length).to be > 4
    end
  end

  describe 'Stream#quantize' do
    it 'moves notes later to the next grid step of the timeline, keeping lengths' do
      s = list_stream(ev.note_on(60, time: 1/100r), ev.note_off(60, time: 1/10r), ev.note_on(62, time: 1/8r), ev.note_off(62, time: 2/10r))
      out = read_all(s.quantize(16, transport: transport))
      expect(out.map { |e| e.first(3) }).to eq([[:note_on, 60, 1/8r], [:note_on, 62, 1/8r], [:note_off, 62, 2/10r], [:note_off, 60, 1/8r + 9/100r]])
    end

    it 'moves notes part of the way with amount:, and leaves notes outside the window' do
      s = -> { list_stream(ev.note_on(60, time: 1/40r), ev.note_off(60, time: 1/10r)) }
      expect(ons(read_all(s.().quantize(16, amount: 0.5, transport: transport))).map { |e| e[2] }).to eq([3/40r])
      expect(ons(read_all(s.().quantize(16, window: 1.n64, transport: transport))).map { |e| e[2] }).to eq([1/40r])
      expect(ons(read_all(s.().quantize(16, window: 1.n16, transport: transport))).map { |e| e[2] }).to eq([1/8r])
    end

    it 'follows the session timeline (a graph started off the grid)' do
      s = list_stream(ev.note_on(60, time: 0r), ev.note_off(60, time: 1/10r))
      q = s.quantize(4, transport: transport)
      q.source.start_at(1/16r) # the stream starts a 16th into the timeline
      out = read_all(q)
      expect(ons(out).map { |e| e[2] }).to eq([(1/4r - 1/16r) * 2]) # 3/16 whole notes at 120 BPM
    end
  end

  describe 'Stream#strum' do
    def chord_stream(time = 0r, off = 1r)
      list_stream(*[64, 60, 67].flat_map { |n| [ev.note_on(n, 0.8, time: time), ev.note_off(n, time: off)] })
    end

    it 'spreads notes that start together, low to high by default, keeping lengths' do
      out = read_all(chord_stream.strum(0.04))
      expect(out.map { |e| e.first(3) }).to eq([
        [:note_on, 60, 0r], [:note_on, 64, 1/50r], [:note_on, 67, 1/25r],
        [:note_off, 60, 1r], [:note_off, 64, 1r + 1/50r], [:note_off, 67, 1r + 1/25r],
      ])
    end

    it 'strums up, alternates, follows the played order, or shuffles from a seed' do
      expect(ons(read_all(chord_stream.strum(0.04, :up))).map { |e| e[1] }).to eq([67, 64, 60])
      expect(ons(read_all(chord_stream.strum(0.04, :played))).map { |e| e[1] }).to eq([64, 60, 67])

      two = list_stream(*[0r, 1/2r].flat_map { |t| [60, 64].flat_map { |n| [ev.note_on(n, time: t), ev.note_off(n, time: t + 1/4r)] } })
      expect(ons(read_all(two.strum(0.02, :alternate))).map { |e| e[1] }).to eq([60, 64, 64, 60])

      a = ons(read_all(chord_stream.strum(0.04, :random, seed: 2)))
      b = ons(read_all(chord_stream.strum(0.04, :random, seed: 2)))
      expect(a).to eq(b)
    end

    it 'groups notes within a window, delaying them by it' do
      s = list_stream(ev.note_on(60, time: 0r), ev.note_on(64, time: 1/100r), ev.note_off(60, time: 1/2r), ev.note_off(64, time: 1/2r))
      out = read_all(s.strum(0.02, window: 0.02))
      expect(out.map { |e| e.first(3) }).to eq([
        [:note_on, 60, 1/50r], [:note_on, 64, 1/25r], [:note_off, 60, 1/2r + 1/50r], [:note_off, 64, 1/2r + 3/100r],
      ])
    end

    it 'keeps short notes whose note-offs come inside the window' do
      s = list_stream(ev.note_on(60, time: 0r), ev.note_off(60, time: 1/200r), ev.note_on(64, time: 1/100r), ev.note_off(64, time: 1/2r))
      out = read_all(s.strum(0.02, window: 0.02), chunk: 1/1000r, seconds: 1)
      expect_balanced(out)
      expect(out.first(2).map { |e| e.first(3) }).to eq([[:note_on, 60, 1/50r], [:note_off, 60, 1/50r + 1/200r]])
    end

    it 'scales later notes with velocity:' do
      expect(ons(read_all(chord_stream.strum(0.04, velocity: 0.5))).map(&:last)).to eq([0.8, 0.4, 0.2])
    end

    it 'gives readers of any size the same events' do
      expect(read_all(chord_stream.strum(0.04), seconds: 2, chunk: 128/48000r)).to eq(read_all(chord_stream.strum(0.04)))
    end
  end
end
