RSpec.describe(MB::Sound::PlotOutput) do
  let(:plot) { MB::M::Plot.new(terminal: 'dumb', width: 80, height: 40).tap { |p| p.print = false } }
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

  before(:each) {
    ENV['PLOT_TYPE'] = 'dumb'
  }

  after(:each) {
    ENV.delete('PLOT_TYPE')
    plot.close
    output.close
  }

  describe '#initialize' do
    it 'accepts an externally created plotter' do
      expect(po_time.output).to equal(output)
    end

    it 'can create a graphical plotter' do
      po = MB::Sound::PlotOutput.new(output, graphical: true)
      po.close
    end

    it 'can create a terminal plotter' do
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

  describe '#write' do
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
