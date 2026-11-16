RSpec.describe(MB::Sound::UI::WaveView, :aggregate_failures) do
  let(:wv) { MB::Sound::UI::WaveView }

  after do
    wv.mode = :off
    wv.target = nil
    wv.feed = nil
  end

  describe 'value_of' do
    it 'reads the frequency, width, and scan a tone used last, planned or not' do
      [false, true].each do |planned|
        scan = 0.25.constant
        t = MB::Sound::Tone.new(wave_type: :sine, frequency: 220).wavetable(:basic_norm, scan: scan)
        g = planned ? MB::Sound::Plan.install(t) && t : t
        g.sample(128)
        expect(wv.value_of(t, :frequency)).to eq(220.0)
        expect(wv.value_of(t, :scan)).to be_within(1e-6).of(0.25)
        expect(wv.value_of(t, :width).nan?).to eq(true)
      end
      p = MB::Sound::Tone.new(wave_type: :square, frequency: 55).pwm(0.3.constant)
      p.sample(64)
      expect(wv.value_of(p, :width)).to be_within(1e-6).of(0.3)
    end

    it 'reads the cutoff a four-pole read last' do
      f = 110.hz.saw.lp4(1000.constant + 0.0 * 1.hz.lfo, resonance: 0.3)
      f.sample(256)
      expect(wv.value_of(f, :cutoff)).to be_within(1e-3).of(1000.0)
      expect(wv.value_of(f, :resonance)).to be_within(1e-9).of(0.3)
    end
  end

  describe MB::Sound::UI::WaveView::Tap do
    it 'publishes the watched values without allocating, and the painter reads the newest' do
      t = MB::Sound::Tone.new(wave_type: :square, frequency: 55).pwm(0.3.constant)
      t.sample(64)
      tap = described_class.new
      watch = [[t, :frequency].freeze, [t, :width].freeze].freeze
      tap.watch = watch
      3.times { tap.publish }
      before = GC.stat(:total_allocated_objects)
      1000.times { tap.publish }
      expect(GC.stat(:total_allocated_objects) - before).to be <= 1 # (one object once, not per publish: 100 or 1000 give 1)
      out = Array.new(described_class::MAX)
      expect(tap.read(watch, out)).to eq(true)
      expect(out[0]).to eq(55.0)
      expect(out[1]).to be_within(1e-6).of(0.3)
      expect(tap.read([[t, :frequency]].freeze, out)).to eq(false) # (another list: not this one's values)
    end

    it 'does nothing without a watch list' do
      tap = described_class.new
      tap.publish
      expect(tap.seq).to eq(0)
    end
  end

  describe MB::Sound::UI::WaveView::ToneDisplay do
    it 'draws one period from the oscillator\'s own kernel at the given width and scan' do
      src = MB::Sound::Tone.new(wave_type: :square, frequency: 110).pwm(0.5.constant)
      d = described_class.new(src)
      expect(d.why).to be_nil
      c = d.cycle(110.0, 0.2, Float::NAN)
      expect(c.length).to eq((48000 / 110.0).ceil)
      ref = MB::Sound::Tone.new(wave_type: :square, frequency: 110.0.constant).pwm(0.2.constant)
      expect(c.to_a).to eq(ref.sample(c.length).to_a) # (a fresh tone's first period)
      first = c.to_a
      expect(d.cycle(110.0, 0.2, Float::NAN)).to equal(c) # (kept while nothing changes)
      expect(d.cycle(110.0, 0.7, Float::NAN).to_a).not_to eq(first)
      # (each cycle starts from the same state: the same samples as a fresh tone, in any order)
      [[0.2, 110.0], [0.7, 220.0], [0.2, 110.0], [0.45, 55.0]].each do |w, f|
        ref = MB::Sound::Tone.new(wave_type: :square, frequency: f.constant).pwm(w.constant)
        got = d.cycle(f, w, Float::NAN).to_a
        expect(got).to eq(ref.sample(got.length).to_a), "width #{w} at #{f} Hz"
      end
    end

    it 'moves a wavetable through its frames by the scan' do
      src = MB::Sound::Tone.new(wave_type: :sine, frequency: 110).wavetable(:basic_norm, scan: 0.5.constant)
      d = described_class.new(src)
      a = d.cycle(110.0, Float::NAN, 0.0).dup
      b = d.cycle(110.0, Float::NAN, 1.0).dup
      expect((a - b).abs.max).to be > 0.3
    end

    it 'says why for shapes without a cheap cycle' do
      expect(described_class.new(MB::Sound::Tone.new(frequency: 110).noise).why).to eq('noise')
      m = 220.hz.sine
      expect(described_class.new(MB::Sound::Tone.new(frequency: 110.constant + m * 50)).why).to eq('frequency modulated')
      expect(described_class.new(MB::Sound::Tone.new(frequency: 110.constant + 2.hz.lfo * 5)).why).to be_nil # (vibrato)
    end
  end

  describe 'LFO displays' do
    it 'draws the LFO\'s shape with a marker at its phase now' do
      lfo = 2.hz.lfo.triangle
      lfo.sample(4800) # (a tenth of a second: a fifth of a cycle)
      expect(wv.value_of(lfo, :phase)).to be_within(1e-6).of(0.2)
      expect(wv.lfo_tone_of(lfo)).to equal(lfo)
      d = MB::Sound::UI::WaveView::ToneDisplay.new(lfo)
      expect(d.why).to be_nil
      t = MB::Sound::UI::WaveView::Target.new(label: 'lfo', kind: :lfo, watch: [].freeze, keys: wv::KEYS[:lfo], view: d)
      n = Struct.new(:label).new('lfo')
      data, lo, hi, title, mark = wv.picture(t, [2.0, Float::NAN, Float::NAN, 0.2], n, 40)
      expect(data.length).to eq(wv::LFO_POINTS)
      expect([lo, hi]).to eq([-1.0, 1.0])
      expect(mark).to eq(16) # (0.2 of 80 dot columns)
      expect(title).to eq('lfo 2 Hz live, now at 0.20')
      ref = 1.hz.lfo.triangle # (the same shape at any rate, within a third of a sample step: 0.0026)
      expect((data - ref.at_rate(wv::LFO_POINTS).sample(wv::LFO_POINTS)).abs.max).to be < 0.004
    end
  end

  describe MB::Sound::UI::WaveView::FilterDisplay do
    it 'draws the closed-form response at the given cutoff and resonance' do
      f = 110.hz.saw.lp4(1200.constant + 0.0 * 1.hz.lfo, resonance: 0.4)
      f.sample(128)
      d = described_class.new(f)
      c = d.curve(2000.0, 0.6)
      ref = MB::Sound::Filter::FourPole.new(cutoff: 2000.0, resonance: 0.6, sample_rate: 48000)
      _, db = MB::Sound::Plot::Presets.response_db(ref, 48000)
      expect((c - Numo::SFloat.cast(db.clip(-60.0, nil))).abs.max).to be < 1e-4
      expect(d.curve(2000.0, 0.6)).to equal(c)
    end
  end

  describe 'the preview pane' do
    it 'draws the live cycle from the tap every frame while live, and today\'s preview while off' do
      tone = MB::Sound::Tone.new(wave_type: :square, frequency: 110).pwm(0.3.constant)
      tone.sample(64)
      feed = MB::Sound::UI::Feed.new
      tap = feed.wave_tap = MB::Sound::UI::WaveView::Tap.new
      watch = %i[frequency width scan].map { |k| [tone, k].freeze }.freeze
      tap.watch = watch
      tap.publish
      wv.feed = feed
      wv.mode = :live
      node = MB::Sound::UI::Inspect::NodeInfo.new(key: 0, label: 'osc1', role: :osc, count: 1, params: tone.param_snapshot, preview: nil, knobs: [].freeze)
      info = MB::Sound::UI::Inspect::InspectInfo.new(track: :t, tracks: [:t].freeze, knobs: [].freeze, nodes: [node].freeze, node: 0, code: nil, error: nil)
      snap = MB::Sound::UI::Snapshot.fake.then { |s| s.with(slow: s.slow.with(inspector: info)) }
      wv.target = MB::Sound::UI::WaveView::Target.new(label: 'osc1', kind: :tone, watch: watch, keys: %i[frequency width scan], view: MB::Sound::UI::WaveView::ToneDisplay.new(tone))
      pane = MB::Sound::UI::Panes::Preview.new
      grid = MB::Sound::Plot::Text::NativeCells.new(40, 8)
      canvas = MB::Sound::UI::Canvas.new(grid, 0, 0, 40, 8)
      state = {}
      pane.draw(canvas, snap, state)
      text = grid.to_text(:none)
      expect(text.lines.first).to include('osc1 110 Hz live pw 0.30')
      expect(text).to match(/[⠁-⣿]/)
      expect(pane.priority).to eq(:live)
    end

    it 'draws an envelope\'s trace with the playhead as its marker while live' do
      env = MB::Sound::Envelope.new(attack: 0.01, decay: 0.3, sustain: 0.6, release: 0.4, sample_rate: 48000)
      params = env.param_snapshot
      draw = lambda do |live|
        node = MB::Sound::UI::Inspect::NodeInfo.new(key: 0, label: 'amp env', role: :env, count: 1, params: params, preview: nil, knobs: [].freeze, live: live)
        info = MB::Sound::UI::Inspect::InspectInfo.new(track: :t, tracks: [:t].freeze, knobs: [].freeze, nodes: [node].freeze, node: 0, code: nil, error: nil)
        snap = MB::Sound::UI::Snapshot.fake.then { |s| s.with(slow: s.slow.with(inspector: info)) }
        pane = MB::Sound::UI::Panes::Preview.new
        grid = MB::Sound::Plot::Text::NativeCells.new(40, 8)
        pane.draw(MB::Sound::UI::Canvas.new(grid, 0, 0, 40, 8), snap, {})
        [grid, pane]
      end
      wv.mode = :live
      quiet, pane = draw.(nil)
      expect(quiet.to_text(:none).lines.first).to include('live')
      expect(pane.priority).to eq(:list) # (no note: nothing moves)
      held, pane = draw.({ stage: :segment, segment: 1, position: 0.1, peak: 1.0, at: MB::Sound::UI::Panes::Preview.now }.freeze)
      expect(held.lines(:truecolor)).not_to eq(quiet.lines(:truecolor)) # (the marker)
      expect(pane.priority).to eq(:live)
      wv.mode = :off
      off, = draw.(nil)
      expect(off.to_text(:none)).not_to include(' live')
    end
  end
end
