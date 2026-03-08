RSpec.describe('bin/reverb.rb') do
  let(:outfile) { 'tmp/reverb_output.flac' }

  before do
    FileUtils.mkdir_p(File.dirname(outfile))
    File.unlink(outfile) if File.exist?(outfile)
  end

  it 'can generate an output file' do
    output = `bin/reverb.rb --quiet sounds/piano0.flac #{outfile} 2>&1`
    expect($?).to be_success
    expect(output).to include(outfile)

    info = MB::Sound::FFMPEGInput.parse_info(outfile)
    expect(info[:streams][0][:duration_ts]).to be > 48000
  end

  it 'can generate an output file with custom parameters' do
    output = `bin/reverb.rb --quiet --room-size 0.8 --decay 1.0 --damping 0.7 sounds/piano0.flac #{outfile} 2>&1`
    expect($?).to be_success

    info = MB::Sound::FFMPEGInput.parse_info(outfile)
    expect(info[:streams][0][:duration_ts]).to be > 48000
  end

  it 'can generate a graphviz image' do
    output = `DISPLAY= bin/reverb.rb --quiet sounds/piano0.flac #{outfile} --graphviz 2>&1`
    expect($?).to be_success

    png_line = output.lines.find { |l| l.include?('.png') && l.include?(' image to ') }
    png_file = png_line.strip.rpartition(' image to ').last

    info = MB::Sound::FFMPEGInput.parse_info(png_file)
    expect(info[:format][:format_name]).to include('png')
    expect(info[:format][:size]).to be > 0
  end
end
