RSpec.describe(MB::Sound::Plot::Live, :aggregate_failures) do
  let(:plot) { MB::Sound::Plot }
  let(:looks) { MB::Sound::Plot::Text::LOOKS.keys }
  let(:modes) { %i[truecolor ansi256 ansi16 none] }

  around do |example|
    old = MB::Sound::Plot.native
    example.run
  ensure
    MB::Sound::Plot.native = old
  end

  # Charts of every mark kind, scale kind, and layout feature
  def corpus
    rng = Random.new(7)
    t = Numo::DFloat.new(800).seq / 48000
    saw = (t * 220 % 1.0) - 0.5
    sine = Numo::NMath.sin(t * 2 * Math::PI * 330) * 0.7
    noisy = sine + Numo::DFloat.cast(Array.new(800) { rng.rand(-0.1..0.1) })
    noisy[400] = Float::NAN
    [
      plot.waveform([saw, sine], range: -1.0..1.0),
      plot.waveform(noisy),
      plot.waveform(saw, fill: true, title: 'filled'),
      plot.spectrum(sine + saw * 0.01, range: -90..0, floor: -90),
      plot.spectrum([saw, sine]),
      plot.spectrogram(Numo::DFloat.cast(Array.new(9600) { |i| Math.sin(i * i * 1e-5) }), fft: 256, hop: 128),
      plot.envelope(Numo::DFloat.linspace(0, 1, 300) ** 2),
      plot.chart(title: 'marks') {
        x :linear, 0..10
        line [0, 3, 1, 4, 1, 5, 9, 2, 6, 5, 3], label: 'step', step: true
        points [5, 3, 5, 8, 9, 7, 9, 3, 2, 3, 8], label: 'pts'
        stems [1, -2, 3, -4, 5, -6, 7, -8, 9, -10, 1], label: 'stems'
        band [-3, -2, -1, 0, 1, 2, 1, 0, -1, -2, -3], [0, 1, 2, 3, 4, 5, 4, 3, 2, 1, 0], label: 'band'
        area [1, 2, 3, 2, 1, 2, 3, 2, 1, 2, 3], label: 'area', base: 0.0
        line [2] * 11, dash: [2, 2], label: 'dashed'
        rule y: -6, dash: [2, 2]
      },
      plot.chart(title: 'polar') {
        polar
        line Numo::DFloat.linspace(0, 1, 200), x: 0..1
      },
      plot.figure(title: 'two panels') {
        chart(title: 'a') { line [1, 2, 3] }
        chart(title: 'b') { x :frequency, 20..20000, notes: true; line [1, 2, 3, 2], x: [100, 1000, 5000, 15000] }
      },
    ]
  end

  it 'draws exactly what Plot::Text.render draws, with the C kernels and their Ruby mirrors' do
    charts = corpus
    # (every color mode for two looks, two for the rest: color codes are
    # the same for every look)
    [[60, 16], [37, 11]].each do |w, h|
      looks.each do |look|
        modes.each do |mode|
          next if look == :ascii && mode != :none
          next if !%i[scope blocks].include?(look) && !%i[truecolor none].include?(mode)

          native = charts.map { |c| plot.native = true; plot::Text.render(c, width: w, height: h, look: look, color: mode) }
          ruby = charts.map { |c| plot.native = false; plot::Text.render(c, width: w, height: h, look: look, color: mode) }
          charts.each_index do |i|
            expect(native[i]).to eq(ruby[i]), "chart #{i} #{w}x#{h} #{look} #{mode}"
          end

          [true, false].each do |nat|
            plot.native = nat
            live = described_class.new(width: w, height: h, look: look, color: mode)
            # Each chart twice (the second reuses the layout), in order
            (charts + charts.reverse).each do |c|
              expect(live.redraw(c)).to eq(ruby[charts.index(c)].join("\n")), "live #{c.inspect} #{w}x#{h} #{look} #{mode} native=#{nat}"
            end
          end
        end
      end
    end
  end

  it 'reuses the layout while scales and titles stay the same' do
    live = described_class.new(width: 60, height: 16, look: :scope, color: :none)
    5.times { |k| live.redraw(plot.waveform(Numo::DFloat.new(800).rand(-1, 1) * 0.3 * k, range: -1.0..1.0)) }
    expect(live.layouts).to eq(1)

    # A fitted scale changes with the data: a new layout when its domain does
    live.redraw(plot.waveform(Numo::DFloat[0.1, -0.1, 0.1]))
    live.redraw(plot.waveform(Numo::DFloat[0.1, -0.1, 0.1]))
    expect(live.layouts).to eq(2)
    live.redraw(plot.waveform(Numo::DFloat[3, -3, 3]))
    expect(live.layouts).to eq(3)

    live.redraw(plot.waveform(Numo::DFloat[3, -3, 3], title: 'other'))
    expect(live.layouts).to eq(4)
    expect(live.inspect).to include('60x16', 'scope', '4 layouts')
  end

  # Replays terminal bytes (cursor moves, SGR, synchronized output) onto a
  # screen of characters and returns its rows
  def replay(screen, bytes)
    s = bytes.dup.force_encoding('UTF-8')
    row = col = 0
    i = 0
    while i < s.length
      if s[i] == "\e"
        m = s[i..].match(/\A\e\[(\??)([\d;]*)([A-Za-z])/)
        raise "bad escape at #{i}: #{s[i, 10].inspect}" unless m

        if m[3] == 'H'
          r, c = m[2].split(';').map(&:to_i)
          row = r - 1
          col = c - 1
        end
        i += m[0].length
      else
        screen[row][col] = s[i]
        col += 1
        i += 1
      end
    end
    screen
  end

  it 'sends only changed cells that rebuild the screen exactly' do
    [true, false].each do |nat|
      plot.native = nat
      look = :scope
      live = described_class.new(width: 50, height: 12, look: look, color: :truecolor)
      plain = described_class.new(width: 50, height: 12, look: look, color: :none)
      screen = Array.new(14) { ' ' * 60 }
      sizes = []
      8.times do |k|
        d = Numo::DFloat.new(800).seq.map { |j| Math.sin(j * 0.02 + k * 0.4) * 0.8 }
        chart = plot.waveform([d, d * 0.5], range: -1.0..1.0)
        bytes = live.frame(chart, row: 2, col: 3)
        sizes << bytes.bytesize
        expect(bytes).to start_with("\e[?2026h").and end_with("\e[?2026l")
        replay(screen, bytes)
        expected = plain.lines(chart)
        expect(screen[1, 12].map { |r| r[2, 50] }).to eq(expected), "frame #{k} native=#{nat}"
      end
      expect(sizes[1..].max).to be < sizes[0]

      # The same chart again: nothing to send but the frame markers
      d = Numo::DFloat.new(800).seq.map { |j| Math.sin(j * 0.02 + 7 * 0.4) * 0.8 }
      expect(live.frame(plot.waveform([d, d * 0.5], range: -1.0..1.0), row: 2, col: 3)).to eq("\e[?2026h\e[0m\e[?2026l")
      live.invalidate
      fresh = described_class.new(width: 50, height: 12, look: look, color: :truecolor)
      chart = plot.waveform([d, d * 0.5], range: -1.0..1.0)
      expect(live.frame(chart, row: 2, col: 3, sync: false)).to eq(fresh.frame(chart, row: 2, col: 3, sync: false))
      expect(live.frame(chart, row: 2, col: 3, full: true)).to eq(fresh.frame(chart, row: 2, col: 3, full: true))
    end
  end

  it 'writes frames to an IO' do
    [true, false].each do |nat|
      plot.native = nat
      live = described_class.new(width: 30, height: 8, look: :blocks, color: :ansi256)
      other = described_class.new(width: 30, height: 8, look: :blocks, color: :ansi256)
      chart = plot.waveform(Numo::DFloat.new(100).seq.map { |j| Math.sin(j * 0.1) }, range: -1.0..1.0)
      r, w = IO.pipe
      n = live.write(w, chart, row: 4)
      w.close
      bytes = r.read
      r.close
      expect(n).to eq(bytes.bytesize)
      expect(bytes.force_encoding('UTF-8')).to eq(other.frame(chart, row: 4))
    end
  end
end
