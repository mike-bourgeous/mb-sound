RSpec.describe(MB::Sound::PlotOutput) do
  # A plotter with only MB::M::Plot's Hash interface (no #draw)
  let(:hash_plotter) {
    Class.new do
      attr_accessor :print
      def plot(data) = data
      def xrange(*) = nil
      def yrange(*) = nil
      def logscale(*) = nil
      def close = nil
      def closed? = false
    end
  }
  let(:plot) { hash_plotter.new.tap { |p| p.print = false } }
  let(:plotter) { MB::Sound::Plot::Plotter.terminal(width: 80, height: 30, look: :ascii, color: :none).tap { |p| p.print = false } }
  let(:output) { MB::Sound::NullOutput.new(channels: 4) }
  let(:po_time) { MB::Sound::PlotOutput.new(output, window_size: 800, plot: plot).tap { |p| p.sleep = false } }
  let(:po_freq) { MB::Sound::PlotOutput.new(output, window_size: 800, plot: plot, spectrum: true).tap { |p| p.sleep = false } }

  let(:short_data) { ([Numo::SFloat.ones(150)] * 4).map.with_index { |v, k| [k, v] }.to_h }
  let(:long_data) { ([Numo::SFloat.ones(1100)] * 4).map.with_index { |v, k| [k, v] }.to_h }
  let(:truncated_long_data) { ([Numo::SFloat.ones(800)] * 4).map.with_index { |v, k| [k, v] }.to_h }

  let(:short_dc) {
    ([Numo::DFloat.zeros(76).fill(-80).tap { |n| n[0] = 2.to_db }] * 4).map.with_index { |v, k| [k, v] }.to_h
  }
  let(:long_dc) {
    ([Numo::DFloat.zeros(401).fill(-80).tap { |n| n[0] = 2.to_db }] * 4).map.with_index { |v, k| [k, v] }.to_h
  }

  after(:each) {
    output.close
  }

  describe '#initialize' do
    it 'accepts an externally created plotter' do
      expect(po_time.output).to equal(output)
    end

    it 'can create a graphical plotter' do
      po = MB::Sound::PlotOutput.new(output, graphical: true)
      expect(po.instance_variable_get(:@p)).to be_a(MB::Sound::Plot::Plotter)
      expect(po.band).to be_nil
      po.close
    end

    # (play-ui-1: a band of the terminal UI replaced the old text meters)
    it 'shows writes on a band of master meters and a scope when its io is a terminal, and takes it down on close' do
      io = Class.new(StringIO) {
        def tty? = true
        def winsize = [30, 100]
      }.new
      po = MB::Sound::PlotOutput.new(MB::Sound::NullOutput.new(channels: 2, sleep: false), io: io)
      po.write([220.hz.sample(800), 330.hz.sample(800)])
      expect(po.band).to be_a(MB::Sound::UI::Band)
      po.band.refresh
      screen = MB::Term::Screen.new(30, 100)
      screen.feed(io.string)
      expect(screen.to_text).to include('MASTER').and include('SCOPE')
      expect(po.feed.frames).to eq(800)
      po.close
      expect(po.band).to be_nil
    end

    it "doesn't draw anything when its io isn't a terminal" do
      io = StringIO.new
      po = MB::Sound::PlotOutput.new(MB::Sound::NullOutput.new(channels: 2, sleep: false), io: io)
      po.write([220.hz.sample(800)] * 2)
      expect(po.band).to be_nil
      expect(io.string).to eq('')
      po.close
    end
  end

  describe '#closed?' do
    it 'returns false if the output is open' do
      expect(output.closed?).to eq(false)
      expect(po_time.closed?).to eq(false)
    end

    it 'returns true if the output is closed' do
      expect(output.closed?).to eq(false)
      expect(po_time.closed?).to eq(false)
      output.close
      expect(po_time.closed?).to eq(true)
    end
  end

  describe '#close' do
    it 'closes the output' do
      po_time.close
      expect(output.closed?).to eq(true)
      expect(po_time.closed?).to eq(true)
    end
  end

  describe '#write with a Plot plotter' do
    it 'draws a waveform with one legend entry per channel' do
      po = MB::Sound::PlotOutput.new(output, window_size: 800, plot: plotter).tap { |p| p.sleep = false }
      po.write([100.hz.sample(800), 200.hz.sample(800), 300.hz.sample(800), Numo::SFloat.zeros(800)])
      lines = plotter.lines
      expect(lines.length).to eq(30)
      expect(lines[0]).to start_with('waveform')
      expect(lines[0]).to include('-- 0', '-- 1', '-- 2', '-- 3')
      expect(lines.join("\n")).to include('time (ms)')
    end

    it 'draws a spectrum over log frequency with note names' do
      po = MB::Sound::PlotOutput.new(output, window_size: 800, plot: plotter, spectrum: true).tap { |p| p.sleep = false }
      po.write([1000.hz.sample(800)] * 4)
      lines = plotter.lines
      expect(lines[0]).to start_with('spectrum')
      expect(lines.join("\n")).to include('frequency (Hz)', '1k', 'C5')
    end
  end

  describe '#write with a Hash plotter' do
    it 'can plot in the time domain' do
      expect(plot).to receive(:plot).with(short_data)
      po_time.write(short_data.values)

      expect(plot).to receive(:plot).with(truncated_long_data)
      po_time.write(long_data.values)
    end

    it 'can plot in the frequency domain' do
      expect(plot).to receive(:plot).with(short_dc)
      po_freq.write(short_data.values)

      expect(plot).to receive(:plot).with(long_dc)
      po_freq.write(long_data.values)
    end
  end
end
