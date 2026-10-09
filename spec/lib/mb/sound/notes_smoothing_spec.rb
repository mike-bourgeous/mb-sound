require 'numo/pocketfft'

# Controller smoothing (MB::Sound::Notes::Smoother, Notes.control_smoothing):
# controllers, pressure, and bend glide between MIDI value steps.
RSpec.describe('MB::Sound::Notes controller smoothing', :check_shared) do
  let(:ev) { MB::Sound::MIDI::Event }

  # A Notes on +events+, plus a late CC so the source doesn't end.
  def notes_for(*events, sample_rate: 48000)
    MB::Sound::Notes.new(MIDIListSource.new(events, ev.cc(99, 0, time: 1000r)), sample_rate: sample_rate)
  end

  # +total+ samples of +node+ read in buffers of +sizes+ in turn.
  def read(node, total, sizes = [128])
    out = []
    n = 0
    i = 0
    while n < total
      count = [sizes[i % sizes.length], total - n].min
      out << node.sample(count).dup
      n += count
      i += 1
    end
    out.reduce(:concatenate)
  end

  # Offline reference: the triangle kernel (two moving averages of n1 and
  # n2 samples) over +x+, starting settled at x[0].
  def triangle(x, n1, n2)
    box = ->(d, n) {
      ext = Numo::DFloat.new(n - 1).fill(d[0]).concatenate(d)
      c = Numo::DFloat.zeros(ext.length + 1)
      c[1..] = ext.cumsum
      (c[n..] - c[0...-n]) / n
    }
    box.(box.(Numo::DFloat.cast(x), n1), n2)
  end

  # Power above +cutoff+ Hz relative to full scale, in dB.
  def hf_db(x, cutoff, rate = 48000)
    d = Numo::DFloat.cast(x)
    spec = Numo::Pocketfft.rfft(d - d.mean)
    bin = (cutoff * d.length / rate.to_f).round
    10 * Math.log10((spec[bin..].abs ** 2).sum / d.length ** 2 + 1e-30)
  end

  # Channel pressure in 7-bit steps sent every 4 ms: a raised cosine
  # swell 0..1..0 over 0.8 s, as an aftertouch gesture (smooth itself, so
  # the energy above 200 Hz is the zipper).
  let(:gesture) {
    (0...200).map { |k|
      t = k * 0.004
      v = t < 0.8 ? (1 - Math.cos(2 * Math::PI * t / 0.8)) / 2 : 0
      ev.channel_pressure((v * 127).round / 127.0, time: Rational(k * 4, 1000))
    }
  }

  describe MB::Sound::Notes::Smoother do
    it 'is the triangle FIR in any buffer sizes, exact once settled' do
      x = Numo::SFloat.zeros(20000)
      [[100, 0.5], [130, 0.6], [1000, 0.2], [1003, 0.9], [5000, 0.1], [12000, 1.0]].each { |i, v| x[i..] = v }
      s = MB::Sound::Notes::Smoother.new(0.01, sample_rate: 48000)
      expect(s.kernel_samples).to eq(479)

      out = []
      pos = 0
      [128, 300, 64, 1000].cycle do |n|
        break if pos >= x.length
        b = x[pos...[pos + n, x.length].min].dup
        constant = b.eq(b[0]).all? ? b[0] : nil
        b.freeze if constant
        r = s.process(b, constant)
        expect(r).to equal(b) if constant && s.settled? && b[0] == r[0] && pos > 13000
        out << r.dup
        pos += n
      end
      y = out.reduce(:concatenate)

      expect((Numo::DFloat.cast(y) - triangle(x, 240, 240)).abs.max).to be < 1e-6
      expect(y[(130 + 478)..999].to_a.uniq).to eq([x[200]])
      expect(y[12000 + 477]).not_to eq(1.0)
      expect(y[(12000 + 478)..].to_a.uniq).to eq([1.0])
    end

    it 'jumps at the offsets given' do
      s = MB::Sound::Notes::Smoother.new(0.002, sample_rate: 48000)
      x = Numo::SFloat.zeros(512)
      x[100..] = 1
      x[300..] = 0.25
      y = s.process(x, nil, [300])
      expect(y[100]).to be < 0.01
      expect(y[299]).to be_between(0.9, 1)
      expect(y[300..].to_a.uniq).to eq([0.25])
    end

    it 'takes Lengths and follows sample rate changes' do
      s = MB::Sound::Notes::Smoother.new(96.samples, sample_rate: 48000)
      expect(s.kernel_samples).to eq(95)
      s = MB::Sound::Notes::Smoother.new(10.ms, sample_rate: 48000)
      s.sample_rate = 96000
      expect(s.kernel_samples).to eq(959)
    end
  end

  describe 'adaptive smoothing' do
    # A slow 7-bit bend: 0 to 1 in 64 MSB-only steps every 31.25 ms
    let(:slow_bend) {
      (1..64).map { |k| ev.bend(k / 64.0, time: Rational(k * 3125, 100_000) + 0.01r) }
    }

    it 'matches its Ruby mirror in any buffer sizes, with jumps' do
      x = Numo::SFloat.zeros(30000)
      t = 50
      v = 0.0
      while t < 30000
        x[t..] = v
        t += [7, 240, 1500, 3, 9000, 480].sample(random: Random.new(t))
        v = (v * 7 + 0.37) % 1.3 - 0.4
      end

      runs = [true, false].map { |c|
        s = MB::Sound::Notes::Smoother.new(5.ms..100.ms, sample_rate: 48000)
        expect(s).to be_adaptive
        expect(s.kernel_samples).to eq(4800)
        out = []
        pos = 0
        [128, 300, 64, 1000, 1].cycle do |n|
          break if pos >= x.length
          b = x[pos...[pos + n, x.length].min].dup
          s.send(:settle_at, b[0]) unless s.plan_arrays[0]
          o = Numo::SFloat.zeros(b.length)
          jumps = pos == 12800 ? [5] : nil
          MB::Sound::Notes::Smoother.run(b, o, 0, b.length, s.plan_arrays[0], s.plan_arrays[1], s.plan_arrays[2], jumps, c: c)
          out << o
          pos += n
        end
        out.reduce(:concatenate)
      }
      expect(runs[0].to_a).to eq(runs[1].to_a)
      expect(runs[0][12805]).to eq(x[12805])
    end

    it 'turns a slow 7-bit bend staircase into a line' do
      fixed = read(notes_for(*slow_bend).bend, 120_000)
      adaptive = read(notes_for(*slow_bend).bend(smooth: :adaptive), 120_000)
      expect(notes_for.bend(smooth: :adaptive).smooth_time).to eq(MB::Sound::Notes::ADAPTIVE_SMOOTHING)

      # Between the second and the last step: a constant slope (each ramp
      # ends as the next step arrives), where the 5 ms default holds flat
      # for about 26 ms of every 31 ms step
      mid = 6000...96000
      slope = 1 / 64.0 / 1500
      d_adaptive = Numo::DFloat.cast(adaptive[mid]).diff
      d_fixed = Numo::DFloat.cast(fixed[mid]).diff
      expect((d_adaptive - slope).abs.max).to be < 1e-6
      expect(d_fixed.eq(0).count).to be > 0.7 * d_fixed.length

      # Lags one step interval, ends exactly at the last value
      expect(adaptive[-1]).to eq(1.0)
      expect((adaptive[50000] - fixed[50000 - 1500]).abs).to be < 0.02
    end

    it 'glides an isolated step over the maximum and fast steps over the minimum' do
      events = [ev.cc_raw(1, 64, time: 0.5r)] + (1..20).map { |k| ev.cc_raw(1, 64 + k, time: 1.0r + Rational(k, 1000)) }
      out = read(notes_for(*events).mod(smooth: 5.ms..50.ms), 60000)
      done = (24000...48000).find { |i| out[i] == (64 / 127.0).to_f.then { |f| Numo::SFloat[f][0] } }
      expect(done).to eq(24000 + 2399)

      # 1 ms steps glide over 5 ms: the output trails the input by about
      # 240 samples at the end of the run
      expect(out[48000 + 20 * 48 + 240]).to eq(Numo::SFloat[84 / 127.0][0])
      expect(out[48000 + 20 * 48 + 100]).to be < 84 / 127.0
    end

    it 'takes :adaptive and Ranges of times, and refuses bad Ranges' do
      v = notes_for
      expect(v.cc(1, smooth: :adaptive).smooth_time).to eq(0.005..0.2)
      expect(v.cc(1, smooth: 2.ms..50.ms).smooth_time).to eq(2.ms..50.ms)
      expect { v.cc(2, smooth: 0.1..0.01) }.to raise_error(ArgumentError, /Smoothing/)
      expect { v.cc(2, smooth: 0..0.01) }.to raise_error(ArgumentError, /Smoothing/)
      expect { MB::Sound::Notes.control_smoothing = :slow }.to raise_error(ArgumentError, /Smoothing/)
    end
  end

  describe 'live global defaults' do
    it 'changes nodes made with the default from their next buffer; explicit ones keep theirs' do
      events = [ev.cc_raw(1, 127, time: 0.01r), ev.cc_raw(1, 0, time: 0.2r), ev.cc_raw(1, 127, time: 0.4r), ev.cc_raw(1, 0, time: 0.6r)]
      v = notes_for(*events)
      default = v.mod
      own = v.mod(smooth: 10.ms)
      a = read(default, 4800)
      b = read(own, 4800)
      expect(a.to_a).to eq(b.to_a)

      # Longer: the default node's step at 0.2 s now takes 50 ms
      MB::Sound::Notes.control_smoothing = 50.ms
      expect(default.smooth_time).to eq(50.ms)
      expect(own.smooth_time).to eq(10.ms)
      a = read(default, 14400)
      b = read(own, 14400)
      expect(b[(9600 - 4800 + 480)..].to_a.uniq).to eq([0.0])
      expect(a[9600 - 4800 + 1000]).to be > 0.5
      expect(a[(9600 - 4800 + 2400)..].to_a.uniq).to eq([0.0])

      # Off: exact steps
      MB::Sound::Notes.control_smoothing = false
      expect(default.smooth_time).to be_nil
      a = read(default, 9600)
      expect(a[(19200 - 19200)...(19200 - 19200 + 1)].to_a).to eq([1.0]) # 0.4 s: step on the sample
      expect(a[0..].to_a.uniq).to eq([1.0])

      # And adaptive
      MB::Sound::Notes.control_smoothing = :adaptive
      a = read(default, 9600)
      expect(a[(28800 - 28800 + 10)]).to be_between(0.5, 1.0)
    end

    it 'glides on from the current output when the default changes mid-glide' do
      v = notes_for(ev.cc_raw(1, 127, time: 0.01r))
      node = v.mod
      first = read(node, 480 + 200).dup
      MB::Sound::Notes.control_smoothing = 100.ms
      rest = read(node, 4000)
      expect(first[-1]).to be_between(0.2, 0.8)
      expect(rest[0]).to be_within(0.01).of(first[-1])
      expect(Numo::DFloat.cast(rest).diff.abs.max).to be < 0.01 # no jump
      expect(rest[-1]).to be < 1.0 # still gliding over 100 ms

      MB::Sound::Notes.control_smoothing = false
      expect(read(node, 1).to_a).to eq([1.0]) # off: the input at once
    end

    it 'follows bend_smoothing in #freq' do
      v = notes_for(ev.note_on(69, 1, time: 0r), ev.bend(1.0, time: 0.1r))
      f = v.freq
      read(f, 2400)
      MB::Sound::Notes.bend_smoothing = false
      out = read(f, 4800)
      expect(out[4800 - 2400 - 1]).to be_within(0.01).of(440)
      expect(out[4800 - 2400]).to be_within(0.01).of(493.883)
    end
  end

  describe 'defaults and options' do
    it 'smooths controllers, pressure, and poly pressure over 10 ms and bend over 5 ms' do
      v = notes_for
      [v.cc(20), v.mod, v.brightness, v.pressure, v.poly_pressure].each do |node|
        expect(node.smooth_time).to eq(0.01)
      end
      expect(v.bend.smooth_time).to eq(0.005)
      expect(v.bend_semitones(12).smooth_time).to eq(0.005)
      expect(v.aftertouch.poly.smooth_time).to eq(0.01)
    end

    it 'leaves note nodes and switch controllers on exact steps' do
      v = notes_for
      [v.gate, v.trigger, v.number, v.velocity, v.lift, v.choke].each do |node|
        expect(node.smooth_time).to be_nil
      end
      expect(v.portamento.smooth_time).to be_nil
      expect(v.portamento(smooth: 0.02).smooth_time).to eq(0.02)
    end

    it 'takes per-node times, true, false, and 0, and shares equal nodes' do
      v = notes_for
      expect(v.cc(1, smooth: 20.ms).smooth_time).to eq(20.ms)
      expect(v.cc(1, smooth: false).smooth_time).to be_nil
      expect(v.cc(1, smooth: 0).smooth_time).to be_nil
      expect(v.mod(smooth: true)).to equal(v.mod)
      expect(v.mod(smooth: false)).not_to equal(v.mod)
      expect(v.bend(smooth: false)).not_to equal(v.bend)
      expect(v.pressure(smooth: 0.02)).to equal(v.pressure(smooth: 0.02))
      expect(v.poly_pressure(smooth: false)).not_to equal(v.poly_pressure)
      expect { v.cc(1, smooth: -1) }.to raise_error(ArgumentError, /Smoothing/)
      expect { v.cc(2, smooth: :fast) }.to raise_error(ArgumentError, /Smoothing/)
    end

    it 'follows the global defaults for nodes made afterwards' do
      MB::Sound::Notes.control_smoothing = false
      MB::Sound::Notes.bend_smoothing = 2.ms
      v = notes_for
      expect(v.mod.smooth_time).to be_nil
      expect(v.bend.smooth_time).to eq(2.ms)
    end

    it 'smooths script controllers (ScriptRunner midi_cc)' do
      values = MB::Sound::ScriptRunner::Values.new(mix: 0.5)
      v = notes_for
      values.midi_source = -> { v }
      expect(values.midi_cc(7, :mix, range: 0.0..2.0).smooth_time).to eq(0.01)
      expect(values.midi_cc(8, :mix, range: 0.0..2.0, smooth: false).smooth_time).to be_nil
    end
  end

  describe 'output' do
    it 'reduces the zipper of a stepped pressure gesture' do
      stepped = read(notes_for(*gesture).pressure(smooth: false), 48000)
      smooth = read(notes_for(*gesture).pressure, 48000)
      fine = read(notes_for(*gesture).pressure(smooth: 5.ms), 48000)

      # Measured: stepped -54.5 / -65.2 dB, 10 ms -86.7 / -136.7, 5 ms -70 / -124
      expect(hf_db(smooth, 200)).to be < hf_db(stepped, 200) - 25
      expect(hf_db(smooth, 2000)).to be < hf_db(stepped, 2000) - 60
      expect(hf_db(fine, 2000)).to be < hf_db(stepped, 2000) - 45

      # The same gesture, delayed by half the time
      expect((smooth[1000...47000] - stepped[(1000 - 240)...(47000 - 240)]).abs.max).to be < 0.02
    end

    it 'with smooth: false steps on the event samples exactly as before' do
      events = [ev.cc_raw(1, 64, time: 0.01r), ev.cc_raw(1, 127, time: Rational(31, 1000)), ev.cc_raw(1, 3, time: 0.04r)]
      out = read(notes_for(*events).mod(smooth: false), 2400, [128, 300])
      expected = Numo::SFloat.zeros(2400)
      expected[480..] = 64 / 127.0
      expected[1488..] = 1.0
      expected[1920..] = 3 / 127.0
      expect(out.to_a).to eq(expected.to_a)
    end

    it 'gives the same samples with Notes fast paths off' do
      old = MB::Sound::Notes.fast_paths
      runs = [true, false].map { |fast|
        MB::Sound::Notes.fast_paths = fast
        v = notes_for(*gesture)
        read(v.pressure + v.mod * 0 + v.bend, 48000, [128, 300, 64])
      }
      expect(runs[0].to_a).to eq(runs[1].to_a)
    ensure
      MB::Sound::Notes.fast_paths = old
    end

    it 'returns the same frozen constant buffer, without extra allocations, once settled' do
      events = -> { [ev.cc_raw(1, 100, time: 0.001r), ev.bend(0.5, time: 0.001r), ev.channel_pressure(0.3, time: 0.001r)] }
      v = notes_for(*events.call)
      w = notes_for(*events.call) # its own stream, so stream reads count the same
      nodes = [v.mod, v.bend, v.pressure]
      plain = [w.mod(smooth: false), w.bend(smooth: false), w.pressure(smooth: false)]
      (nodes + plain).each { |n| 4.times { n.sample(512) } }

      nodes.zip(plain).each do |node, ref|
        a = node.sample(512)
        expect(a).to be_frozen
        expect(node.sample(512)).to equal(a)
        expect(a.to_a.uniq).to eq(ref.sample(512).to_a.uniq)
      end

      counts = [nodes, plain].map { |list|
        GC.start
        before = GC.stat(:total_allocated_objects)
        20.times { list.each { |n| n.sample(512) } }
        GC.stat(:total_allocated_objects) - before
      }
      expect(counts[0]).to be_within(2).of(counts[1]) # 60 reads each; GC noise
    end

    it 'takes the same time at any sample rate' do
      events = [ev.cc_raw(1, 127, time: 0.01r)]
      results = [48000, 96000, 44100].map { |rate|
        out = read(notes_for(*events, sample_rate: rate).mod, rate / 20)
        start = (0.01 * rate).floor
        done = (0...out.length).find { |i| out[i] == 1.0 }
        half = (0...out.length).find { |i| out[i] >= 0.5 }
        [(done - start) / rate.to_f, (half - start) / rate.to_f]
      }
      # A step completes one sample before the time (the kernel spans 10 ms)
      results.each do |done, half|
        expect(done).to be_within(2.5 / 44100).of(0.01)
        expect(half).to be_within(2.5 / 44100).of(0.005)
      end
    end

    it 'glides bend in #freq' do
      v = notes_for(ev.note_on(69, 1, time: 0r), ev.bend(1.0, time: 0.01r))
      f = read(v.freq, 2400)
      expect(f[479]).to be_within(0.01).of(440)
      expect(f[480 + 120]).to be_between(441, 493.88 - 1)
      expect(f[480 + 239]).to be_within(0.01).of(493.883)
    end

    it 'starts each poly pressure note at once but glides its pressure changes' do
      v = notes_for(
        ev.note_on(60, 1, time: 0r), ev.poly_pressure(60, 1.0, time: 0.01r),
        ev.note_on(64, 1, time: 0.05r), ev.poly_pressure(64, 0.5, time: 0.06r)
      )
      out = read(v.poly_pressure, 4800)
      expect(out[480 + 100]).to be_between(0.05, 0.95)
      expect(out[(480 + 478)...2400].to_a.uniq).to eq([1.0])
      expect(out[2400]).to eq(0.0) # the new note's 0 at its note-on
      expect(out[2880 + 120]).to be_between(0.05, 0.45)
      expect(out[(2880 + 478)..].to_a.uniq).to eq([0.5])
    end
  end
end
