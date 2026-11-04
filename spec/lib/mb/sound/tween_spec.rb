RSpec.describe('Tweens (MB::Sound.tween, Clip#tween, smooth(curve:))') do
  # +seconds+ of +node+ as a DFloat, in buffers of 480.
  def take(node, seconds)
    SpecBuffers.join((seconds * 100).round.times.map { node.sample(480).dup }).cast_to(Numo::DFloat)
  end

  # Launches a tween in a Session (on: :now) after at least +pre+ frames
  # (whole buffers), returning the output from frame 0.
  def launched_tween(tween, pre:, buffer_size:, bars: 4)
    session = MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1, buffer_size: buffer_size, realtime: false, raise_errors: true)
    out = []
    MB::Sound::Session.with_context(session: session) {
      MB::Sound.bg(:z, 0.constant)
      out << session.process_buffer[0].dup while out.sum(&:length) < pre
      MB::Sound.bg(:t, tween, on: :now)
      out << session.process_buffer[0].dup while out.sum(&:length) < pre + bars * 96000
    }
    session.close
    SpecBuffers.join(out).cast_to(Numo::DFloat)
  end

  before { MB::Sound.bpm(120) }

  describe 'MB::Sound.tween' do
    it 'tweens from its first keyframe when its graph launches in a Session (not from the end)' do
      # A Session launch is a content jump onto the first keyframe's note;
      # the glide used to take it as a chased note and jump to its target
      # (2026-10-11: night_bus_flow's riser was a constant hiss)
      session = MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1, buffer_size: 800, realtime: false, raise_errors: true)
      out = []
      MB::Sound::Session.with_context(session: session) {
        MB::Sound.bg(:z, 0.constant)
        30.times { out << session.process_buffer[0].dup } # launch later than the timeline's start
        MB::Sound.bg(:t, MB::Sound.tween([0.0, 1.0], 1.bar, loop: false), on: :now)
        150.times { out << session.process_buffer[0].dup }
      }
      session.close
      data = SpecBuffers.join(out)[24000..]
      expect(data[0]).to be < 0.001
      expect(data[24000]).to be_within(0.01).of(0.156) # smoothstep at 1/4 of the bar
      expect(data[48000]).to be_within(0.01).of(0.5)
      expect(data[96000]).to be_within(1e-6).of(1)
    end

    [800, 367, 128].each do |bs|
      it "follows the timeline when a looping tween launches partway through it (#{bs}-frame buffers)" do
        # Mid-timeline launches used to hold the first keyframe for the
        # launch bar (arrange-3, 2026-10-11): the chase at the second
        # step glided from the first keyframe into it
        out = launched_tween(MB::Sound.tween([200.0, 1000.0], 1.bar, curve: :linear), pre: 0, buffer_size: bs, bars: 1)
        expect(out[48000]).to be_within(0.1).of(600)

        # Launched on bar 2 (the loop's second step): 1000 -> 200
        out = launched_tween(MB::Sound.tween([200.0, 1000.0], 1.bar, curve: :linear), pre: 96001, buffer_size: bs, bars: 3)
        start = out.to_a.index { |v| v != 0 }
        expect(start).to be > 96000
        expect(start).to be <= 96000 + bs
        # Partway into bar 2 at its own position on the timeline
        frac = (start - 96000 + 1) / 96000.0
        expect(out[start]).to be_within(0.1).of(1000 - 800 * frac)
        expect(out[144000]).to be_within(0.1).of(600) # mid bar 2: halfway down
        expect(out[192000]).to be_within(0.1).of(200) # bar 3: the first keyframe
        expect(out[240000]).to be_within(0.1).of(600) # and up again
      end
    end

    it 'starts at its first keyframe wherever it launches with align: :launch' do
      out = launched_tween(MB::Sound.tween([200.0, 1000.0], 1.bar, curve: :linear, align: :launch), pre: 100000, buffer_size: 800, bars: 2)
      start = out.to_a.index { |v| v != 0 }
      expect(out[start]).to be_within(0.1).of(200)
      expect(out[start + 47999]).to be_within(0.1).of(600)
      expect(out[start + 95999]).to be_within(0.1).of(1000)
    end

    it 'resumes a step partway when launched mid-step (Elastic curve, uneven steps)' do
      tw = -> { MB::Sound.tween([0.0, 1.0, 0.5], [1.bar, 2.beats, 2.beats], curve: :elastic) }
      ref = take(tw.call, 8) # 2 cycles from the timeline start
      [800, 128].each do |bs|
        out = launched_tween(tw.call, pre: 120000, buffer_size: bs, bars: 2)
        start = out.to_a.index { |v| v != 0 }
        expect(start).to be_within(bs).of(120000)
        expect((out[start...(start + 96000)] - ref[start...(start + 96000)]).abs.max).to be < 1e-4
      end
    end

    it 'treats values as keyframes: each value at its step start, tweening to the next' do
      out = take(MB::Sound.tween([0, 1, 0.3], 1.bar, curve: :elastic, loop: false), 8) # a bar is 2 s
      c = MB::Sound::Curve[:elastic]
      t = (Numo::DFloat.new(96000).seq + 1) / 96000.0
      expect(out[0]).to be_within(1e-6).of(c.lookup(Numo::DFloat[1 / 96000.0])[0])
      expect((out[0...96000] - c.lookup(t.dup)).abs.max).to be < 1e-6 # 0 -> 1 during bar 1
      expect(out[0...96000].max).to be > 1.2
      expect(out[96000]).to be_within(1e-6).of(1 + (0.3 - 1) * c.lookup(Numo::DFloat[1 / 96000.0])[0]) # 1 -> 0.3 during bar 2
      expect(out[192000..].to_a.uniq).to eq([0.30000001192092896]) # holds the last value
    end

    it 'loops back to the first value over the last step' do
      out = take(MB::Sound.tween([300, 3000, 800], 1.bar, curve: :linear), 8)
      expect([0, 1, 2, 3, 4, 5, 6, 7].map { |i| out[i * 48000].round(1) }).to eq([300, 1650, 3000, 1900, 800, 550, 300, 1650])
    end

    it 'takes its length per step, as its docs say: [100.hz, 5000.hz, 100.hz] over 2.bars is back down after 4 bars, loops after 6' do
      out = take(MB::Sound.tween([100.hz, 5000.hz, 100.hz], 2.bars, curve: :linear), 14) # 2 bars = 4 s
      at = ->(bars) { out[(bars * 2 * 48000).round] }
      expect(at.(0)).to be_within(0.5).of(100)
      expect(at.(2)).to be_within(1).of(5000)
      expect(at.(4)).to be_within(0.5).of(100)
      expect(at.(5)).to be_within(0.5).of(100) # the loop's last step: 100 back to 100
      expect(at.(6.5)).to be_within(1).of(100 * 50**0.25) # up again, in octaves
    end

    it 'holds a repeated value for its step' do
      out = take(MB::Sound.tween([0, 1, 1, 0], 1.bar, curve: :linear, loop: false), 8)
      expect(out[96000...192000].to_a.uniq).to eq([1.0])
    end

    it 'steps with per-step lengths and :steps' do
      out = take(MB::Sound.tween([0, 12, 12], [2.beats, 1.bar], curve: :steps, cycles: 4, loop: false), 2)
      first = out[0...48000].to_a.each_slice(12000).map(&:uniq)
      expect(first).to eq([[3.0], [6.0], [9.0], [12.0]])
    end

    it 'takes a fixed time, then holds' do
      out = take(MB::Sound.tween([0, 10], 1.bar, time: 1.beat, curve: :back, loop: false), 2)
      expect(out[24000 - 1]).to be_within(1e-4).of(10)
      expect(out[12000...24000].max).to be > 10.5
      expect(out[24000..].to_a.uniq).to eq([10.0])
    end

    it 'follows tempo changes in Duration times' do
      node = MB::Sound.tween([0, 1], 1.bar, curve: :linear)
      MB::Sound.bpm(240)
      out = take(node, 1.5)
      expect(out[24000 - 1]).to be_within(1e-4).of(0.5)
    ensure
      MB::Sound.bpm(120)
    end

    it 'tweens Pitches in octaves (in Hz), keeping overshoots positive' do
      out = take(MB::Sound.tween([3400.hz, 700.hz], 1.bar, curve: :elastic, overshoot: 0.35, loop: false), 4)
      e = MB::Sound::Curve[:elastic, overshoot: 0.35]
      expect(out[47999]).to be_within(1).of(3400 * (700 / 3400.0)**e.(0.5))
      expect(out.min).to be > 0
      expect(out.min).to be_within(10).of(700 * (700 / 3400.0)**0.35)
      expect(out[-1]).to be_within(0.01).of(700)

      lin = take(MB::Sound.tween([300.hz, 900.hz], 1.bar, curve: :linear, log: false, loop: false), 1)
      expect(lin[47999]).to be_within(0.1).of(600)
      expect(take(MB::Sound.tween([300, 1200], 1.bar, curve: :linear, log: true, loop: false), 1)[47999]).to be_within(0.1).of(600)
    end

    it 'rejects mixed Pitches and numbers, other values, and non-positive log values' do
      expect { MB::Sound.tween([MB::Sound::C4, 1]) }.to raise_error(ArgumentError, /mix/)
      expect { MB::Sound.tween([:a, 1]) }.to raise_error(ArgumentError, /numbers or Pitches/)
      expect { MB::Sound.tween([0, 1], log: true) }.to raise_error(ArgumentError, /positive/)
    end
  end

  describe 'Clip#tween' do
    it 'tweens over uneven steps by default' do
      ev = MB::Sound::Sequence::Event
      clip = MB::Sound::Sequence::Clip.new([
        ev.new(start: 0r, length: 1/4r, value: 0, velocity: 1), ev.new(start: 1/4r, length: 1/2r, value: 8, velocity: 1),
        ev.new(start: 3/4r, length: 1/4r, value: 4, velocity: 1),
      ], loop: true) # 0.5 s, 1 s, 0.5 s
      out = take(clip.tween(curve: :linear), 2.5)
      expect(out[11999]).to be_within(1e-3).of(4) # halfway from 0 to 8 in 0.5 s
      expect(out[24000 + 23999]).to be_within(1e-3).of(6) # halfway from 8 to 4 in 1 s
      expect(out[72000 + 11999]).to be_within(1e-3).of(2) # halfway from 4 back to 0
      expect(out[96000]).to be_within(1e-2).of(0)
    end

    it 'tweens the note numbers of a seq of Notes (in semitones)' do
      out = take(MB::Sound.seq(MB::Sound::A3, MB::Sound::A4).n2.tween(curve: :linear), 1)
      expect(out[23999]).to be_within(0.01).of(63)
    end
  end

  describe 'a curve per step (curve: [...], tween-curves-1)' do
    # +seconds+ of +node+ in buffers of +size+.
    def take_in(node, seconds, size)
      n = (seconds * 48000).round
      SpecBuffers.join(((n + size - 1) / size).times.map { node.sample(size).dup }).cast_to(Numo::DFloat)[0...n]
    end

    # What a looping tween of +values+ over +steps+ (samples) with +curves+
    # (one per step, cycling like the steps) plays for +n+ samples: step i
    # at its k-th sample is a + (b - a) * curve((k + 1) / L), as
    # Notes::Glide fills it (Curve#lookup; float32 output).
    def expected(values, steps, curves, n)
      out = []
      i = 0
      while out.length < n
        st = i % values.length
        len = steps[st % steps.length]
        a = values[st]
        b = values[(st + 1) % values.length]
        t = (Numo::DFloat.new(len).seq + 1) / len
        shaped = MB::Sound::Curve[curves[st % curves.length]].lookup(t)
        out.concat(Numo::SFloat.cast(shaped * (b - a) + a).to_a)
        i += 1
      end
      Numo::DFloat.cast(out[0...n])
    end

    let(:values) { [0.0, 1.0, 0.5, 0.8, 0.2] }
    # (shorter than the five steps: they cycle, :fast again for step 4, ...)
    let(:curves) { [:fast, :hold, :sharp] }
    let(:tw) { -> { MB::Sound.tween(values, [1.beat, 2.beats], curve: curves) } }

    it 'tweens each step along its own curve, cycling the list like the step lengths' do
      out = take(tw.call, 7) # 7 beats a loop (1 2 1 2 1), 2 loops
      ref = expected(values, [24000, 48000], curves, out.length)
      expect((out - ref).abs.max).to be < 1e-7

      # :hold keeps its step's first value, then lands on the next on the
      # step's last sample, like every curve
      expect(out[24000...71999].to_a.uniq).to eq([1.0])
      expect(out[71999]).to eq(0.5)
      # The second loop starts again at the first curve and length
      expect((out[168000...192000] - ref[0...24000]).abs.max).to be < 1e-7
    end

    it 'plays the same at any buffer size' do
      ref = take_in(tw.call, 4, 800)
      [367, 64, 1].each do |bs|
        seconds = bs == 1 ? 0.6 : 4
        expect(take_in(tw.call, seconds, bs)).to eq(ref[0...(seconds * 48000).round])
      end
    end

    it 'plays a list of one curve, or the same curve repeated, bit for bit like the curve alone' do
      one = take(MB::Sound.tween([0.0, 1.0, 0.3], [1.beat, 2.beats], curve: :elastic, overshoot: 0.3), 2)
      expect(take(MB::Sound.tween([0.0, 1.0, 0.3], [1.beat, 2.beats], curve: [:elastic], overshoot: 0.3), 2)).to eq(one)
      twice = [:elastic, MB::Sound::Curve[:elastic, overshoot: 0.3]]
      expect(take(MB::Sound.tween([0.0, 1.0, 0.3], [1.beat, 2.beats], curve: twice, overshoot: 0.3), 2)).to eq(one)
    end

    [800, *SlowTier.slow_tier([367, 128])].each do |bs|
      it "resumes the launched step's own curve when launched partway through it (#{bs}-frame buffers)" do
        ref = take(tw.call, 14)
        # mid-step 2 (:hold), mid-step 3 (:sharp), and on step 4's start
        [50000, 85000, 120000].each do |pre|
          out = launched_tween(tw.call, pre: pre, buffer_size: bs, bars: 2)
          start = out.to_a.index { |v| v != 0 }
          expect(start).to be_within(bs).of(pre)
          expect((out[start...(start + 96000)] - ref[start...(start + 96000)]).abs.max).to be < 1e-6
        end
      end
    end

    it 'starts at its first keyframe and curve with align: :launch' do
      out = launched_tween(MB::Sound.tween(values, [1.beat, 2.beats], curve: curves, align: :launch), pre: 100000, buffer_size: 800, bars: 2)
      start = out.to_a.index { |v| v != 0 }
      ref = expected(values, [24000, 48000], curves, 96000)
      expect((out[start...(start + 96000)] - ref).abs.max).to be < 1e-7
    end

    it 'lands on the right value and curve after a seek into a step' do
      session = MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1, buffer_size: 800, realtime: false, raise_errors: true)
      out = []
      MB::Sound::Session.with_context(session: session) {
        MB::Sound.bg(:t, tw.call)
        60.times { out << session.process_buffer[0].dup } # 48000 frames
        session.seek(MB::Sound::Sequence::Duration.new(11/8r)) # 5.5 beats: mid-step 4 (:fast, 0.8 -> 0.2)
        120.times { out << session.process_buffer[0].dup }
      }
      session.close
      data = SpecBuffers.join(out).cast_to(Numo::DFloat)
      ref = take(tw.call, 5)
      expect((data[48000...144000] - ref[132000...228000]).abs.max).to be < 1e-6
    end

    it 'matches the .acd study oracle on a mixed-curve breakpoint list (ACID envelope segments)' do
      # Ported from research-acd-format-linux's
      # research/acd-format/acd/audio_render_oracle.rb envelope_values: a
      # segment from point a to point b plays a + (b - a) * curve(x),
      # x = (s - a.time) / (b.time - a.time), with the curve of a's code
      # (acd/midi.rb CURVES; 0 holds a's value); before the first point the
      # first value, after the last the last.  (The oracle evaluates that
      # every 64 samples and interpolates; here it is per sample.)
      acid = {
        0 => ->(_x) { 0.0 }, 1 => ->(x) { x }, 2 => ->(x) { 1 - (1 - x)**2 }, -2 => ->(x) { x * x },
        4 => ->(x) { x * x * (3 - 2 * x) }, -4 => ->(x) { 0.5 + 4 * (x - 0.5)**3 },
      }
      names = { 0 => :hold, 1 => :linear, 2 => :fast, -2 => :slow, 4 => :smooth, -4 => :sharp }
      beats = [0, 1, 3, 7/2r, 5, 6, 8]
      vals = [0.2, 1.0, 0.5, 0.9, 0.1, 0.6, 0.3]
      codes = [2, 0, -4, -2, 4, 1, 1]
      pts = beats.zip(vals, codes).map { |b, v, c| [(b * 24000).to_i, v, c] }
      oracle = ->(s) {
        i = pts.rindex { |p| p[0] <= s }
        next pts.first[1] if i.nil?
        next pts[i][1] if i == pts.length - 1

        a, b = pts[i], pts[i + 1]
        a[1] + (b[1] - a[1]) * acid.fetch(a[2]).((s - a[0]).to_f / (b[0] - a[0]))
      }

      steps = beats.each_cons(2).map { |a, b| MB::Sound::Sequence::Duration.new((b - a) / 4r) }
      out = take(MB::Sound.tween(vals, steps, curve: codes[0...-1].map(&names), loop: false), 4.5)
      now = Numo::DFloat.cast((0...out.length).map { |s| oracle.(s) })
      ahead = Numo::DFloat.cast((0...out.length).map { |s| oracle.(s + 1) })

      # A glide's k-th sample is at x = (k + 1) / L (it lands on b on the
      # step's last sample), so the tween is the oracle one sample ahead,
      # within float32 rounding (3e-8 measured)
      expect((out - ahead).abs.max).to be < 1e-7
      # Without the one-sample lead: within a sample's slope (1e-4
      # measured), except on a :hold step's last sample, where the tween
      # has already jumped to the next value
      hold_end = pts[2][0] - 1
      expect(out[hold_end]).to be_within(1e-7).of(0.5)
      expect(now[hold_end]).to eq(1.0)
      diff = (out - now).abs
      diff[hold_end] = 0
      expect(diff.max).to be < 2e-4
    end

    it 'takes overshoot: and cycles: for every name in the list, Curves and beziers as they are' do
      list = [:elastic, MB::Sound::Curve[:back, overshoot: 0.2], [0.25, 0.1, 0.25, 1.0], MB::Sound::Curve.db(-20)]
      out = take(MB::Sound.tween([0.0, 1.0, 0.0, 1.0], 1.beat, curve: list, overshoot: 0.4, cycles: 2), 2)
      ref = expected([0.0, 1.0, 0.0, 1.0], [24000], [MB::Sound::Curve[:elastic, overshoot: 0.4, cycles: 2], *list[1..]], out.length)
      expect((out - ref).abs.max).to be < 1e-7

      expect { MB::Sound.tween([0, 1], curve: [:elastic, :linear], overshoot: 0.4) }.to raise_error(ArgumentError, /linear curve takes no options/)
      expect { MB::Sound.tween([0, 1], curve: [MB::Sound::Curve[:elastic], MB::Sound::Curve[:linear]], cycles: 2) }.to raise_error(ArgumentError, /need curve names/)
      expect { MB::Sound.tween([0, 1], curve: [:fast, [:slow, :hold]]) }.to raise_error(ArgumentError, /can't hold another list/)
      expect { MB::Sound.tween([0, 1], curve: [:fast, :wobble]) }.to raise_error(ArgumentError, /Unknown curve :wobble/)
      # An Array of numbers alone is still one bezier
      bez = take(MB::Sound.tween([0.0, 1.0], 1.beat, curve: [0.25, 0.1, 0.25, 1.0]), 1)
      expect(bez).to eq(take(MB::Sound.tween([0.0, 1.0], 1.beat, curve: :ease), 1))
      expect { MB::Sound::Curve.from([:fast, :slow]) }.to raise_error(ArgumentError, /one curve per step/)
    end

    it 'tweens Clip values with a curve per event (Clip#tween), Pitches in octaves' do
      out = take(MB::Sound.seq(0, 12, 12, 7).n4.loop.tween(curve: [:slow, :hold, :fast]), 2)
      ref = expected([0.0, 12.0, 12.0, 7.0], [24000], [:slow, :hold, :fast], out.length)
      expect((out - ref).abs.max).to be < 1e-5

      hz = take(MB::Sound.tween([200.hz, 800.hz], 1.beat, curve: [:linear, :hold]), 1)
      expect(hz[11999]).to be_within(0.01).of(400) # halfway up in octaves
      expect(hz[24000...47999].to_a.uniq.length).to eq(1) # then holds 800 Hz
      expect(hz[30000]).to be_within(0.01).of(800)
    end

    it 'saves and loads in graph documents and prints as Ruby' do
      code = 'tween([300.hz, 3000.hz, 800.hz], [1.beat, 2.beats], curve: [:fast, Curve[:elastic, overshoot: 0.4], [0.25, 0.1, 0.25, 1.0], Curve.db(-20), :hold])'
      graph = MB::Sound.module_eval("110.hz.saw.filter(:lowpass, cutoff: #{code}, quality: 2)", __FILE__, __LINE__)
      doc = MB::Sound::GraphIO.dump(graph, name: 'tw')
      expect(doc).to include('curve: [:fast, Curve[:elastic, overshoot: 0.4, cycles: 3.0], [0.25, 0.1, 0.25, 1.0], Curve[-20.0], :hold]')
      loaded = MB::Sound::GraphIO.load(doc)
      expect(RecipeHelpers.max_diff(RecipeHelpers.render(graph, buffers: 300), RecipeHelpers.render(loaded, buffers: 300))).to eq(0)
      expect(MB::Sound::GraphIO.dump(loaded, name: 'tw').sub(/saved: "[^"]*"/, '')).to eq(doc.sub(/saved: "[^"]*"/, ''))

      expect(MB::Sound.tween([0, 1], 1.bar, curve: [:fast, :slow]).to_ruby).to eq('tween([0, 1], 1.bar, curve: [:fast, :slow])')
    end
  end

  describe 'GraphNode#smooth with a curve' do
    it 'draws each change along the curve' do
      out = take(MB::Sound.seq(0, 1).n2.loop.number.smooth(0.1, curve: :bounce), 1.2)
      c = MB::Sound::Curve[:bounce]
      t = (Numo::DFloat.new(4800).seq + 1) / 4800.0
      expect((out[48000...52800] - c.map(t)).abs.max).to be < 1e-6
      expect(out[52800..].to_a.uniq).to eq([1.0])
    end
  end

  describe 'TimelineInterpolator' do
    it 'blends keyframes with any curve' do
      ti = MB::Sound::TimelineInterpolator.new([{ time: 0, data: [0], blend: :elastic }, { time: 1, data: [2] }])
      expect(ti.value(0.3)[0]).to be_within(1e-12).of(2 * MB::Sound::Curve[:elastic].(0.3))
      expect { MB::Sound::TimelineInterpolator.new([{ time: 0, data: [0], blend: :wobble }]) }.to raise_error(/blend/)
    end
  end
end
