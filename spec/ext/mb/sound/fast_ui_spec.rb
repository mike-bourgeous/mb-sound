require 'shellwords'

RSpec.describe('MB::Sound::FastUI', :aggregate_failures) do
  let(:fast) { MB::Sound::FastUI }
  let(:plot) { MB::Sound::Plot }
  let(:geometry) { MB::Sound::Plot::Geometry }

  around do |example|
    old = MB::Sound::Plot.native
    MB::Sound::Plot.native = true
    example.run
  ensure
    MB::Sound::Plot.native = old
  end

  it 'loads when the GC runs at every allocation' do
    so = File.expand_path('../../../../lib/mb/sound/fast_ui.so', __dir__)
    code = 'require "bundler/setup"; require "numo/narray"; GC.stress = true; require ARGV[0]; GC.stress = false; p MB::Sound::FastUI::Grid.new(3, 2).width'
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
    let(:cells) { MB::Sound::Plot::Text::Cells }
    let(:native) { MB::Sound::Plot::Text::NativeCells }
    let(:modes) { %i[none truecolor ansi256 ansi16] }

    # The same random edits on Ruby Cells and NativeCells
    def edit_both(a, b, rng, count)
      colors = [nil, [255, 0, 0], [0, 0, 0], [138, 138, 133], [95, 135, 175], [8, 8, 8], [254, 254, 254], [17, 168, 205]]
      chars = [' ', 'a', '⠿', '█', '▀', '│', '🬀', 'µ']
      count.times do
        x = rng.rand(-2..a.width + 1)
        y = rng.rand(-2..a.height + 1)
        if rng.rand(3) == 0
          str = Array.new(rng.rand(0..12)) { chars.sample(random: rng) }.join
          fg = colors.sample(random: rng)
          bold = rng.rand(2) == 0
          max = [nil, 3].sample(random: rng)
          a.text(x, y, str, fg: fg, bold: bold, max: max)
          b.text(x, y, str, fg: fg, bold: bold, max: max)
        else
          ch = chars.sample(random: rng)
          fg = colors.sample(random: rng)
          bg = colors.sample(random: rng)
          bold = rng.rand(2) == 0
          rev = rng.rand(3) == 0
          a.set(x, y, ch, fg: fg, bg: bg, bold: bold, reverse: rev)
          b.set(x, y, ch, fg: fg, bg: bg, bold: bold, reverse: rev)
        end
      end
    end

    it 'gives the same lines, text, and characters as Cells in every color mode' do
      rng = Random.new(11)
      [[1, 1], [10, 4], [61, 17]].each do |w, h|
        a = cells.new(w, h)
        b = native.new(w, h)
        edit_both(a, b, rng, w * h)
        modes.each do |m|
          expect(b.lines(m)).to eq(a.lines(m)), "#{w}x#{h} #{m}"
          expect(b.to_text(m)).to eq(a.to_text(m))
        end
        expect(b.char(w - 1, h - 1)).to eq(a.char(w - 1, h - 1))
        expect(b.lines(:truecolor).first.encoding).to eq(Encoding::UTF_8)
      end
    end

    it 'maps every color like Plot::Text::ANSI' do
      rng = Random.new(2)
      a = cells.new(64, 4)
      b = native.new(64, 4)
      64.times do |x|
        4.times do |y|
          rgb = Array.new(3) { [0, 1, 7, 8, 9, 94, 95, 96, 114, 115, 116, 255, rng.rand(256)].sample(random: rng) }
          a.set(x, y, 'x', fg: rgb, bg: rgb.reverse)
          b.set(x, y, 'x', fg: rgb, bg: rgb.reverse)
        end
      end
      %i[ansi256 ansi16].each { |m| expect(b.lines(m)).to eq(a.lines(m)) }
    end

    it 'encodes frames (full and changed cells) like Cells#frame' do
      rng = Random.new(4)
      [[1, 1], [12, 5], [60, 16]].each do |w, h|
        a = cells.new(w, h)
        b = native.new(w, h)
        pa = cells.new(w, h)
        pb = native.new(w, h)
        6.times do |k|
          edit_both(a, b, rng, k == 0 ? w * h : rng.rand(w * 2))
          modes.each do |m|
            [[nil, nil], [pa, pb]].each do |prev_a, prev_b|
              [true, false].each do |sync|
                fa = a.frame(prev_a, m, row: 3, col: 7, sync: sync)
                fb = b.frame(prev_b, m, row: 3, col: 7, sync: sync)
                expect(fb).to eq(fa), "#{w}x#{h} frame #{k} #{m} diff=#{!prev_a.nil?} sync=#{sync}"
              end
            end
          end
          pa.copy_from(a)
          pb.copy_from(b)
        end
        expect(b.frame(pb, :truecolor)).to eq("\e[?2026h\e[0m\e[?2026l")
      end
    end

    it 'writes frames without the GVL' do
      g = native.new(20, 3)
      g.text(0, 1, 'hello ⠿ world', fg: [255, 128, 0])
      r, w = IO.pipe
      n = g.write_frame(w, nil, :truecolor, row: 2, col: 1)
      w.close
      bytes = r.read
      expect(n).to eq(bytes.bytesize)
      expect(bytes.force_encoding('UTF-8')).to eq(g.frame(nil, :truecolor, row: 2, col: 1))
    ensure
      r&.close
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
          plot.native = true
          a = plot::Text.render(c, width: 41, height: 12, look: look, color: :truecolor)
          plot.native = false
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
end
