RSpec.describe('Delays ringing out after their input ends') do
  let(:margin) { MB::Sound::DelayLine::MARGIN }

  # A one-shot pluck: a 0.001 s attack and a 0.2 s decay (ends after about
  # 0.32 s, with the envelope's hold)
  def pluck
    440.hz.triangle * MB::Sound.env([[1, 0.001], [0, 0.2, 60]])
  end

  # Samples +node+ in +size+-sample buffers until it ends, returning all of
  # its output and the buffer lengths.
  def drain(node, size: 800, limit: 600_000 / size)
    bufs = []
    limit.times do
      b = node.sample(size)
      break if b.nil?

      bufs << b.dup
    end
    raise 'The node never ended' if bufs.length == limit

    SpecBuffers.join(bufs)
  end

  # Checks that +out+ is what the never-ending graph from the block (its
  # input padded with silence by #ringdown) plays, and that what it would
  # have played after +out+ ends is below -90 dB.
  def expect_quiet_cut(out, tolerance: 0)
    ref = yield
    data = SpecBuffers.join(Array.new((out.length + 3 * 48000) / 800 + 1) { ref.sample(800).dup })
    expect((data[0...out.length] - out).abs.max).to be <= tolerance
    expect(data[out.length..].abs.max).to be < MB::Sound::QuietRun::QUIET
  end

  # The same length at another buffer size, and the same samples but for
  # the pluck's own ~1e-15 differences between buffer sizes (its envelope,
  # as before ringing out).
  def expect_same(other, out)
    expect(other.length).to eq(out.length)
    expect((other - out).abs.max).to be < 1e-12
  end

  def source_length
    drain(pluck).length
  end

  describe 'the ring-out form of MB::Sound::QuietRun' do
    it 'ends where a quiet run reaches the window, wherever the loud samples fall' do
      r = MB::Sound::QuietRun.new(0)
      expect(r.advance(Numo::SFloat[1, 0, 0, 0, 0], 5, 10)).to eq(nil)
      expect(r.quiet_for(r.at)).to eq(4)
      expect(r.advance(nil, 8, 10)).to eq(6)
      expect(r).to be_done

      r = MB::Sound::QuietRun.new(0)
      expect(r.advance(Numo::SFloat[0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0], 12, 3)).to eq(6)
      expect(MB::Sound::QuietRun.new(0).advance(Numo::SFloat[0, 0, 0, 1], 4, 3)).to eq(3)
      expect(MB::Sound::QuietRun.new(0).advance(Numo::SFloat[1, 0, 0, 0], 4, 3)).to eq(4)
    end

    it 'counts -90 dB as silent, like Session tails' do
      r = MB::Sound::QuietRun.new(0)
      expect(r.advance(Numo::SFloat[MB::Sound::QuietRun::QUIET * 0.99, 0], 2, 2)).to eq(2)
      r = MB::Sound::QuietRun.new(0)
      expect(r.advance(Numo::SFloat[MB::Sound::QuietRun::QUIET * 1.01, 0], 2, 2)).to eq(nil)
    end
  end

  describe 'GraphNode#delay' do
    it 'plays the last echo of a plain delay, ending one delay plus the interpolation reach after its input' do
      out = drain(pluck.delay(0.375))
      expect(out.length).to eq(source_length + 18000 + margin)
      expect(out[18000..].abs.max).to be > 0.9
    end

    it 'rings out with feedback until the repeats fall below -90 dB, at any buffer size' do
      out = drain(pluck.delay(1.n8.dotted, feedback: 0.5))
      expect(out[0...18000].abs.max).to eq(0)

      # Each repeat is 6 dB quieter: about 15 echoes until -90 dB
      expect(out.length).to be_between(14 * 18000, 17 * 18000)
      expect_quiet_cut(out) { pluck.ringdown.delay(1.n8.dotted, feedback: 0.5) }

      expect_same(drain(pluck.delay(1.n8.dotted, feedback: 0.5), size: 97), out)
      expect_same(drain(pluck.delay(1.n8.dotted, feedback: 0.5), size: 4800), out)
    end

    it 'ends with its input given ring_out: false (for structures with their own tails)' do
      expect(drain(pluck.delay(0.1, feedback: 0.5, ring_out: false)).length).to eq(source_length)
      expect { pluck.delay(0.1, feedback: 0.5, ring_out: false) { |fb| fb } }.to raise_error(ArgumentError, /ring_out/)
    end

    it 'rings out with a feedback node and a dry signal' do
      out = drain(pluck.delay(0.1, feedback: 0.5.constant, dry: 1))
      expect(out.length).to be > source_length + 10 * 4800
    end

    it 'rings out through a Session (it used to play nothing)' do
      out = MB::Sound::NullOutput.new(channels: 2, sleep: false)
      session = MB::Sound::Session.new(master_gain: 1, output: out, buffer_size: 800, realtime: false, raise_errors: true)
      session.add(pluck.delay(1.n8.dotted, feedback: 0.5))
      data = SpecBuffers.join(Array.new(60) { session.process_buffer[0].dup })
      expect(data[0...18000].abs.max).to eq(0)
      expect(data[18000...36000].abs.max).to be > 0.9
      expect(data[36000..].abs.max).to be_between(0.4, 0.6)
    ensure
      session&.close
      MB::Sound.rewind
    end

    it 'rings out a tape echo with an insert block, and an insert pipeline, at any buffer size' do
      tape = ->(src = pluck) { src.delay(0.1, feedback: 0.5, dry: 1) { |fb| fb.filter(:lowpass, cutoff: 3000).softclip(0.5, 1) } }
      out = drain(tape.call)
      expect(out.length).to be > source_length + 10 * 4800
      expect_quiet_cut(out) { tape.call(pluck.ringdown) }
      expect_same(drain(tape.call, size: 97), out)

      pipe = -> {
        pluck.delay(0.1, feedback: 0.5, dry: 1) { |d|
          d.fb { |f| f.filter(3000.hz.lowpass) }
          d.wet { |w| w.filter(5000.hz.lowpass) }
        }
      }
      out = drain(pipe.call)
      expect(out.length).to be > source_length + 10 * 4800
      expect_same(drain(pipe.call, size: 97), out)
    end
  end

  describe 'GraphNode#multitap' do
    it 'plays every tap to its end' do
      l, r = pluck.multitap(0.1, 0.25)
      lo = []
      ro = []
      loop do
        a = l.sample(800)
        b = r.sample(800)
        break if a.nil?

        lo << a.dup
        ro << b.dup
      end
      lo = SpecBuffers.join(lo)
      ro = SpecBuffers.join(ro)

      expect(lo.length).to eq(source_length + 12000 + margin)
      expect(ro.length).to eq(lo.length)
      expect(ro[12000..].abs.max).to be > 0.9
    end
  end

  describe 'GraphNode#feedback' do
    it 'rings out after its input ends, at any buffer size' do
      # A tone cut off at 0.1 s rings for about 46 echoes of 5 ms
      make = ->(src = 440.hz.triangle.until(0.1)) { src.feedback { |fb, input| input + fb.delay(5.ms) * 0.8 } }
      out = drain(make.call)
      expect(out.length).to be_between(4800 + 40 * 240, 4800 + 50 * 240)
      expect_quiet_cut(out) { make.call(440.hz.triangle.until(0.1).ringdown) }
      expect(drain(make.call, size: 97)).to eq(out)
    end
  end
end
