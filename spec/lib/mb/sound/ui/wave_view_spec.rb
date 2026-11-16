require_relative '../../../../support/allocation_budget'

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
      pic = wv.picture(t, [2.0, Float::NAN, Float::NAN, 0.2], n, 40)
      data, lo, hi, title, mark = pic.data, pic.lo, pic.hi, pic.title, pic.mark
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

    it 'draws SVF and cookbook responses at the published cutoff, quality, and gain, on the chart preview\'s axis' do
      [
        [110.hz.saw.filter(:peak, cutoff: 800.constant, quality: 2.0, gain: 2.0), :svf, ->(c, q, g) { MB::Sound::Filter::SVF.new(:peak, 48000, c, quality: q, gain: g) }],
        [110.hz.saw.filter(:highpass, cutoff: 800.constant, quality: 0.7, structure: :biquad), :biquad, ->(c, q, _) { MB::Sound::Filter::Cookbook.new(:highpass, 48000, c, quality: q) }],
      ].each do |node, kind, make|
        node.sample(128)
        expect(wv.filter_kind(node)).to eq(kind)
        expect(wv.value_of(node, :cutoff)).to be_within(1e-3).of(800.0)
        d = described_class.new(node)
        expect(d.why).to be_nil
        c = d.curve(1500.0, 4.0, 3.0)
        _, db = MB::Sound::Plot::Presets.response_db(make.(1500.0, 4.0, 3.0), 48000)
        expect((c - Numo::SFloat.cast(db.clip(-60.0, nil))).abs.max).to be < 1e-3, kind.to_s
        expect(d.lo).to eq(-60.0)
        expect(d.hi).to eq(MB::Sound::Plot::Panels.db_range(MB::Sound::Plot::Panels.cookbook_top(node.preview_data), db).end.to_f)
      end
    end
  end

  describe MB::Sound::UI::WaveView::OutputTap do
    it 'copies a lane\'s first channel into its ring without allocating, and reads the newest samples back' do
      tap = described_class.new
      a = Numo::SFloat.new(800).seq
      b = Numo::SFloat.new(800).seq(10_000)
      tap.lane = 1
      tap.write([a, [b, a], nil])
      out = Numo::SFloat.zeros(100)
      expect(tap.read(out, 100)).to eq(700)
      expect(out.to_a).to eq(b[700..].to_a)
      expect(tap.read(out, described_class::SIZE)).to be_nil # (more than half the ring)
      tap.write([a, nil]) # (an ended lane: nothing)
      expect(tap.written).to eq(800)
      frozen = b.dup.freeze
      lanes = [a, frozen]
      m = AllocationBudget.measure(buffers: 200) { tap.write(lanes) }
      expect(m.objects_per_buffer).to be <= 0.1, m.report
      g = tap.generation
      tap.lane = 0
      expect(tap.generation).to eq(g + 1)
    end

    it 'leaves a Synth\'s samples as they were while it taps a lane' do
      make = -> { MB::Sound::Synth.new(MB::Sound.seq(MB::Sound::A2, MB::Sound::C3).n4.loop, voices: 2) { |v| v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.1) } }
      plain = make.call
      tapped = make.call
      tapped.output_tap = described_class.new
      a = Array.new(40) { plain.sample(367).dup }
      b = Array.new(40) { tapped.sample(367).dup }
      expect(b.map(&:to_a)).to eq(a.map(&:to_a))
      expect(tapped.output_tap.written).to eq(40 * 367)
    end
  end

  describe MB::Sound::UI::WaveView::VoiceView do
    it 'draws one period of a steady tapped sound that stands still from frame to frame' do
      tap = MB::Sound::UI::WaveView::OutputTap.new
      node = MB::Sound::Tone.new(wave_type: :ramp, frequency: 110)
      # (a sine: a band-limited edge's ripple falls on other samples each
      # period at a period of 436.36 samples, moving a dot or two there)
      src = MB::Sound::Tone.new(wave_type: :sine, frequency: 110.0).softclip(0.3, 0.9)
      view = described_class.new(node, tap, 0, [].freeze, 'frequency modulated')
      starts = []
      pics = []
      grid = MB::Sound::Plot::Text::NativeCells.new(40, 8)
      30.times do
        tap.write([src.sample(800)])
        c = view.cycle(110.0)
        next unless c
        starts << view.start
        MB::Sound::Plot::Wave.draw(grid, c, x: 0, y: 0, w: 40, h: 8, lo: -view.range, hi: view.range, fg: 0xffffff)
        pics << grid.lines(:none)
      end
      period = 48000 / 110.0
      expect(c = view.cycle(110.0).length).to eq(period.round)
      phases = starts.map { |x| (x % period) / period }
      expect(phases.each_cons(2).map { |p0, p1| [(p1 - p0).abs, 1 - (p1 - p0).abs].min }.max).to be < 1e-3
      # (after the first frames, once the range is set: at most a dot, where
      # a value lands within float rounding of a dot row's edge)
      changed = pics.last(20).each_cons(2).map { |a, b| a.join.each_char.zip(b.join.each_char).count { |x, y| x != y } }
      expect(changed.max).to be <= 1, changed.inspect
      peak = view.cycle(110.0).abs.max
      expect(view.range).to be_between(peak, peak * 2**0.25)
      m = AllocationBudget.measure(buffers: 200) { view.cycle(110.0) }
      expect(m.objects_per_buffer).to be <= 0.1, m.report
    end
  end

  describe 'watch_for' do
    after do
      MB::Sound::UI::Inspect.target = nil
      @session&.close
      MB::Sound.rewind
    end

    it 'picks a live response for an SVF row, and the tap publishes the cutoff its LFO moves' do
      out = MB::Sound::Sampler::CaptureOutput.new(channels: 2)
      @session = s = MB::Sound::Session.new(output: out, realtime: false)
      MB::Sound::Session.with_context(session: s) do
        MB::Sound.instance_eval do
          track(:sv) { |clip| synth(clip) { |v| v.hz.saw.filter(:lowpass, cutoff: 800 * 2**v.lfo(3, depth: 1), quality: 2.0) * v.amp_env(0.01, 0.3, 0.7, 0.3) } }
          bg :sv, seq(MB::Sound::A2).n2.loop
        end
      end
      s.ui_feed = MB::Sound::UI::Feed.new unless s.ui_feed
      wv.mode = :live
      g = MB::Sound::UI::Inspect::Gatherer.new
      8.times { s.process_buffer }
      info = g.call(s, { track: :sv })
      targets = info.nodes.each_index.map { |i| wv.watch_for(s, g, info.with(node: i)) }
      i = targets.index { |t| t&.kind == :svf }
      expect(i).not_to be_nil, info.nodes.map { |n| [n.label, n.what] }.inspect
      t = wv.watch_for(s, g, info.with(node: i))
      vals = Array.new(wv::Tap::MAX)
      seen = Array.new(30) { s.process_buffer; s.ui_feed.wave_tap.read(t.watch, vals) ? vals[0] : nil }.compact
      expect(seen.length).to be > 20
      expect(seen.min).to be_between(390.0, 1610.0)
      expect(seen.max - seen.min).to be > 10.0 # (the LFO moves it)
      expect(vals[1]).to be_within(1e-6).of(2.0)
      pic = wv.picture(t, vals, info.nodes[i], 40)
      expect(pic.title).to match(/ Hz Q 2.00 live\z/)
    end

    it 'shows an FM oscillator row through the voice\'s output tap, and takes the tap off the Synth when leaving it' do
      out = MB::Sound::Sampler::CaptureOutput.new(channels: 2)
      @session = s = MB::Sound::Session.new(output: out, realtime: false)
      MB::Sound::Session.with_context(session: s) do
        MB::Sound.instance_eval do
          track(:fm) { |clip| synth(clip, voices: 1) { |v| (v.freq + v.hz.transpose(12).sine.at(220)).tone.named('car') * v.amp_env(0.01, 0.2, 0.8, 0.3) } }
          bg :fm, seq(MB::Sound::A2).n1.loop
        end
      end
      s.ui_feed = MB::Sound::UI::Feed.new unless s.ui_feed
      wv.mode = :live
      g = MB::Sound::UI::Inspect::Gatherer.new
      8.times { s.process_buffer }
      info = g.call(s, { track: :fm })
      row = info.nodes.index { |n| n.label == 'car' }
      t = wv.watch_for(s, g, info.with(node: row))
      expect(t.kind).to eq(:voice)
      expect(t.view.reason).to eq('frequency modulated')
      synth = g.synth_of(info, 1)
      expect(synth.output_tap).to be_a(wv::OutputTap)
      vals = Array.new(wv::Tap::MAX)
      pic = nil
      12.times { s.process_buffer; s.ui_feed.wave_tap.read(t.watch, vals) && (pic = wv.picture(t, vals, info.nodes[row], 40)) }
      expect(pic.data.length).to eq((48000 / MB::Sound::A2.frequency).round)
      expect(pic.title).to eq("car frequency modulated: voice out #{MB::Sound::A2.frequency.round} Hz live")
      env = info.nodes.index { |n| n.what == 'amp env' }
      wv.watch_for(s, g, info.with(node: env))
      expect(synth.output_tap).to be_nil
      wv.watch_for(s, g, info.with(node: row))
      expect(synth.output_tap).not_to be_nil
      wv.mode = :off
      wv.watch_for(s, g, info.with(node: row))
      expect(synth.output_tap).to be_nil
    end

    it 'picks a live display for oscillator, filter, and LFO rows only, and the tap publishes what the voice used' do
      out = MB::Sound::Sampler::CaptureOutput.new(channels: 2)
      @session = s = MB::Sound::Session.new(output: out, realtime: false)
      MB::Sound::Session.with_context(session: s) do
        MB::Sound.instance_eval do
          track(:wob) { |clip|
            synth(clip, voices: 2) { |v|
              f = v.hz
              o1 = f.wavetable(:basic_norm, scan: v.lfo(0.3, unipolar: true)).named('osc1')
              o2 = f.transpose(-12).square.pwm(v.lfo(0.7, unipolar: true) * 0.8 + 0.1).named('osc2')
              (o1 + o2 * 0.5).lp4(1200 * 2 ** v.lfo(1.5, depth: 1.5), resonance: 0.4).softclip(0.5, 1.0) * v.amp_env(0.01, 0.3, 0.7, 0.3)
            }
          }
          bg :wob, seq(MB::Sound::A2).n2.loop
        end
      end
      s.ui_feed = MB::Sound::UI::Feed.new unless s.ui_feed
      wv.mode = :live
      g = MB::Sound::UI::Inspect::Gatherer.new
      8.times { s.process_buffer }
      info = g.call(s, { track: :wob })
      kinds = info.nodes.each_index.to_h { |i|
        t = wv.watch_for(s, g, info.with(node: i))
        [[info.nodes[i].label, info.nodes[i].what], t&.kind]
      }
      expect(kinds.select { |(l, _), _| %w[osc1 osc2].include?(l) }.values).to eq(%i[tone tone]), kinds.inspect
      expect(kinds.find { |(l, _), _| l == 'lp4' }&.last).to eq(:four_pole)
      # (the LFO rows, and the plumbing view's LFO oscillators themselves)
      expect(kinds.select { |(_, w), _| w.to_s.start_with?('lfo') }.values.uniq).to eq([:lfo]), kinds.inspect
      expect(kinds.reject { |(l, w), _| %w[osc1 osc2 lp4].include?(l) || w.to_s.start_with?('lfo') }.values.uniq).to eq([nil]), kinds.inspect

      osc2 = info.nodes.index { |n| n.label == 'osc2' }
      t = wv.watch_for(s, g, info.with(node: osc2))
      4.times { s.process_buffer }
      vals = Array.new(wv::Tap::MAX)
      expect(s.ui_feed.wave_tap.read(t.watch, vals)).to eq(true)
      expect(vals[0]).to be_within(0.5).of(MB::Sound::A1.frequency) # (the note an octave down)
      expect(vals[1]).to be_between(0.1, 0.9) # (the PWM LFO's width now)
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
