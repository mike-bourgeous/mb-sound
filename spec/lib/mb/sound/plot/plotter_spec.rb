RSpec.describe(MB::Sound::Plot::Plotter) do
  let(:io) { StringIO.new }
  let(:plotter) { described_class.terminal(width: 60, height: 16, look: :ascii, color: :none, io: io) }

  it 'prints a grid of titled charts from a Hash, like MB::M::Plot' do
    plotter.plot({ 'sine' => 100.hz.sample(480), 'pairs' => [[1, 2], [2, 4], [3, 1]] })
    lines = io.string.lines(chomp: true)
    expect(lines.length).to eq(16)
    expect(lines[0]).to start_with('sine')
    expect(lines[8]).to start_with('pairs') # stacked like MB::M::Plot (rows = ceil(sqrt(n)))
  end

  it 'returns lines instead with print: false or #print false' do
    expect(plotter.plot({ 'a' => [1, 2, 3] }, print: false).length).to eq(16)
    plotter.print = false
    expect(plotter.plot({ 'a' => [1, 2, 3] }).length).to eq(16)
    expect(io.string).to be_empty
  end

  it 'draws 2D data as a heatmap' do
    lines = plotter.plot({ 'heat' => Numo::SFloat.new(8, 16).seq }, print: false)
    expect(lines.join).to include('█', '░')
  end

  it 'honors ranges, log scale, and plot types' do
    plotter.yrange(-10, 10)
    plotter.logscale
    lines = plotter.plot({ 'a' => { data: Numo::DFloat.new(100).seq, type: 'impulses' } }, print: false)
    expect(lines.join("\n")).to include('-10', '10', '1', '100').or include('-10', '10', '1', '50')
    plotter.logscale(false)
    plotter.yrange(nil, nil)
  end

  it 'saves the next plot instead of showing it' do
    path = tmp_path('p.svg')
    plotter.save_image(path, width: 300, height: 200)
    expect(plotter.plot({ 'a' => [1, 2, 3] })).to be_nil
    expect(File.read(path)).to include('viewBox="0 0 300 200"')
    expect(io.string).to be_empty
  end

  it "refuses gnuplot commands and plots after #close" do
    expect { plotter.command('set xrange [0:1]') }.to raise_error(MB::Sound::Plot::PlotError, /gnuplot/)
    plotter.close
    expect(plotter.closed?).to eq(true)
    expect { plotter.plot({ 'a' => [1] }) }.to raise_error(MB::Sound::Plot::PlotError, /closed/)
  end

  it 'falls back to text when graphical and no image protocol is known' do
    allow(MB::Sound::Plot::Terminal).to receive(:image_protocol).and_return(nil)
    allow(MB::Sound::Plot::Terminal).to receive(:width).and_return(50)
    allow(MB::Sound::Plot::Terminal).to receive(:height).and_return(20)
    g = described_class.graphical(io: io, color: :none)
    g.plot({ 'a' => [1, 2, 3] })
    expect(io.string.lines.length).to eq(18)
  end

  it 'writes inline images when graphical and the terminal supports them' do
    allow(MB::Sound::Plot::Terminal).to receive(:image_protocol).and_return(:kitty)
    g = described_class.graphical(width: 200, height: 120, io: io)
    g.plot({ 'a' => [1, 2, 3] })
    expect(io.string).to start_with("\e_Ga=T,f=100")
  end
end
