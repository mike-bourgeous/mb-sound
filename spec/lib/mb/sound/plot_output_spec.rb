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
      expect(STDOUT).to receive(:write).at_least(1).times
      po = MB::Sound::PlotOutput.new(output, graphical: true)
      po.close
    end

    it 'can create a terminal plotter' do
      expect(STDOUT).to receive(:write).at_least(1).times
      po = MB::Sound::PlotOutput.new(output)
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
      expect(MB::Sound::Meter).to receive(:linear_meters).at_least(1).times
      po = MB::Sound::PlotOutput.new(output, window_size: 800, plot: plotter).tap { |p| p.sleep = false }
      po.write([100.hz.sample(800), 200.hz.sample(800), 300.hz.sample(800), Numo::SFloat.zeros(800)])
      lines = plotter.lines
      expect(lines.length).to eq(30)
      expect(lines[0]).to start_with('waveform')
      expect(lines[0]).to include('-- 0', '-- 1', '-- 2', '-- 3')
      expect(lines.join("\n")).to include('time (ms)')
    end

    it 'draws a spectrum over log frequency with note names' do
      expect(MB::Sound::Meter).to receive(:linear_meters).at_least(1).times
      po = MB::Sound::PlotOutput.new(output, window_size: 800, plot: plotter, spectrum: true).tap { |p| p.sleep = false }
      po.write([1000.hz.sample(800)] * 4)
      lines = plotter.lines
      expect(lines[0]).to start_with('spectrum')
      expect(lines.join("\n")).to include('frequency (Hz)', '1k', 'C5')
    end
  end

  describe '#write with a Hash plotter' do
    it 'can plot in the time domain' do
      expect(MB::Sound::Meter).to receive(:linear_meters).at_least(1).times
      expect(plot).to receive(:plot).with(short_data)
      po_time.write(short_data.values)

      expect(plot).to receive(:plot).with(truncated_long_data)
      po_time.write(long_data.values)
    end

    it 'can plot in the frequency domain' do
      expect(MB::Sound::Meter).to receive(:linear_meters).at_least(1).times
      expect(plot).to receive(:plot).with(short_dc)
      po_freq.write(short_data.values)

      expect(plot).to receive(:plot).with(long_dc)
      po_freq.write(long_data.values)
    end
  end
end
