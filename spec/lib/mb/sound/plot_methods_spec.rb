RSpec.describe(MB::Sound::PlotMethods) do
  before(:each) do
    ENV['PLOT_TERMINAL'] = 'dumb'
    ENV['PLOT_WIDTH'] = '80'
    ENV['PLOT_HEIGHT'] = '40'
    MB::Sound.close_plotter
    MB::Sound.plotter(width: 80, height: 40).print = false
  end

  after(:each) do
    ENV.delete('PLOT_TERMINAL')
    ENV.delete('PLOT_WIDTH')
    ENV.delete('PLOT_HEIGHT')
    MB::Sound.close_plotter
  end

  let(:tone) { 357.2.hz.gauss }

  let(:lines) { output.map(&MB::U.method(:remove_ansi)).map(&:rstrip) }
  let(:text) { lines.join("\n").lstrip }

  # Makes sure the regex matches a full line and isn't accidentally matching a
  # zero-width string and isn't matching across lines
  def check_regex(example, lines, text, regex)
    expect(text).to match(regex)
    match = text.match(regex).to_s
    expect(match).not_to include("\n")
    expect(match.length).to be_between(70, 80)

  rescue Exception => e
    # Trying to find out why sometimes a line starts with \n
    #
    # It looks like the plot output has a blank line randomly mixed in and the
    # line moves around from place to place.  The newline error happens when
    # that blank line ends up right before the line we want to match.
    raise e.class, "#{e.message}\n\t\e[1m#{lines.map(&:inspect).join("\n\t")}\e[0m"
  end

  describe '#hist' do
    let(:output) { MB::Sound.hist(tone.sample(5 * 48000)) }

    it 'can draw a histogram' do |ex|
      expect(lines.length).to eq(40)
      check_regex(ex, lines, text, /^\s*1000 \|-\+\s+\* {5,10}\*.*\|$/)
      check_regex(ex, lines, text, /^\s*200 \|-\+\s+\* {15,25}\*.*\|$/)
    rescue Exception => e
      raise e.class, "#{e.message}\n\t\e[1m#{lines.map(&:inspect).join("\n\t")}\e[0m"
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

    it 'draws the estimate with the theory over it' do
      expect(text).to include('sine', 'estimate', 'theory')
      expect(lines.length).to be_between(38, 41)
    rescue Exception => e
      raise e.class, "#{e.message}\n\t\e[1m#{lines.map(&:inspect).join("\n\t")}\e[0m"
    end
  end

  describe '#overlay' do
    let(:output) {
      MB::Sound.overlay({
        'a_b' => { 'line_1' => [[0, 0], [1, 1]], 'line 2' => [Numo::DFloat[0, 1], Numo::DFloat[1, 0]] },
        'c' => { 'flat' => [[0, 0.5], [1, 0.5]] },
      })
    }

    it 'plots several curves per pane, keeping underscores in titles' do
      expect(text).to include('a_b', 'line_1', 'line 2', 'flat')
      expect(text.lines.count { |l| l.match?(/\+-{20,}\+/) }).to eq(4)
    end
  end

  describe '#mag_phase' do
    context 'with a tone' do
      let(:output) { MB::Sound.mag_phase(440.hz.sine) }

      it 'includes both magnitude and phase graphs' do
        expect(lines.length).to eq(40)
        expect(text).to include('mag **')
        expect(text).to include('phase **')
      rescue Exception => e
        raise e.class, "#{e.message}\n\t\e[1m#{lines.map(&:inspect).join("\n\t")}\e[0m"
      end
    end

    context 'with a filter' do
      let(:output) { MB::Sound.mag_phase(5000.hz.lowpass) }

      it 'can plot a Filter' do
        expect(lines.length).to eq(40)
      rescue Exception => e
        raise e.class, "#{e.message}\n\t\e[1m#{lines.map(&:inspect).join("\n\t")}\e[0m"
      end
    end

    context 'with a complex-valued filter' do
      let(:output) { MB::Sound.mag_phase(MB::Sound::Filter::HilbertIIR.new) }

      it 'can plot a complex-output Filter' do
        expect(lines.length).to eq(40)
      rescue Exception => e
        raise e.class, "#{e.message}\n\t\e[1m#{lines.map(&:inspect).join("\n\t")}\e[0m"
      end
    end
  end

  describe '#time_freq' do
    context 'with a tone' do
      let(:output) { MB::Sound.time_freq(tone) }

      it 'includes both time and frequency graphs' do |ex|
        expect(lines.length).to eq(40)

        expect(text).to include('time **')
        expect(text).to include('freq **')
        expect(text).not_to match(/^\s*0 .*\*{5,}.*\|$/) # no extended dwell at zero

        check_regex(ex, lines, text, /^\s*0 .*(\*+[^*|]+){12,}.*\|$/) # at least 12 zero crossings
        check_regex(ex, lines, text, /^\s*-40 .*\*{10,}.*\|$/) # lots of frequency plot density
      rescue Exception => e
        raise e.class, "#{e.message}\n\t\e[1m#{lines.map(&:inspect).join("\n\t")}\e[0m"
      end
    end

    context 'with a filter' do
      let(:output) { MB::Sound.time_freq(5000.hz.lowpass) }

      it 'can plot a Filter' do
        expect(lines.length).to eq(40)
      rescue Exception => e
        raise e.class, "#{e.message}\n\t\e[1m#{lines.map(&:inspect).join("\n\t")}\e[0m"
      end
    end

    context 'with a complex filter' do
      let(:output) { MB::Sound.time_freq(MB::Sound::Filter::HilbertIIR.new) }

      it 'can plot a complex-output Filter' do
        expect(lines.length).to eq(40)
      rescue Exception => e
        raise e.class, "#{e.message}\n\t\e[1m#{lines.map(&:inspect).join("\n\t")}\e[0m"
      end
    end
  end

  describe '#spectrum' do
    context 'with a sine wave' do
      let(:output) { MB::Sound.spectrum(400.hz.sine, samples: 1200) }

      it 'can plot a spectrogram of a sine wave' do |ex|
        expect(MB::Sound).to receive(:puts).with(/Plotting/)
        expect(lines.length).to eq(40)

        expect(text).to include('0 ***')

        r1 = /^.*-70 [^*]+(\*+[^*|]+){2}[^*|]+\|$/
        check_regex(ex, lines, text, r1)

        r2 = /^.*-30 [^*]+(\*+[^*|]+){1,2}[^*|]+\|$/
        check_regex(ex, lines, text, r2)
      rescue Exception => e
        raise e.class, "#{e.message}\n\t\e[1m#{lines.map(&:inspect).join("\n\t")}\e[0m"
      end
    end

    context 'with a gauss wave' do
      let(:output) { MB::Sound.spectrum(480.hz.gauss.at(0.1), samples: 800) }

      it 'can plot a spectrogram of a more complex wave' do |ex|
        expect(MB::Sound).to receive(:puts).with(/Plotting/)
        expect(lines.length).to eq(40)

        expect(text).to include('0 ***')
        check_regex(ex, lines, text, /^.*-40 [^*]+(\*+[^*|]+){7,9}[^*|]+\|$/)
        check_regex(ex, lines, text, /^.*-30 [^*]+(\*+[^*|]+){1,3}[^*|]+\|$/)

        expect(text.match(/^.*-30 [^*]+(\*+[^*|]+){1,3}[^*|]+\|$/).to_s.length).to be_between(75, 81).inclusive
      rescue Exception => e
        raise e.class, "#{e.message}\n\t\e[1m#{lines.map(&:inspect).join("\n\t")}\e[0m"
      end
    end
  end

  describe '#plot' do
    context 'with a tone' do
      let(:output) { MB::Sound.plot(tone) }

      it 'can plot a Tone' do
        expect(MB::Sound).to receive(:puts).with(/Plotting.*Tone/m)
        expect(lines.length).to eq(40)
      rescue Exception => e
        raise e.class, "#{e.message}\n\t\e[1m#{lines.map(&:inspect).join("\n\t")}\e[0m"
      end
    end

    context 'with a sound file' do
      let(:output) { MB::Sound.plot('sounds/synth0.flac') }

      it 'can plot a sound file' do
        expect(MB::Sound).to receive(:puts).with(/Plotting.*synth0.flac/m)
        expect(lines.length).to eq(40)
        expect(lines.select { |l| l.include?('------------') }.length).to eq(4)

        expect(text).to include('0 **')
        expect(text).to include('1 **')
        expect(text).not_to include('2 **')
      end
    end

    context 'with a Numo::NArray' do
      let(:output) { MB::Sound.plot(tone.sample(800)) }

      it 'can plot a Numo::NArray' do |ex|
        expect(MB::Sound).to receive(:puts).with(/Plotting.*Numo/m)
        expect(lines.length).to eq(40)

        expect(text).to include('0 **')
        expect(text).not_to include('1 **')
        check_regex(ex, lines, text, /^\s*0 .*(\*+[^*|]+){3,5}.*\|$/) # 4 zero crossings
      rescue Exception => e
        raise e.class, "#{e.message}\n\t\e[1m#{lines.map(&:inspect).join("\n\t")}\e[0m"
      end
    end

    context 'with multiple sounds' do
      let(:output) { MB::Sound.plot([123.hz.sine, 123.hz.ramp, 123.hz.triangle, 123.hz.gauss]) }

      it 'can plot an array of different sounds' do
        expect(MB::Sound).to receive(:puts).with(/Plotting.*[^\e]\[/m)
        expect(lines.length).to eq(40)

        expect(lines.select { |l| l.match(/-{12,}.* {6,}.*-{12,}/) }.length).to eq(4)

        expect(text).to include('0 **')
        expect(text).to include('1 **')
        expect(text).to include('2 **')
        expect(text).to include('3 **')
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
    rescue Exception => e
      raise e.class, "#{e.message}\n\t\e[1m#{lines.map(&:inspect).join("\n\t")}\e[0m"
    end

    it 'can plot a Filter' do
      expect(MB::Sound).to receive(:puts).with(/Plotting.*Filter/m)
      lines = MB::Sound.plot(5000.hz.lowpass)
      expect(lines.length).to eq(40)
    rescue Exception => e
      raise e.class, "#{e.message}\n\t\e[1m#{lines.map(&:inspect).join("\n\t")}\e[0m"
    end

    it 'can plot a Hilbert transform filter with a complex output' do
      expect(MB::Sound).to receive(:puts)
      lines = MB::Sound.plot(MB::Sound::Filter::HilbertIIR.new)
      expect(lines.length).to eq(40)
    rescue Exception => e
      raise e.class, "#{e.message}\n\t\e[1m#{lines.map(&:inspect).join("\n\t")}\e[0m"
    end

    it 'can plot complex-valued audio data' do
      expect(MB::Sound).to receive(:puts)
      lines = MB::Sound.plot(123.hz.complex_sine)
      expect(lines.length).to eq(40)
    rescue Exception => e
      raise e.class, "#{e.message}\n\t\e[1m#{lines.map(&:inspect).join("\n\t")}\e[0m"
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
