require 'shellwords'

RSpec.describe('MB::Sound::FastUI', :aggregate_failures) do
  let(:fast) { MB::Sound::FastUI }
  let(:plot) { MB::Sound::Plot }
  let(:geometry) { MB::Sound::Plot::Geometry }

  # (fast_ui links mb-term's fast_term at load time: mb/term comes first)
  it 'loads when the GC runs at every allocation' do
    so = File.expand_path('../../../../lib/mb/sound/fast_ui.so', __dir__)
    code = 'require "bundler/setup"; require "numo/narray"; require "mb/term"; GC.stress = true; require ARGV[0]; GC.stress = false; p MB::Sound::FastUI::Grid.new(3, 2).width'
    out = `ruby -e #{code.shellescape} #{so.shellescape} 2>&1`

    expect($?).to be_success, out
    expect(out.lines.last.to_s.strip).to eq('3'), out
  end

  # Values with NaNs comparable by eq (NaN never equals NaN)
  def comparable(v)
    case v
    when Array then v.map { |e| comparable(e) }
    when Numo::NArray then [v.class, v.shape, comparable(v.to_a)]
    when Float then v.nan? ? :nan : v
    else v
    end
  end

  # Random device coordinates with NaN gaps, infinities, and values far
  # outside a raster
  def wild(rng, n, scale)
    Numo::DFloat.cast(Array.new(n) {
      case rng.rand(40)
      when 0 then Float::NAN
      when 1 then [Float::INFINITY, -Float::INFINITY].sample(random: rng)
      when 2 then rng.rand(-3e3..3e3)
      else rng.rand(-0.1 * scale..1.1 * scale)
      end
    })
  end

  describe '.decimate' do
    it 'matches Geometry.decimate_ruby for even and uneven x, with and without ends' do
      rng = Random.new(5)
      [[800, 58], [801, 58], [2048, 240], [97, 10], [5000, 3], [41, 20]].each do |n, cols|
        [true, false].each do |ends|
          ys = Numo::DFloat.cast(Array.new(n) { rng.rand(-20.0..20.0) })
          ys[rng.rand(n)] = Float::NAN if n > 50
          xs = Numo::DFloat.new(n).seq * (cols - 1).to_f / (n - 1)
          expect(comparable(fast.decimate(xs, ys, cols, true, ends))).to eq(comparable(geometry.decimate_ruby(xs, ys, cols, regular: true, ends: ends))), "regular n=#{n} ends=#{ends}"

          # Log-spaced x with repeats, a NaN group, and infinities
          lx = Numo::NMath.log10(Numo::DFloat.new(n).seq + 1) * (cols - 1) / Math.log10(n)
          lx[n / 2] = Float::NAN
          lx[-1] = Float::INFINITY
          lx[-2] = Float::INFINITY
          expect(comparable(fast.decimate(lx, ys, cols, false, ends))).to eq(comparable(geometry.decimate_ruby(lx, ys, cols, regular: false, ends: ends))), "irregular n=#{n} ends=#{ends}"
        end
      end
    end

    it 'keeps groups that are all NaN like numo min/max' do
      ys = Numo::DFloat[Float::NAN, Float::NAN, Float::NAN, 1, Float::NAN, 2, 3, 4, 5, 6, 7, 8]
      xs = Numo::DFloat.new(12).seq * 0.25
      [true, false].each do |reg|
        expect(comparable(fast.decimate(xs, ys, 3, reg, false))).to eq(comparable(geometry.decimate_ruby(xs, ys, 3, regular: reg, ends: false)))
      end
    end

    it 'returns nil for inputs it leaves to Ruby' do
      expect(fast.decimate(Numo::SFloat.new(100).seq, Numo::DFloat.new(100).seq, 10, true, false)).to be_nil
      expect(fast.decimate(Numo::DFloat.new(10).seq, Numo::DFloat.new(10).seq, 10, true, false)).to be_nil
      expect(fast.decimate(Numo::DFloat.new(200).seq[0..-1][(0..199) % 2], Numo::DFloat.new(100).seq, 10, true, false)).to be_nil
    end
  end

  describe '.polyline' do
    it 'draws the same dots as Raster#polyline_ruby' do
      rng = Random.new(9)
      [[1, 1], [2, 3], [120, 64], [17, 9], [240, 120]].each do |w, h|
        40.times do |k|
          n = [0, 1, 2, 3, 50, 400][k % 6]
          xs = wild(rng, n, w)
          ys = wild(rng, n, h)
          dash = [nil, [1, 2], [3, 1], [2, 2]][k % 4]
          a = plot::Raster.new(w, h)
          b = plot::Raster.new(w, h)
          expect(fast.polyline(a.dots, xs, ys, 7, dash ? dash[0] : 0, dash ? dash.sum : 0)).to eq(true)
          b.polyline_ruby(xs, ys, 7, dash: dash)
          expect(a.dots).to eq(b.dots), "#{w}x#{h} n=#{n} dash=#{dash.inspect}"
        end
      end
    end

    it 'leaves lines of more than 4M dots and other arrays to Ruby' do
      r = plot::Raster.new(10, 10)
      expect(fast.polyline(r.dots, Numo::DFloat[0, 5e6], Numo::DFloat[0, 0], 1, 0, 0)).to be_nil
      expect(r.dots.max).to eq(0)
      expect(fast.polyline(r.dots, Numo::SFloat[0, 5], Numo::DFloat[0, 0], 1, 0, 0)).to be_nil

      # The public method subsamples those the Ruby way
      a = plot::Raster.new(10, 10)
      b = plot::Raster.new(10, 10)
      a.polyline(Numo::DFloat[0, 5e6, 3], Numo::DFloat[0, 0, 9], 1)
      b.polyline_ruby(Numo::DFloat[0, 5e6, 3], Numo::DFloat[0, 0, 9], 1)
      expect(a.dots).to eq(b.dots)
    end

    it 'raises for dots that are not a 2D UInt16' do
      expect { fast.polyline(Numo::UInt8.zeros(3, 3), Numo::DFloat[0, 1], Numo::DFloat[0, 1], 1, 0, 0) }.to raise_error(ArgumentError, /UInt16/)
    end
  end

  describe '.area' do
    it 'fills like Surface#area_ruby' do
      rng = Random.new(3)
      look = plot::Text::LOOKS[:blocks]
      theme = plot::Theme[:dark]
      [[60, 14], [7, 3], [1, 1]].each do |cols, rows|
        30.times do |k|
          a = plot::Text::Surface.new(cols, rows, look, theme)
          b = plot::Text::Surface.new(cols, rows, look, theme)
          n = [2, 9, 300][k % 3]
          xs = wild(rng, n, a.width)
          ys = wild(rng, n, a.height)
          base = [0.0, a.height - 1.0, a.height / 2.0 + 0.5, -3.0, 1e9][k % 5]
          a.area(xs, ys, base, [200, 100, 50])
          b.area_ruby(xs, ys, base, [200, 100, 50])
          expect(a.raster.dots).to eq(b.raster.dots), "#{cols}x#{rows} n=#{n} base=#{base}"
          expect(a.raster.colors).to eq(b.raster.colors)
          expect(a.priorities).to eq(b.priorities)
        end
      end
    end
  end

  describe '.project' do
    it 'maps like Mark::Base#device_ruby on linear and log scales' do
      v = Numo::DFloat[-1e9, -2, -1, -0.5, 0, 1e-9, 0.25, 1, 7.5, 20, 440, 20000, Float::NAN, Float::INFINITY, -Float::INFINITY]
      surface = Struct.new(:width, :height).new(120, 64)
      mark = plot::Mark::Line.new(v)
      [
        plot::Scale::Linear.new(-1..1), plot::Scale::Symmetric.new(-0.5..0.5, reverse: true), plot::Scale::DB.new(-90..0),
        plot::Scale::Frequency.new(20..24000), plot::Scale::Log.new(0.1..100, reverse: true), plot::Scale::Time.new(0..1),
      ].each do |s|
        coord = plot::Coord::Cartesian.new(x: s, y: s)
        kind, lo, span, rev = s.projection
        expect(kind).not_to be_nil
        ux, uy = mark.send(:device_ruby, surface, coord, v, v)
        expect(comparable(fast.project(v, kind, lo, span, rev, 119, false))).to eq(comparable(ux)), s.inspect
        expect(comparable(fast.project(v, kind, lo, span, rev, 63, true))).to eq(comparable(uy)), s.inspect
      end
    end
  end

  describe '.monotonic' do
    it 'agrees with Geometry.monotonic_ruby' do
      [
        [], [1], [1, 2, 2, 3], [1, 0], [1, Float::NAN, 0], [Float::NAN, 1, 2], [1, Float::INFINITY, 2], [-0.0, 0.0], [3, 3, 2.9999],
      ].each do |a|
        x = Numo::DFloat.cast(a)
        expect(fast.monotonic(x)).to eq(geometry.monotonic_ruby(x)), a.inspect
      end
    end
  end

  describe MB::Sound::FastUI::Grid do
    let(:cells) { MB::Term::Cells }
    let(:native) { MB::Sound::Plot::Text::NativeCells }
    let(:modes) { %i[none truecolor ansi256 ansi16] }

    it 'is mb-term\'s native grid with #compose (the grid itself is specced in gems/mb-term/spec/native_spec.rb)' do
      expect(MB::Sound::FastUI::Grid.superclass).to equal(MB::Term::FastTerm::Grid)
      expect(native.ancestors).to include(MB::Term::NativeMethods, MB::Sound::FastUI::Grid)
      expect(MB::Term::Grid.native).to equal(native)
      g = native.new(4, 1)
      g.text(0, 0, 'ab', fg: [1, 2, 3])
      c = cells.new(4, 1)
      c.text(0, 0, 'ab', fg: [1, 2, 3])
      expect(g.frame(nil, :truecolor)).to eq(c.frame(nil, :truecolor))
    end

    it 'composes every canvas like Canvas.cells + Panel#compose' do
      rng = Random.new(8)
      wave = Numo::DFloat.cast(Array.new(500) { |i| Math.sin(i * 0.05) + rng.rand(-0.2..0.2) })
      charts = [
        plot.waveform([wave, -wave * 0.5], range: -1.5..1.5),
        plot.chart { line [1, 3, 2, 5], label: 'a'; area [0, 1, 0, 2], label: 'b'; points [2, 2, 4, 1], label: 'c' },
        plot.spectrogram(wave.concatenate(wave), fft: 64, hop: 32),
      ]
      plot::Text::LOOKS.each_key do |look|
        charts.each do |c|
          MB::Sound::Kernels.set(fast_ui: :c)
          a = plot::Text.render(c, width: 41, height: 12, look: look, color: :truecolor)
          MB::Sound::Kernels.set(fast_ui: :ruby)
          b = plot::Text.render(c, width: 41, height: 12, look: look, color: :truecolor)
          expect(a).to eq(b), "#{look} #{c.inspect}"
        end
      end
    end

    it 'checks sizes and arguments' do
      expect { native.new(-1, 2) }.to raise_error(ArgumentError)
      expect { native.new(3, 2).copy_from(native.new(2, 3)) }.to raise_error(ArgumentError)
      expect { native.new(3, 2).frame(native.new(2, 3), :none) }.to raise_error(ArgumentError)
      expect { native.new(3, 2).frame(Object.new, :none) }.to raise_error(TypeError)
      expect { native.new(3, 2).compose(Numo::UInt16.zeros(2, 3), 0, 2, 4, 0, 0, 3, 2, Numo::Int32[0], Numo::Int32[-1], plot::Text::Canvas::TABLES[:braille]) }.to raise_error(ArgumentError)
      g = native.new(4, 2)
      dots = Numo::UInt16.zeros(8, 8)
      dots[3] = 5
      expect { g.compose(dots, 0, 2, 4, 0, 0, 4, 2, Numo::Int32[0], Numo::Int32[-1], plot::Text::Canvas::TABLES[:braille]) }.to raise_error(IndexError)
    end
  end

  describe 'GVLProbe' do
    let(:probe) { MB::Sound::FastUI::GVLProbe }

    after { probe.stop }

    it 'records GVL waits and holds of watched threads, and who held the GVL for long waits' do
      waiter = Thread.new { 20.times { sleep 0.002; 2000.times { } } }
      probe.start([waiter, Thread.current])
      expect(probe).to be_active
      # Hold the GVL for a few ms at a time so the waiter waits on wakeups
      t = MB::U.clock_now
      while MB::U.clock_now - t < 0.15 && waiter.alive?
        u = MB::U.clock_now
        nil while MB::U.clock_now - u < 0.003
        Thread.pass
      end
      waiter.join
      probe.stop
      expect(probe).not_to be_active

      waits = probe.waits(0)
      expect(waits.length).to be_between(1, 21)
      expect(waits).to all(be >= 0)
      expect(probe.holds(1)).not_to be_empty
      blockers = probe.blockers(0)
      expect(blockers).to all(match([be >= 0.001, be_between(-1, 1)]))
      expect(blockers.map(&:last)).to include(1) unless blockers.empty?
    end

    it 'checks its arguments' do
      expect { probe.start([]) }.to raise_error(ArgumentError, /1 to 6 threads/)
      expect { probe.start([Thread.current] * 7) }.to raise_error(ArgumentError)
      expect { probe.start([1]) }.to raise_error(TypeError)
      probe.start([Thread.current])
      expect { probe.waits(1) }.to raise_error(IndexError, /No GVLProbe slot 1/)
      expect(probe.waits(0)).to eq([])
    end

    describe 'log' do
      after {
        probe.log_stop
        probe.log_drain
      }

      it 'timestamps long waits for the GVL, times blocked off it, and GC steps with the thread that ran them' do
        probe.log_drain
        sleeper = Thread.new { sleep 0.01; MB::Sound::FastLatency.spin(0.0001) }
        probe.start([sleeper, Thread.current])
        probe.log_start(0.001, 0.0)
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        # (the sleeper wakes while this thread holds the GVL for 20 ms)
        sleep 0.005
        MB::Sound::FastLatency.spin(0.02)
        sleeper.join
        GC.start
        probe.log_stop
        log = probe.log_drain
        t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)

        mine = log.select { |kind, slot, *| kind == :thread && slot == 0 }
        expect(mine).not_to be_empty
        blocked = mine.find { |_, _, _, a, b, _| a > 0 && b - a >= 8_000_000 }
        expect(blocked).not_to be_nil # (the sleep)
        waited = mine.find { |_, _, _, _, b, c| c - b >= 5_000_000 }
        expect(waited).not_to be_nil
        expect(waited[2]).to eq(1) # (held by this thread)
        mine.each { |_, _, _, a, b, c| expect([a, b, c].reject(&:zero?)).to all(be_between(t0 - 20_000_000, t1)) }

        gc = log.select { |kind, *| kind == :gc }
        expect(gc).not_to be_empty
        expect(gc.map { |r| r[1] }).to include(1)
        gc.each { |_, _, _, a, b, c, count| expect([b >= a, c, count >= 1]).to eq([true, 0, true]) }
        expect(probe.log_stats).to include(on: false, lost: 0)
        expect(probe.log_stats[:gc_steps]).to be >= gc.length
      end

      # (a subprocess: YJIT is off in specs, and the ring is sized once)
      it 'checks its size, and keeps YJIT code while its GC hook runs (an internal TracePoint)' do
        code = <<~RUBY
          require 'bundler/setup'
          require 'mb-sound'
          def hot(n) = (0...n).sum { |i| i * 2 }
          300.times { hot(100) }
          begin
            MB::Sound::FastUI::GVLProbe.log_start(0.001, 0.0, 4)
          rescue ArgumentError => e
            puts e.message
          end
          MB::Sound::FastUI::GVLProbe.log_start(0.001, 0.0)
          GC.start
          300.times { hot(100) }
          MB::Sound::FastUI::GVLProbe.log_stop
          gc = MB::Sound::FastUI::GVLProbe.log_drain.count { |r| r[0] == :gc }
          p [gc > 0, RubyVM::YJIT.runtime_stats[:invalidate_everything]]
        RUBY
        out = IO.popen(['ruby', '--yjit', '--yjit-stats=quiet', '-e', code], err: [:child, :out], &:read)
        expect($?).to be_success, out
        expect(out).to include('holds 16 to 16777216 records (got 4)')
        expect(out.lines.last.strip).to eq('[true, 0]'), out
      end
    end
  end
end
