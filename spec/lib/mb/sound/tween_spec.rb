RSpec.describe('Tweens (MB::Sound.tween, Clip#tween, smooth(curve:))') do
  # +seconds+ of +node+ as a DFloat, in buffers of 480.
  def take(node, seconds)
    (seconds * 100).round.times.map { node.sample(480).dup }.reduce(:concatenate).cast_to(Numo::DFloat)
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
      data = out.reduce(:concatenate)[24000..]
      expect(data[0]).to be < 0.001
      expect(data[24000]).to be_within(0.01).of(0.156) # smoothstep at 1/4 of the bar
      expect(data[48000]).to be_within(0.01).of(0.5)
      expect(data[96000]).to be_within(1e-6).of(1)
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
      out.reduce(:concatenate).cast_to(Numo::DFloat)
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
