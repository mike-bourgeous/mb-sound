require_relative '../../../../support/bar_stats_sounds'

# The grids bar statistics count on (BarStats::Grid): a constant grid from
# a tempo and the first downbeat, and a render's own grid
# (render(..., bar_stats: true), Grid::Recorder): beats on the frames the
# timeline crossed them through meter changes, tempo ramps, render
# windows, and the song form's section passes.
RSpec.describe(MB::Sound::BarStats::Grid, :aggregate_failures) do
  let(:s) { MB::Sound }

  describe '.constant' do
    it 'counts bars from the first downbeat, with a pickup in bar 0' do
      g = described_class.constant(bpm: 120, offset: 0.75, duration: 5.0)
      expect(g.beats.first(3).map { |b| [b.bar, b.beat, b.seconds] }).to eq([[0, 4, 0.25], [1, 1, 0.75], [1, 2, 1.25]])
      expect(g.bars.map(&:number)).to eq([1, 2, 3])
      expect(g.bars[1].seconds).to eq(2.75)
      expect(g.beat_spans.last).to eq([4.75, 5.0])
      expect(g.source).to eq(:given)
    end
  end

  describe 'BarStats.analyze\'s choice of grid (bar-stats-fix-1)' do
    let(:stem) { BarStatsSounds.kick_stem(silent: [3, 4], extra: 8) }

    it 'takes bpm: alone as a constant grid from 0 s, and says so' do
      r = s::BarStats.analyze(stem, bpm: 140.0001, sections: false)
      expect(r.grid.source).to eq(:given)
      expect(r.bars.length).to eq(8) # (8 samples past bar 8 make no bar 9)
      expect(r.grid.bars.first.seconds).to eq(0.0)
      expect(r.grid.bars[4].seconds).to be_within(1e-9).of(4 * 4 * 60 / 140.0001)
      expect(r.grid_text).to eq('constant 140.0001 BPM, bar 1 at 0.000 s (bpm: given)')
      expect(r.to_s).to include('Grid: constant 140.0001 BPM')
    end

    it 'tracks beats with grid: :track (bpm: then a hint) or without bpm:, and refuses offset: without bpm:' do
      r = s::BarStats.analyze(stem, bpm: 140, grid: :track, sections: false)
      expect(r.grid.source).to eq(:tracked)
      expect(r.grid_text).to start_with('tracked: ').and include('(bpm: 140.0 as a hint)')
      expect { s::BarStats.analyze(stem, offset: 0.5) }.to raise_error(ArgumentError, /pass bpm: with it/)
    end
  end

  describe 'Recorder (a render\'s grid)' do
    # Renders +bars+ of a click on every beat at +bpm+ with the block's
    # extra setup, returning [file, Report].
    def render_song(bars:, bpm: 140, **options, &block)
      path = tmp_path('song.flac')
      s.render(path, bars: bars, bpm: bpm, bar_stats: { sections: false }, **options) {
        block&.call
        s.bg :click, s.tr808(s.grid(kick: 'x...', closed_hat: '..x.').loop)
      }
      [path, s::BarStats.load(path)]
    end

    it 'puts every beat on the frame the timeline crossed it, through a meter change' do
      _, r = render_song(bars: 6) { s.meter 3, 4, at: s.bar(4) }
      g = r.grid
      expect(g.source).to eq(:render)
      expect(g.tempo).to be_within(1e-9).of(140)
      expect(g.beats.length).to eq(3 * 4 + 3 * 3)
      g.beats.each_with_index { |b, k| expect(b.seconds).to be_within(1e-6).of(k * 60.0 / 140) }
      expect(g.bars.map(&:beats)).to eq([4, 4, 4, 3, 3, 3])
      expect(g.bars.map(&:number)).to eq((1..6).to_a)
      expect(g.beats[12].bar).to eq(4)
      expect(g.beats[12].beat).to eq(1)
    end

    it 'follows a tempo ramp' do
      _, r = render_song(bars: 4, bpm: 120) { s.tempo 180, over: 2.bars, at: s.bar(2) }
      gaps = r.grid.beats.each_cons(2).map { |a, b| b.seconds - a.seconds }
      expect(gaps.first(4)).to all(be_within(1e-6).of(0.5))
      expect(gaps.last(3)).to all(be_within(1e-4).of(60.0 / 180))
      expect(gaps[4..11].each_cons(2).all? { |a, b| b <= a + 1e-9 }).to be(true)
      expect(r.grid.tempo).to be_nil
    end

    it 'starts a render window\'s grid at its first bar' do
      _, r = render_song(bars: 2, from: 3)
      expect(r.grid.bars.map(&:number)).to eq([3, 4])
      expect(r.grid.bars.first.seconds).to be_within(1.0 / 48000).of(0) # (the window starts on the frame holding it)
    end

    it 'takes the sections from the song form\'s passes' do
      path = tmp_path('form.flac')
      s.render(path, bars: 6, bpm: 240, bar_stats: true) {
        s.track(:pad) { |c| v = c.notes; v.hz.sine * v.amp_env(0.01, 0.1, 0.8, 0.05) * 0.2 }
        s.scene :verse, pad: s.seq(s::A3, s::C4).n2.loop
        s.scene :chorus, pad: s.seq(s::F3, s::G3).n2.loop
        s.flow do
          verse 2
          chorus 2
          verse 2
        end
      }
      r = s::BarStats.load(path)
      expect(r.grid.sections.map { |x| [x.label, x.first_bar, x.bars] }).to eq([['verse', 1, 2], ['chorus', 3, 2], ['verse 2', 5, 2]])
      expect(r.sections.keys).to eq(['verse', 'chorus', 'verse 2'])
      expect(r.grid.sections[1].seconds).to be_within(1e-6).of(2.0)
    end
  end
end
