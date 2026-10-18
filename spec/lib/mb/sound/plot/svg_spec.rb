RSpec.describe(MB::Sound::Plot::SVG) do
  let(:chart) {
    MB::Sound::Plot.chart(title: 'Saw & <square>') {
      x :time, sample_rate: 48000
      line 110.hz.saw.sample(4800), label: 'saw'
      line 110.hz.square.sample(4800), label: 'square'
    }
  }

  let(:spectrogram) { MB::Sound::Plot.spectrogram(Numo::DFloat.new(8000).rand - 0.5, fft: 512) }

  it 'writes an SVG document with escaped text, axis titles, and a legend' do
    svg = chart.to_svg(width: 640, height: 360)
    expect(svg).to start_with('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 360"')
    expect(svg).to include('Saw &amp; &lt;square&gt;', 'time (ms)', '>saw<', '>square<', '<title>saw</title>')
    expect(svg.scan('<path d="M').length).to be >= 2
  end

  it 'gives every render its own element ids, so inlined SVGs never share defs' do
    page = %i[paper studio phosphor].map { |t| spectrogram.to_svg(theme: t) }.join + chart.to_svg(theme: :phosphor)
    ids = page.scan(/ id="([^"]+)"/).flatten
    expect(ids.length).to be > 6
    expect(ids.uniq.length).to eq(ids.length)

    refs = page.scan(/url\(#([^)]+)\)/).flatten
    expect(refs - ids).to be_empty
  end

  it 'accepts a fixed id prefix for deterministic output' do
    a = spectrogram.to_svg(theme: :phosphor, id_prefix: 'x-')
    b = spectrogram.to_svg(theme: :phosphor, id_prefix: 'x-')
    expect(a).to eq(b)
    expect(a).to include('id="x-plot1"', 'url(#x-grad', 'id="x-glow"')
  end

  it 'embeds heatmaps as PNG images no larger than heatmap_pixels' do
    svg = spectrogram.to_svg(width: 800, height: 400, heatmap_pixels: [50, 20])
    png = svg[/data:image\/png;base64,([^"]+)/, 1].unpack1('m0')
    expect(png[12, 4]).to eq('IHDR')
    expect(png[16, 8].unpack('NN')).to eq([50, 20])
  end
end
