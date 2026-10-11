RSpec.describe('bin/plot_gallery.rb') do
  it 'writes a compact gallery with every look and theme' do
    dir = tmp_path('gallery')
    text, status = run_script('bin/plot_gallery.rb', '--compact', '-o', dir, real: true)
    expect(status).to be_success, text
    expect(text).to include("Wrote #{dir}/index.html")

    html = File.read(File.join(dir, 'index.html'))
    expect(html.bytesize).to be < 400_000
    MB::Sound::Plot::Text::LOOKS.each_key { |look| expect(html).to include(%(id="look-#{look}")) }
    %w[paper studio phosphor].each { |theme| expect(html).to include(%(id="svg-#{theme}")) }
    ids = html.scan(/ id="([^"]+)"/).flatten
    expect(ids.uniq.length).to eq(ids.length)

    expect(File.read(File.join(dir, 'scope_waveform.ans'))).to include("\e[38;2;")
    expect(File.read(File.join(dir, 'paper_spectrum.svg'))).to start_with('<svg')
  end

  it 'prints one look in the terminal' do
    text, status = run_script('bin/plot_gallery.rb', '--show', 'ascii', '-W', '60', '-H', '12')
    expect(status).to be_success, text
    expect(text).to include('Saw at A2', 'Spectrogram')
  end
end
