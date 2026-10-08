RSpec.describe('Note marks, Rest, Tie, and Seq#acid') do
  step_class = MB::Sound::Sequence::Seq::Step
  let(:a1) { MB::Sound::A1 }
  let(:c2) { MB::Sound::C2 }
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }

  # Renders +node+ in 800-sample buffers for +max+ samples
  def render(node, max)
    bufs = []
    total = 0
    while total < max && (b = node.sample(800))
      bufs << b.dup
      total += b.length
    end
    bufs.reduce { |a, b| a.concatenate(b) }[0...max]
  end

  describe 'accent' do
    it 'returns an accented Step from !, #accent, #acc, and #a!' do
      [!a1, a1.accent, a1.acc, a1.a!].each do |s|
        expect(s).to be_a(step_class)
        expect(s.value).to eq(33)
        expect(s.accented?).to eq(true)
        expect(s.velocity).to eq(MB::Sound::Sequence::Clip::ACCENT_VELOCITY)
      end
    end

    it 'leaves the note itself alone' do
      n = MB::Sound::A1
      !n
      expect(n).to be_a(MB::Sound::Note)
      expect(MB::Sound.seq(n).events[0].velocity).to eq(MB::Sound::Sequence::Clip::DEFAULT_VELOCITY)
    end

    it 'plays at the accent velocity in a plain seq' do
      e = MB::Sound.seq(a1, !a1).n16.events
      expect(e.map(&:velocity)).to eq([0.75, 1.0])
      expect(e.map(&:accented)).to eq([nil, true])
    end
  end

  describe 'slide' do
    it 'returns a slid Step from ~, #slide, and #s!' do
      [~a1, a1.slide, a1.s!].each do |s|
        expect(s).to be_a(step_class)
        expect(s.slid?).to eq(true)
      end
    end

    it 'makes the note overlap the next by 2% of its step' do
      e = MB::Sound.seq(~a1, c2).n16.events
      expect(e[0].length).to eq(1/16r * 51/50r)
      expect(e[0].end_time).to be > e[1].start
      expect(e[0].slid).to eq(true)
    end

    it 'takes an overlap' do
      e = MB::Sound.seq(a1.slide(1.25), c2).n4.events
      expect(e[0].length).to eq(5/16r)
    end

    it 'survives Seq#legato and Clip#legato' do
      s = MB::Sound.seq(~a1, c2, a1).n16
      expect(s.legato(0.5).events.map(&:length)).to eq([1/16r * 51/50r, 1/32r, 1/32r])
      clip = s | MB::Sound.seq(c2).n16
      expect(clip.legato(0.5).events.map(&:length)).to eq([1/16r * 51/50r, 1/32r, 1/32r, 1/32r])
    end

    it 'keeps a mono gate high and the pitch gliding across a slide' do
      clip = MB::Sound.seq(~a1, c2, a1, c2).n16.acid
      n = clip.notes(transport: transport)
      gate = render(n.gate, 24000)
      # 120 BPM: a sixteenth is 6000 samples; the slid A1 holds into C2,
      # while the C2 (gate 0.5) closes at 9000
      expect(gate[0...9000].to_a.uniq).to eq([1.0])
      expect(gate[9000...12000].to_a.uniq).to eq([0.0])
    end
  end

  describe 'chaining' do
    it 'combines marks in any order' do
      [~!a1, !(~a1), a1.!.~, a1.acc.s!, (~a1).acc].each do |s|
        expect([s.accented?, s.slid?, s.value]).to eq([true, true, 33])
      end
    end

    it 'gives Steps the length methods' do
      expect((!a1).n8).to be_a(MB::Sound::Sequence::Seq)
      expect(a1.acc.n8.events[0].length).to eq(1/8r)
      expect(a1.n8.acc.events[0].accented).to eq(true)
    end

    it 'explains !A1.n8' do
      expect { MB::Sound.seq(!a1.n8) }.to raise_error(ArgumentError, /\(!A1\)\.n8/)
    end
  end

  describe 'octave marks' do
    it 'move Notes and stay Notes' do
      expect(a1.up).to be_a(MB::Sound::Note)
      expect([a1.up.number, a1.dn.number, a1.down.number, a1.oct(2).number, a1.up(2).number]).to eq([45, 21, 21, 57, 57])
    end

    it 'move Pitches' do
      expect(440.hz.up.frequency).to be_within(1e-9).of(880)
      expect(440.hz.dn.frequency).to be_within(1e-9).of(220)
    end

    it 'move Steps and Seqs' do
      expect((!a1).up.value).to eq(45)
      expect((!a1).up.accented?).to eq(true)
      expect(MB::Sound.seq(a1, c2).up.events.map(&:value)).to eq([45, 48])
      expect(MB::Sound.seq(a1, c2).dn.events.map(&:value)).to eq([21, 24])
      expect(MB::Sound.seq(a1).oct(-1).events.map(&:value)).to eq([21])
    end
  end

  describe 'Rest and Tie' do
    it 'defines R and T' do
      expect(MB::Sound::R).to equal(MB::Sound::Rest)
      expect(MB::Sound::T).to equal(MB::Sound::Tie)
      expect(MB::Sound::Rest.rest?).to eq(true)
      expect(MB::Sound::Tie.rest?).to eq(false)
      expect(MB::Sound::Tie.tie?).to eq(true)
    end

    it 'rests like nil' do
      a = MB::Sound.seq(a1, MB::Sound::Rest, c2).n8
      b = MB::Sound.seq(a1, nil, c2).n8
      expect(a.events).to eq(b.events)
      expect(MB::Sound::Rest.n4.length).to eq(1/4r)
    end

    it 'holds the previous note one more step per Tie, resolving lengths later' do
      e = MB::Sound.seq(a1, MB::Sound::Tie, MB::Sound::Tie, c2).n16.events
      expect(e.map(&:start)).to eq([0, 3/16r])
      expect(e.map(&:length)).to eq([3/16r, 1/16r])
    end

    it 'applies legato to the last tied step only' do
      e = MB::Sound.seq(a1, MB::Sound::Tie, c2).n16.legato(0.5).events
      expect(e[0].length).to eq(1/16r + 1/32r)
    end

    it 'rests at the start and after a rest' do
      e = MB::Sound.seq(MB::Sound::Tie, a1, nil, MB::Sound::Tie, c2).n16.events
      expect(e.map(&:start)).to eq([1/16r, 4/16r])
      expect(e.map(&:length)).to eq([1/16r, 1/16r])
    end

    it 'keeps ties after their notes in reverse' do
      e = MB::Sound.seq(a1, MB::Sound::Tie, c2).n16.reverse.events
      expect(e.map(&:value)).to eq([36, 33])
      expect(e.map(&:start)).to eq([0, 1/16r])
      expect(e[1].length).to eq(1/8r)
    end

    it 'leaves ties in place in permute, with accents and slides moving with their notes' do
      e = MB::Sound.seq(!a1, MB::Sound::Tie, ~c2, a1).n16.permute([1, 2, 0]).events
      expect(e.map(&:value)).to eq([36, 33, 33])
      expect(e.map(&:accented)).to eq([nil, nil, true])
      expect(e[0].slid).to eq(true)
      expect(e[0].length).to eq(1/8r + 1/16r * 2/100r)
    end

    it 'parses - as a tie and X as an accent in grids' do
      e = MB::Sound.grid(16, 'x--X').events
      expect(e.map(&:length)).to eq([3/16r, 1/16r])
      expect(e.map(&:accented)).to eq([nil, true])
    end
  end

  describe 'Seq#acid' do
    let(:line) { MB::Sound.seq(a1, !a1, ~a1.up, a1, MB::Sound::R, c2, !a1, MB::Sound::T).n16 }

    it 'sets 303 gates, accents, and slides' do
      e = line.acid.events
      expect(e.map(&:velocity)).to eq([0.6, 1.0, 0.6, 0.6, 0.6, 1.0])
      expect(e.map(&:length)).to eq([1/32r, 1/32r, 1/16r * 51/50r, 1/32r, 1/32r, 1/16r + 1/32r])
      expect(e.map(&:value)).to eq([33, 33, 45, 33, 36, 33])
    end

    it 'takes other levels and gates' do
      e = line.acid(accent: 0.9, normal: 0.5, gate: 0.25, slide: 1.1).events
      expect(e.map(&:velocity).uniq).to eq([0.5, 0.9])
      expect(e[0].length).to eq(1/64r)
      expect(e[2].length).to eq(1/16r * 11/10r)
    end

    it 'converts nested Seqs' do
      e = MB::Sound.seq(a1, MB::Sound.seq(!c2, c2)).n16.acid.events
      expect(e.map(&:velocity)).to eq([0.6, 1.0, 0.6])
    end

    it 'is MB::Sound.acid with 16th-note steps by default' do
      expect(MB::Sound.acid(a1, !a1, ~a1.up).events).to eq(MB::Sound.seq(a1, !a1, ~a1.up).n16.acid.events)
      expect(MB::Sound.acid(a1, c2, step: 8).length).to eq(1/4r)
      expect(MB::Sound.acid(a1, c2, normal: 0.3).events.map(&:velocity)).to eq([0.3, 0.3])
    end

    it 'is rederived from a replacement clip (Session#swap)' do
      acid = line.acid(gate: 0.25)
      other = MB::Sound.seq(c2, ~c2.up).n16
      expect(acid.source).to equal(line)
      expect(acid.rederive(other).events).to eq(other.acid(gate: 0.25).events)
    end

    it 'rejects velocities outside 0..1' do
      expect { line.acid(accent: 2) }.to raise_error(ArgumentError, /0\.\.1/)
    end
  end
end
