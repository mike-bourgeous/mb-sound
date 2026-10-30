# Controller lanes of clips (midi-import-1): Sequence::ControlLane, Clip's
# lane transforms, and MIDI::ClipSource playing them.
RSpec.describe(MB::Sound::Sequence::ControlLane) do
  let(:lane_class) { MB::Sound::Sequence::ControlLane }
  let(:steps) { lane_class.new(:cc, 1, [[0r, 0.0], [1/4r, 0.5], [1/2r, 1.0]]) }
  let(:clip) { MB::Sound.events([0r, 1/8r, 60, 0.8], length: 1r, loop: true, controls: { cc1: steps.to_spec }) }

  # Events of +clip+ read in +step+-second reads for +seconds+, as
  # [time, type, note or controller, value].
  def read_events(clip, seconds: 4, step: 1/50r, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
    src = MB::Sound::MIDI::ClipSource.new(clip, transport: transport)
    t = 0r
    out = []
    while t < seconds
      out.concat(src.read(t, t + step).map { |e| [e.time, e.type, e.note, e.value] })
      t += step
    end
    out
  end

  describe 'lanes' do
    it 'checks types, numbers, curves, ranges, and positions' do
      expect { lane_class.new(:cc, 128, [[0r, 0.5]]) }.to raise_error(ArgumentError, /number from 0 to 127/)
      expect { lane_class.new(:bend, 3, [[0r, 0.5]]) }.to raise_error(ArgumentError, /no number/)
      expect { lane_class.new(:fader, nil, [[0r, 0.5]]) }.to raise_error(ArgumentError, /one of :cc/)
      expect { lane_class.new(:cc, 1, [[0.5, 0.5]]) }.to raise_error(ArgumentError, /exact numbers/)
      expect { lane_class.new(:cc, 1, []) }.to raise_error(ArgumentError, /at least one point/)
      expect { lane_class.new(:cc, 1, [[0r, 0.5]], range: 12) }.to raise_error(ArgumentError, /Only a bend lane/)
      expect(lane_class.new(:cc, 1, [[0r, 2.0], [0r, 0.3]]).points).to eq([[0r, 0.3]])
      expect(lane_class.new(:bend, nil, [[0r, -3]]).points).to eq([[0r, -1.0]])
    end

    it 'holds step values and interpolates curve lanes on their resolution grid' do
      expect(steps.value_at(0.3r)).to eq(0.5)
      expect(steps.value_at(-1r)).to be_nil
      linear = lane_class.new(:cc, 1, steps.points, curve: :linear, resolution: 1/16r)
      expect(linear.value_at(1/8r)).to eq(0.25)
      expect(linear.edges(0r, 1r).map(&:first)).to eq((0..8).map { |k| k * 1/16r })
      expect(linear.edges(3/32r, 5/32r)).to eq([[1/8r, 0.25]])
      expect([linear.next_at(0r), linear.next_at(1/100r), linear.next_at(0.6r)]).to eq([0r, 1/16r, nil])
      cubic = lane_class.new(:cc, 74, [[0r, 0.0], [1/4r, 0.2], [1/2r, 1.0]], curve: nil)
      vals = cubic.edges(0r, 1/2r).map(&:last)
      expect(vals.each_cons(2).all? { |a, b| b >= a }).to be(true) # (monotone: no overshoot)
    end

    it 'round-trips through specs' do
      [steps, lane_class.new(:cc, 74, steps.points, curve: nil, resolution: 1/1024r), lane_class.new(:bend, nil, [[0r, 0.1]], range: 12),
       lane_class.new(:poly_pressure, 60, [[0r, 0.5]])].each do |l|
        expect(lane_class.from_spec(l.name, l.to_spec)).to eq(l)
      end
      expect { lane_class.from_spec(:cc1, { points: [[0r, 0.1]], curve: :smooth }) }.to raise_error(ArgumentError, /curve: is :step, :linear, :cubic/)
      expect { lane_class.from_spec(:mod, [[0r, 0.1]]) }.to raise_error(ArgumentError, /named cc1..cc127/)
    end
  end

  it 'gives knob keyframes for turn (a controller-only clip as a gesture)' do
    linear = lane_class.new(:cc, 7, [[0r, 0.0], [2r, 1.0]], curve: :linear)
    keys = linear.keyframes(-60.0..0.0)
    expect(keys).to eq({ 0 => -60.0, MB::Sound::Sequence::Duration.new(2r) => 0.0 })
    expect(linear.gesture_curve).to eq(:linear)
    g = MB::Sound::Gesture.from_hash(keys, curve: linear.gesture_curve, per_sample: 1/96000r, rate: 48000)
    expect(g.keys).to eq([[0, -60.0], [192000, 0.0]])
  end

  describe 'clip transforms' do
    it 'keep lanes through note transforms and loop' do
      [clip.transpose(2), clip.legato(0.5), clip.vel(0.3), clip.humanize(1/64r, seed: 2), clip.loop, clip.named(:x)].each do |c|
        expect(c.controls).to eq([steps])
      end
    end

    it 'move lanes with time transforms' do
      expect(clip.stretch(2).control(1).points).to eq([[0r, 0.0], [1/2r, 0.5], [1r, 1.0]])
      expect(clip.rotate(1/8r).control(1).points).to eq([[0r, 1.0], [1/8r, 0.0], [3/8r, 0.5], [5/8r, 1.0]])
      expect(clip.shift(1/8r).control(1).points).to eq([[1/8r, 0.0], [3/8r, 0.5], [5/8r, 1.0]])
      expect(clip.shift(-1/8r).control(1).points).to eq([[0r, 0.0], [1/8r, 0.5], [3/8r, 1.0]])
      expect(clip.shift(1r).controls).to be_empty
      expect(clip.reverse.control(1).points).to eq([[0r, 1.0], [1/2r, 0.5], [3/4r, 0.0]])
      expect(clip.truncate(1/2r).control(1).points).to eq([[0r, 0.0], [1/4r, 0.5]])
      two = nil
      expect { two = clip.repeat(2) }.to output(/stop looping/).to_stderr
      expect(two.control(1).points.map(&:first)).to eq([0r, 1/4r, 1/2r, 1r, 5/4r, 3/2r])
      cat = clip.without_controls | clip
      expect(cat.control(1).points.map(&:first)).to eq([1r, 5/4r, 3/2r])
      both = clip & MB::Sound.events([0r, 1/8r, 64, 0.8], length: 1r, controls: { cc1: [[1/8r, 0.2]], bend: [[0r, 0.5]] })
      expect(both.control(1).points.map(&:first)).to eq([0r, 1/8r, 1/4r, 1/2r])
      expect(both.control(:bend)).not_to be_nil
    end

    it 'fits step lanes into curves within the tolerance' do
      ramp = lane_class.new(:cc, 1, (0..64).map { |k| [k * 1/64r, (k * 2) / 127.0] })
      c = MB::Sound.events([0r, 1/8r, 60, 0.8], length: 2r, loop: true, controls: { cc1: ramp.to_spec }).fit_controls
      expect(c.control(1).points.length).to eq(2)
      expect(c.control(1)).not_to be_stepped
    end
  end

  describe 'playback (MIDI::ClipSource)' do
    it 'sends controller values at exact times, before notes at the same time' do
      evs = read_events(clip, seconds: 2.1r)
      expect(evs).to eq([
        [0r, :cc, 1, 0.0], [0r, :note_on, 60, 0.8], [1/4r, :note_off, 60, 64 / 127.0], [1/2r, :cc, 1, 0.5], [1r, :cc, 1, 1.0],
        [2r, :cc, 1, 0.0], [2r, :note_on, 60, 0.8],
      ].map { |t, *rest| [t, *rest] })
    end

    it 'sends the values in effect after seeks, swaps, and skipped spans' do
      src = MB::Sound::MIDI::ClipSource.new(clip, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
      src.read(0r, 1/10r)
      src.seek(1.2r) # (clip position 0.6: cc1 holds 1.0 from 0.5)
      expect(src.read(1/10r, 2/10r).select(&:cc?).map { |e| [e.time, e.value] }).to eq([[1/10r, 1.0]])
      # A read past the position skips the span between (to clip position
      # 2.05: cycle 2 holds its first value)
      expect(src.read(3r + 1/10r, 3r + 2/10r).select(&:cc?).map { |e| [e.time, e.value] }).to eq([[3r + 1/10r, 0.0]])
      src.swap_clip(MB::Sound.events([0r, 1/8r, 62, 0.8], length: 1r, loop: true, controls: { cc1: [[0r, 0.25]] }))
      expect(src.read(3r + 2/10r, 3r + 3/10r).select(&:cc?).map(&:value)).to eq([0.25])
    end

    it 'gives the same events at any read size, with and without quiet reads' do
      fit = MB::Sound.events([0r, 1/8r, 60, 0.8], [1/2r, 1/8r, 62, 0.8], length: 1r, loop: true,
                             controls: { cc1: steps.to_spec, cc74: { curve: :cubic, points: [[0r, 0.1], [1/3r, 0.9], [3/4r, 0.2]] }, bend: [[1/8r, -0.5]] })
      ref = read_events(fit, step: 1/1000r).select { |t, *| t < 3.9 }
      expect(ref.count { |e| e[2] == 74 }).to be > 100
      [[48000, 800], [48000, 367], [44100, 128]].each do |rate, n|
        [true, false].each do |quiet|
          MB::Sound::MIDI::ClipSource.quiet_reads = quiet
          expect(read_events(fit, step: Rational(n, rate)).select { |t, *| t < 3.9 }).to eq(ref)
        ensure
          MB::Sound::MIDI::ClipSource.quiet_reads = true
        end
      end
    end

    it 'drives Notes controllers, keeping fitted values between 7-bit steps' do
      c = MB::Sound.events([0r, 1r, 60, 0.8], length: 1r, loop: true, controls: { cc1: { curve: :linear, points: [[0r, 0.0], [1/2r, 0.5]] } })
      mod = c.notes(transport: MB::Sound::Sequence::Transport.new(bpm: 120)).mod(smooth: false)
      vals = Array.new(50) { mod.sample(960)[-1] }
      expect(vals[24]).to be_within(1 / 512.0 + 1e-9).of(0.25) # (the grid value before 0.5 s)
      expect(vals.map { |v| (v * 127).round(6) }.uniq.count { |v| v != v.round }).to be > 10
    end
  end
end
