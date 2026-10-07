RSpec.describe('Tweens (MB::Sound.tween, Clip#tween, smooth(curve:))') do
  # +seconds+ of +node+ as a DFloat, in buffers of 480.
  def take(node, seconds)
    (seconds * 100).round.times.map { node.sample(480).dup }.reduce(:concatenate).cast_to(Numo::DFloat)
  end

  before { MB::Sound.bpm(120) }

  describe 'MB::Sound.tween' do
    it 'tweens to each value along the curve, reaching it as the next step starts' do
      out = take(MB::Sound.tween([0, 1, 0.3], 1.bar, curve: :elastic), 6) # a bar is 2 s
      c = MB::Sound::Curve[:elastic]
      expect(out[0...96000].to_a.uniq).to eq([0.0])
      t = (Numo::DFloat.new(96000).seq + 1) / 96000.0
      expect((out[96000...192000] - c.map(t)).abs.max).to be < 1e-6
      expect(out[96000...192000].max).to be > 1.2
      expect(out[192000]).to be_within(1e-6).of(1 + (0.3 - 1) * c.(1 / 96000.0))
    end

    it 'loops back to the first value' do
      out = take(MB::Sound.tween([0, 1], 1, curve: :linear), 8)
      expect(out[96000 + 48000 - 1]).to be_within(1e-4).of(0.5)
      expect(out[192000 + 48000 - 1]).to be_within(1e-4).of(0.5) # 1 -> 0
      expect(out[192000 + 96000 - 1]).to be_within(1e-4).of(0)
    end

    it 'steps with per-step lengths and :steps' do
      out = take(MB::Sound.tween([0, 12], [1.bar, 2.beats], curve: :steps, cycles: 4), 3)
      second = out[96000...144000].to_a.each_slice(12000).map { |s| s.uniq }
      expect(second).to eq([[3.0], [6.0], [9.0], [12.0]])
    end

    it 'takes a fixed time, then holds' do
      out = take(MB::Sound.tween([0, 10], 1.bar, time: 1.beat, curve: :back), 4)
      expect(out[96000 + 24000 - 1]).to be_within(1e-4).of(10)
      expect(out[96000 + 12000...96000 + 24000].max).to be > 10.5
      expect(out[96000 + 24000...192000].to_a.uniq).to eq([10.0])
    end

    it 'follows tempo changes in Duration times' do
      node = MB::Sound.tween([0, 1], 1.bar, curve: :linear)
      MB::Sound.bpm(240)
      out = take(node, 1.5)
      expect(out[48000 + 24000 - 1]).to be_within(1e-4).of(0.5)
    ensure
      MB::Sound.bpm(120)
    end

    it 'rejects non-numeric values' do
      expect { MB::Sound.tween([MB::Sound::C4, 1]) }.to raise_error(ArgumentError, /numbers/)
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
      expect(out[24000 + 23999]).to be_within(1e-3).of(4) # halfway through the 1 s step to 8
      expect(out[72000 + 11999]).to be_within(1e-3).of(6) # halfway from 8 to 4
      expect(out[96000 + 11999]).to be_within(1e-3).of(2) # looping back to 0
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
