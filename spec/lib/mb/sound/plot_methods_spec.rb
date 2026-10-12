# Plots are drawn by MB::Sound::Plot (no gnuplot process), so their text is
# deterministic: these examples use the plain ASCII look at 80x40 for
# structural checks (see spec/lib/mb/sound/plot/ for each renderer).
RSpec.describe(MB::Sound::PlotMethods) do
  before(:each) do
    MB::Sound.close_plotter
    MB::Sound.plotter(width: 80, height: 40, look: :ascii, color: :none).print = false
  end

  after(:each) do
    MB::Sound.close_plotter
  end

  let(:tone) { 357.2.hz.gauss }

  let(:lines) { output.map(&MB::U.method(:remove_ansi)) }
  let(:text) { lines.join("\n") }

  # The data area of the single (or first) chart: the lines between the
  # header and the x axis, right of the y axis (ASCII look).
  def plot_area(lines)
    axis = lines.index { |l| l.match?(/\+[-+]{10,}/) }
    col = lines[axis].index('+')
    lines[1...axis].map { |l| l[(col + 1)..].to_s }
  end

  # [row, column] of the highest drawn point in an area, as fractions of
  # its height (0 at the top) and width.
  def peak(area)
    row = area.index { |l| l.match?(/\S/) }
    col = area[row].index(/\S/)
    [row / area.length.to_f, col / area[row].length.to_f]
  end

  def check_size(lines)
    expect(lines.length).to eq(40)
    expect(lines.map(&:length).max).to be <= 80
  end

  describe '#hist' do
    let(:output) { MB::Sound.hist(tone.sample(5 * 48000)) }

    it 'draws a histogram peaking in the middle' do
      check_size(lines)
      row, col = peak(plot_area(lines))
      expect(row).to be < 0.1
      expect(col).to be_between(0.3, 0.7)
    end
  end

  describe '#density' do
    it 'estimates a probability density over bin centers' do
      x, d = MB::Sound.density(Numo::SFloat[-1, -0.5, 0.25, 0.75, 2], bins: 4, range: -1..1)
      expect(x.to_a).to eq([-0.75, -0.25, 0.25, 0.75])
      # 4 of 5 values inside, bins 0.5 wide: 1 / (5 * 0.5) in each bin
      expect(d.to_a).to eq([0.4, 0.4, 0.4, 0.4])
    end

    it 'integrates to 1 for uniform noise' do
      _, d = MB::Sound.density(1.hz.ramp.noise.sample(48000), bins: 20, range: -1..1)
      expect(d.sum * 0.1).to be_within(1e-9).of(1)
      expect(d).to all_be_within(0.05).of_array(Numo::DFloat.new(20).fill(0.5))
    end
  end

  describe '#hist with a density' do
    let(:arcsine) { ->(x) { x.abs < 1 ? 1 / (Math::PI * Math.sqrt(1 - x * x)) : 0 } }
    let(:output) { MB::Sound.hist({ 'sine' => 1.hz.sine.noise.sample(48000) }, bins: 40, pdf: arcsine) }

    it 'draws the estimate with the theory over it, with a legend' do
      check_size(lines)
      expect(lines[0]).to start_with('sine')
      expect(lines[0]).to include('-- estimate', '-- theory')
    end
  end

  describe '#overlay' do
    let(:output) {
      MB::Sound.overlay({
        'a_b' => { 'line_1' => [[0, 0], [1, 1]], 'line 2' => [Numo::DFloat[0, 1], Numo::DFloat[1, 0]] },
        'c' => { 'flat' => [[0, 0.5], [1, 0.5]] },
      })
    }

    it 'plots several curves per pane with legends, keeping underscores in titles' do
      check_size(lines)
      expect(text).to include('a_b', 'line_1', 'line 2', 'flat')
      expect(lines.count { |l| l.match?(/\+[-+]{20,}/) }).to eq(2)
    end
  end

  describe '#mag_phase' do
    context 'with a tone' do
      let(:output) { MB::Sound.mag_phase(440.hz.sine) }

      it 'includes both magnitude and phase graphs' do
        check_size(lines)
        expect(text).to include('0 mag', '0 phase')
      end
    end

    context 'with a filter' do
      let(:output) { MB::Sound.mag_phase(5000.hz.lowpass) }

      it 'can plot a Filter on a frequency axis in Hz with note names' do
        check_size(lines)
        expect(text).to include('frequency (Hz)', '1k', 'C5')
      end
    end

    context 'with a complex-valued filter' do
      let(:output) { MB::Sound.mag_phase(MB::Sound::Filter::HilbertIIR.new) }

      it 'can plot a complex-output Filter' do
        check_size(lines)
      end
    end
  end

  describe '#time_freq' do
    context 'with a tone' do
      let(:output) { MB::Sound.time_freq(tone) }

      it 'includes both time and frequency graphs' do
        check_size(lines)
        expect(text).to include('0 time', '0 freq')
        expect(text).to include('frequency (Hz)', '1k', 'C5') # frequencies in Hz (omnibus6), not bins
      end
    end

    context 'with a filter' do
      let(:output) { MB::Sound.time_freq(5000.hz.lowpass) }

      it 'can plot a Filter' do
        check_size(lines)
      end
    end

    context 'with a complex filter' do
      let(:output) { MB::Sound.time_freq(MB::Sound::Filter::HilbertIIR.new) }

      it 'can plot a complex-output Filter' do
        check_size(lines)
      end
    end
  end

  describe '#spectrum' do
    context 'with a sine wave' do
      let(:output) { MB::Sound.spectrum(400.hz.sine, samples: 1200) }

      # Formerly flaky: gnuplot's end marker sometimes leaked into the
      # captured lines (2026-10-11); the output is now deterministic
      it 'peaks at the sine on a log frequency axis' do
        expect(MB::Sound).to receive(:puts).with(/Plotting/).twice
        check_size(lines)
        expect(output).to eq(MB::Sound.spectrum(400.hz.sine, samples: 1200))

        # 400 Hz is bin 10 of 600 (40 Hz bins); the x axis is log from bin 1
        _, col = peak(plot_area(lines))
        expect(col).to be_within(0.04).of(Math.log10(10) / Math.log10(600))
        expect(text).to include('frequency (Hz)', '200', '500', 'C5')
      end
    end

    context 'with a gauss wave' do
      let(:output) { MB::Sound.spectrum(480.hz.gauss.at(0.1), samples: 800) }

      it 'can plot the spectrum of a more complex wave' do
        expect(MB::Sound).to receive(:puts).with(/Plotting/)
        check_size(lines)
        _, col = peak(plot_area(lines))
        expect(col).to be_within(0.04).of(Math.log10(8) / Math.log10(400))
      end
    end
  end

  describe '#plot' do
    context 'with a tone' do
      let(:output) { MB::Sound.plot(tone) }

      it 'can plot a Tone' do
        expect(MB::Sound).to receive(:puts).with(/Plotting.*Tone/m)
        check_size(lines)
      end
    end

    context 'with a sound file' do
      let(:output) { MB::Sound.plot('sounds/synth0.flac') }

      it 'plots each channel in its own panel' do
        expect(MB::Sound).to receive(:puts).with(/Plotting.*synth0.flac/m)
        check_size(lines)
        expect(lines.count { |l| l.match?(/\+[-+]{10,}/) }).to eq(2)
        expect(lines.grep(/^0 /).length).to eq(1)
        expect(lines.grep(/^1 /).length).to eq(1)
        expect(lines.grep(/^2 /)).to be_empty
      end
    end

    context 'with a Numo::NArray' do
      let(:output) { MB::Sound.plot(tone.sample(800)) }

      it 'can plot a Numo::NArray' do
        expect(MB::Sound).to receive(:puts).with(/Plotting.*Numo/m)
        check_size(lines)
        expect(lines[0]).to match(/^0\b/)
        expect(lines.count { |l| l.match?(/\+[-+]{10,}/) }).to eq(1)
      end
    end

    context 'with multiple sounds' do
      let(:output) { MB::Sound.plot([123.hz.sine, 123.hz.ramp, 123.hz.triangle, 123.hz.gauss]) }

      it 'can plot an array of different sounds in a 2x2 grid' do
        expect(MB::Sound).to receive(:puts).with(/Plotting.*[^\e]\[/m)
        check_size(lines)
        expect(lines.count { |l| l.scan(/\+[-+]{10,}/).length == 2 }).to eq(2)
      end
    end

    it 'can plot an entire sound in a loop when :all is true' do
      # The loop advances by elapsed time, capped at 0.1s (4800 samples) per
      # frame, so the sound must be longer than 2 * 4800 samples to take at
      # least 3 frames when frames are slow (e.g. under full-suite load).
      expect(MB::Sound).to receive(:sleep).at_least(3).times
      expect(MB::Sound).to receive(:puts).at_least(2).times
      expect(STDOUT).to receive(:write).at_least(2).times
      lines = MB::Sound.plot(123.hz.sine.sample(14400), all: true, samples: 800)
      expect(lines.length).to eq(40)
    end

    it 'can plot a Filter' do
      expect(MB::Sound).to receive(:puts).with(/Plotting.*Filter/m)
      lines = MB::Sound.plot(5000.hz.lowpass)
      expect(lines.length).to eq(40)
    end

    it 'can plot a Hilbert transform filter with a complex output' do
      expect(MB::Sound).to receive(:puts)
      lines = MB::Sound.plot(MB::Sound::Filter::HilbertIIR.new)
      expect(lines.length).to eq(40)
    end

    it 'can plot complex-valued audio data' do
      expect(MB::Sound).to receive(:puts)
      lines = MB::Sound.plot(123.hz.complex_sine)
      expect(lines.length).to eq(40)
    end
  end

  describe '#spectrogram' do
    let(:output) { MB::Sound.spectrogram(440.hz.ramp, seconds: 0.5, fft: 1024) }

    it 'shades a spectrogram with a colorbar when there is no color' do
      check_size(lines)
      expect(lines[0]).to start_with('spectrogram')
      expect(text).to include('Hz', 'time (ms)')
      expect(text).to match(/[░▒▓█]{10}/)
    end

    it 'reads files' do
      lines = MB::Sound.spectrogram('sounds/synth0.flac')
      expect(lines[0]).to start_with('synth0.flac')
    end
  end

  describe '#chart' do
    it 'builds a chart from a block' do
      c = MB::Sound.chart(title: 'ramp') { line [0, 1, 2, 3], label: 'up' }
      expect(c).to be_a(MB::Sound::Plot::Chart)
      expect(c.lines(width: 40, height: 10, look: :ascii).length).to eq(10)
    end
  end

  describe '#figure' do
    it 'lays out charts' do
      f = MB::Sound.figure(columns: 2) { chart { line [1, 2] }; chart { line [2, 1] } }
      expect(f.columns).to eq(2)
      expect(f.lines(width: 60, height: 10, look: :ascii).first.length).to eq(60)
    end
  end

  describe '#table' do
    it 'can display an evaluated method call' do
      expect(MB::Util).to receive(:puts).with(/[|+]/).exactly(23).times
      MB::Sound.table(CMath.method(:acos))
    end

    it 'can display a proc' do
      expect(MB::Util).to receive(:puts).with(/[|+]/).exactly(2).times
      expect(MB::Util).to receive(:puts).with(/15151/).exactly(21).times
      MB::Sound.table(->(x){15151})
    end

    it 'can display an NArray' do
      expect(MB::Util).to receive(:puts).with(/[|+]/).exactly(2).times
      expect(MB::Util).to receive(:puts).with(/50/)
      expect(MB::Util).to receive(:puts).with(/40/)
      expect(MB::Util).to receive(:puts).with(/30/)
      expect(MB::Util).to receive(:puts).with(/20/)
      expect(MB::Util).to receive(:puts).with(/10/)
      MB::Sound.table(Numo::Int32[50, 40, 30, 20, 10], steps: 5)
    end

    it 'can display complex numbers' do
      expect(MB::Util).to receive(:puts).with(/#.*0/)
      expect(MB::Util).to receive(:puts).with(/-\+-/)
      expect(MB::Util).to receive(:puts).with(/5.*1.*-.*1.*i/)
      expect(MB::Util).to receive(:puts).with(/6.*1.*-.*1.*i/)
      MB::Sound.table([1-1i], range: 5..6, steps: 2)
    end

    it 'can use a custom range and steps' do
      expect(MB::Util).to receive(:puts).with(/[|+]/).exactly(2).times
      expect(MB::Util).to receive(:puts).with(/-2.5.*20/)
      expect(MB::Util).to receive(:puts).with(/-1.5.*30/)
      MB::Sound.table([20, 30], range: -3..-2, steps: [-2.5, -1.5])
    end

    it 'can display multiple columns' do
      expect(MB::Util).to receive(:puts).with(/[|+]/).exactly(2).times
      expect(MB::Util).to receive(:puts).with(/.+\|.+\|.+/).exactly(21).times
      MB::Sound.table([CMath.method(:acos), CMath.method(:asin)])
    end
  end
end
