RSpec.describe(MB::Sound::Plot::Chart) do
  let(:plot) { MB::Sound::Plot }
  let(:theme) { plot::Theme[:dark] }

  it 'builds with instance_exec for blocks without arguments, or yields the builder' do
    data = [1, 2, 3]
    a = plot.chart(title: 'a') { line data, label: 'x' }
    b = plot.chart(title: 'a') { |c| c.line data, label: 'x' }
    expect(a.marks.length).to eq(1)
    expect(b.to_s(width: 30, height: 6, color: :none)).to eq(a.to_s(width: 30, height: 6, color: :none))
  end

  it 'raises NoMethodError with suggestions for typos in the builder' do
    expect { plot.chart { lien [1, 2] } }.to raise_error(NoMethodError) { |e| expect(e.detailed_message).to include('line') }
  end

  it 'assigns palette slots in order to series without colors, muted to rules' do
    c = plot.chart {
      line [1, 2], label: 'a'
      rule y: 0
      line [2, 1], label: 'b', color: '#ff0000'
      area [1, 1], label: 'c'
      line [0, 0], color: 5
    }
    expect(c.colors(theme)).to eq([theme.series(0), theme.muted, [255, 0, 0], theme.series(1), theme.series(5)])
  end

  it 'shows a legend for two or more labeled series, or one without a title' do
    expect(plot.chart(title: 't') { line [1], label: 'a' }.legend_entries(theme)).to be_empty
    expect(plot.chart { line [1], label: 'a' }.legend_entries(theme).map(&:first)).to eq(['a'])
    expect(plot.chart(title: 't', legend: true) { line [1], label: 'a' }.legend_entries(theme).length).to eq(1)
    expect(plot.chart(title: 't', legend: false) { line [1], label: 'a'; line [2], label: 'b' }.legend_entries(theme)).to be_empty
  end

  it 'fits scales to every mark' do
    c = plot.chart { line [0, 5], x: [10, 20]; points [-3, 1], x: [12, 14] }
    co = c.coord
    expect([co.x.lo, co.x.hi]).to eq([10.0, 20.0])
    expect([co.y.lo, co.y.hi]).to eq([-4.0, 6.0])
  end

  it 'lays out figures about square by default' do
    charts = Array.new(5) { plot.chart { line [1, 2] } }
    f = plot.figure(*charts)
    expect([f.rows, f.columns]).to eq([3, 2])
    expect(plot.figure(*charts, columns: 5).rows).to eq(1)
  end

  it 'saves by extension' do
    c = plot.chart(title: 'saw') { line 100.hz.ramp.sample(480) }
    expect(File.read(c.save(tmp_path('a.svg')))).to start_with('<svg')
    expect(File.binread(c.save(tmp_path('a.png'), width: 200, height: 100))).to start_with("\x89PNG".b)
    expect(File.read(c.save(tmp_path('a.txt'), width: 40, height: 8))).to start_with('saw')
    expect(File.read(c.save(tmp_path('a.ans'), width: 40, height: 8))).to include("\e[")
    expect(File.read(c.save(tmp_path('a.html'), width: 40, height: 8))).to include('<pre>', 'saw')
    expect { c.save(tmp_path('a.gif')) }.to raise_error(ArgumentError, /extension/)
  end

  it 'shows text by default' do
    io = StringIO.new
    plot.chart(title: 'saw') { line [1, 2] }.show(io: io, width: 30, height: 5, color: :none)
    expect(io.string.lines.length).to eq(5)
  end
end
