# Structure analysis, phase S1: tempo, beats, bars, and meter
# (MB::Sound::Structure, MB::Sound.analyze_form), on short grooves rendered
# here from the library, with known tempos and bar lines.
RSpec.describe(MB::Sound::Structure, :aggregate_failures) do

  # A one-bar 808 groove with a bass line whose note changes every bar (the
  # downbeat cue), restarting its pattern when launched.
  def self.groove(kick: 'X.......X.......', bass: true)
    roots = MB::Sound.seq(MB::Sound::E1, MB::Sound::G1, MB::Sound::A1, MB::Sound::D1).n1.loop(align: :launch)
    drums = MB::Sound.tr808(
      MB::Sound.grid(16, kick: kick, clap: '....X.......X...', hat: 'x.x.x.x.x.x.x.x.').loop(align: :launch),
      kick: { tune: roots.freq, decay: 1.5 }
    )
    bass ? drums + bass_line : drums
  end

  # A saw bass changing notes every bar.
  def self.bass_line
    b = MB::Sound.seq(MB::Sound::E2, MB::Sound::G2, MB::Sound::A2, MB::Sound::D2).n1.loop(align: :launch).notes
    b.hz.ramp * b.amp_env(0.005, 0.4, 0.5, 0.1) * 0.25
  end

  # Plays the groove with a 2/4 bar of claps at bar +gap+ (the night bus's
  # gap bar, in miniature), relaunching the groove after it.
  def self.gap_song(gap)
    MB::Sound.meter 2, 4, at: MB::Sound.bar(gap)
    MB::Sound.meter 4, 4, at: MB::Sound.bar(gap + 1)
    MB::Sound.bg :drums, groove
    MB::Sound.at_bar(gap) do
      MB::Sound.stop :drums, fade: 0
      MB::Sound.bg :gap, MB::Sound.tr808(MB::Sound.grid(16, clap: 'X.X.XXXX').loop(align: :launch)), fade: 0
    end
    MB::Sound.at_bar(gap + 1) do
      MB::Sound.stop :gap, fade: 0
      MB::Sound.bg :drums, groove, fade: 0
    end
  end

  # Expected downbeat times for +bars+ bars at +bpm+ with a 2/4 bar at +gap+.
  def downbeat_times(bpm, bars, gap)
    t = 0.0
    (1..bars).map { |b| s = t; t += (b == gap ? 2 : 4) * 60.0 / bpm; s }
  end

  # Renders shared by several examples (seeded, since spec_helper's seed
  # reset runs per example).
  before(:all) do
    MB::Sound.seed(1)
    @gap_tracked = MB::Sound.analyze_form(bars: 8, bpm: 120, grid: false) { self.class.gap_song(5) }
    MB::Sound.seed(1)
    @gap_render = MB::Sound.analyze_form(bars: 6, bpm: 120) { self.class.gap_song(3) }
  end

  describe 'on our own renders (the render grid)' do
    it 'takes the beats, bars, and meter map from the render exactly' do
      r = @gap_render
      expect(r.tracker).to eq(:transport)
      expect(r.tempo).to eq(120)
      expect(r.bars.first(6).map(&:number)).to eq([1, 2, 3, 4, 5, 6])
      expect(r.bars.first(6).map(&:seconds)).to eq([0.0, 2.0, 4.0, 5.0, 7.0, 9.0])
      expect(r.bars.first(6).map(&:beats)).to eq([4, 4, 2, 4, 4, 4])
      expect(r.irregular_bars.map(&:number)).to eq([3])
      expect(r.meters.map { |m| [m.pos, m.bar_length, m.bar] }).to eq([[0r, 1r, 1], [2r, 1/2r, 3], [5/2r, 1r, 4]])
      expect(r.beats.first(10).map(&:to_s)).to eq(%w[1:1 1:2 1:3 1:4 2:1 2:2 2:3 2:4 3:1 3:2])
      expect(r.beats[10].to_s).to eq('4:1')
      expect(r.beats[10].seconds).to eq(5.0)
      expect(r.meters_ruby).to eq("meter 2, 4, at: bar(3)\nmeter 4, 4, at: bar(4)")
    end

    it 'renders a graph for its bars at the given tempo' do
      r = MB::Sound.analyze_form(self.class.groove, bars: 2, bpm: 96)
      expect(r.tempo).to eq(96)
      expect(r.bars.first(2).map(&:seconds)).to eq([0.0, 2.5])
      expect(r.beats.first(3).map(&:seconds)).to eq([0.0, 0.625, 1.25])
    end

    it 'accepts a Transport or a Session as grid: for audio data, with start: for where its timeline begins' do
      # Clicks on every beat at 120 BPM from 0.5 s
      t = MB::Sound::Sequence::Transport.new(bpm: 120)
      clicks = Numo::SFloat.zeros(48000 * 6)
      10.times { |k| clicks[(24000 + k * 24000)...(24000 + k * 24000 + 200)] = 1 }
      r = MB::Sound::Structure.analyze(clicks, grid: t, start: 0.5)
      expect(r.tracker).to eq(:transport)
      expect(r.beats.first.seconds).to eq(0.5)
      expect(r.bars.map(&:seconds)).to eq([0.5, 2.5, 4.5])

      session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: t, realtime: false)
      r2 = MB::Sound::Structure.analyze(clicks, grid: session, start: 0.5)
      expect(r2.bars.map(&:seconds)).to eq([0.5, 2.5, 4.5])
    ensure
      session&.close
    end
  end

  describe 'tracking (grid: false, files, data)' do
    it 'finds the tempo, the beats, and a 2/4 bar in a groove' do
      r = @gap_tracked
      expected = downbeat_times(120, 9, 5)
      expect(r.tracker).to eq(:grid)
      expect(r.tempo).to be_within(0.01).of(120)
      expect(r.irregular_bars.map(&:number)).to eq([5])
      expect(r.bars.length).to be >= 8
      r.bars.first(9).zip(expected).each do |bar, t|
        expect(bar.seconds).to be_within(0.015).of(t)
      end
      r.beats.each do |b|
        expect(b.seconds % 0.5).to be_within(0.015).of(0).or be_within(0.015).of(0.5)
      end
      expect(r.meters.map { |m| [m.bar_length, m.bar] }).to eq([[1r, 1], [1/2r, 5], [1r, 6]])
      expect(r.transport.bar_position(6)).to eq(9/2r)
    end

    it 'puts tracked beats within 6 ms of the true beats (ONSET_LATENCY)' do
      offsets = @gap_tracked.beats.map { |b| b.seconds - (b.seconds / 0.5).round * 0.5 }
      expect(offsets.map(&:abs).max).to be < 0.006
    end

    it 'converts between seconds and bar positions' do
      r = @gap_tracked
      expect(r.bar_at(r.bars[2].seconds)).to eq(3)
      expect(r.seconds_at(3.5)).to be_within(1e-9).of((r.bars[2].seconds + r.bars[2].end_seconds) / 2)
      expect(r.bar_at(r.seconds_at(6.25))).to be_within(1e-9).of(6.25)
      expect(r.downbeats).to eq(r.bars.map(&:seconds))
      expect(r.to_s).to match(/120\.0\d BPM, \d+ bars of 4\/4 \(bar 5: 2\/4\)/)
    end

    it 'uses a bpm: hint instead of estimating the tempo' do
      MB::Sound.seed(5)
      MB::Sound.render(capture = MB::Sound::Structure::Capture.new, self.class.groove, bars: 3, bpm: 100)
      data = capture.data
      expect(MB::Sound.analyze_form(data).tempo_estimate).to be_within(0.5).of(100)

      r = MB::Sound.analyze_form(data, bpm: 100, refine: false)
      expect(r.tempo_estimate).to be_nil
      expect(r.tempo).to eq(100)
      expect(r.beats.length).to be >= 11
      expect(r.beats.each_cons(2).map { |a, b| b.seconds - a.seconds }).to all(be_within(1e-9).of(0.6))
      expect(r.downbeats.first).to be_within(0.01).of(0)

      expect(MB::Sound.analyze_form(data, bpm: 99.8).tempo).to be_within(0.05).of(100) # 12 beats: about 2 ms of drift over the 7 s
    end

    it 'reads files, and data at other sample rates' do
      MB::Sound.seed(2)
      MB::Sound.render(capture = MB::Sound::Structure::Capture.new, self.class.groove, bars: 4, bpm: 112)
      data = capture.data
      path = tmp_path('groove.flac')
      MB::Sound.write(path, data)
      r = MB::Sound.analyze_form(path)
      expect(r.tempo).to be_within(0.02).of(112)

      half = data.map { |c| Numo::SFloat.cast(c[(0..-1) % 2]) } # 24 kHz by decimation (aliased, but onsets survive)
      r2 = MB::Sound.analyze_form(half, sample_rate: 24000)
      expect(r2.tempo).to be_within(0.05).of(112)
      expect(r2.downbeats.first(2)).to all(be < 2.2)
    end

    it 'tracks swung and half-time grooves' do
      MB::Sound.seed(3)
      swung = MB::Sound.tr808(MB::Sound.grid(12, kick: 'X.....X.....', clap: '...X.....X..', hat: 'x.xx.xx.xx.x').loop) + self.class.bass_line
      r = MB::Sound.analyze_form(swung, bars: 6, bpm: 96, grid: false)
      expect(r.tempo).to be_within(0.02).of(96)
      r.downbeats.each { |t| expect((t / 2.5 - (t / 2.5).round).abs * 2.5).to be < 0.01 }

      # Half time (kick on 1 and the and of 3, clap on 3): the tempo and
      # beats are right; the downbeats land a beat early (a known limit,
      # the drums' timbre outweighs the bass; see design/notes/structure.md)
      half = MB::Sound.tr808(MB::Sound.grid(16, kick: 'X.........X.....', clap: '........X.......', hat: 'x.x.x.x.x.x.x.x.').loop)
      r = MB::Sound.analyze_form(half, bars: 6, bpm: 140, grid: false)
      expect(r.tempo).to be_within(0.02).of(140)
      r.beats.each { |b| expect((b.seconds * 140 / 60.0 - (b.seconds * 140 / 60.0).round).abs).to be < 0.02 }
    end

    it 'can track with the dynamic programming tracker (beats: :dp)' do
      r = MB::Sound.analyze_form(self.class.groove, bars: 6, bpm: 120, grid: false, beats: :dp)
      expect(r.tracker).to eq(:dp)
      expect(r.tempo).to be_within(0.2).of(120)
      r.beats.each { |b| expect((b.seconds / 0.5 - (b.seconds / 0.5).round).abs * 0.5).to be < 0.025 }
    end

    it 'puts the grid half a beat late on drums_808 (a known limit: syncopated kick, accented offbeat hats)' do
      MB::Sound.seed(4)
      roots = MB::Sound.seq(MB::Sound::E1, MB::Sound::E1, MB::Sound::G1, MB::Sound::D1).n1.loop
      kit = MB::Sound.tr808(
        MB::Sound.grid(16, kick: 'X.....x...X..x..', clap: '....X.......X..x', hat: 'x.xXx.x.x.xXx.xx', open_hat: '......x.......x.').loop,
        kick: { tune: roots.freq, decay: 1.8, tone: 0.4 }, clap: { level: 0.5 }
      )
      r = MB::Sound.analyze_form(kit, bars: 6, bpm: 112, grid: false)
      expect(r.tempo).to be_within(0.02).of(112)
      beat = 60.0 / 112
      phase = r.beats.map { |b| (b.seconds / beat) % 1 }.sort[r.beats.length / 2]
      # S3's backbeat model should bring this to 0; until then the grid
      # sits on the offbeats
      expect(phase).to be_within(0.05).of(0.5)
    end
  end

  describe 'errors' do
    it 'refuses bad options and inputs' do
      expect { MB::Sound::Structure.analyze(Numo::SFloat.zeros(4800), beats: :fancy) }.to raise_error(ArgumentError, /beats:/)
      expect { MB::Sound::Structure.analyze(Numo::SFloat.zeros(4800), grid: 120) }.to raise_error(ArgumentError, /grid:/)
      expect { MB::Sound::Structure.analyze(Numo::SFloat[]) }.to raise_error(ArgumentError, /empty/)
      expect { MB::Sound.analyze_form(123.hz) }.to raise_error(ArgumentError, /bars: or seconds:/)
      expect { MB::Sound.analyze_form('x.flac', bars: 2) }.to raise_error(ArgumentError, /rendering graphs/)
    end
  end
end
