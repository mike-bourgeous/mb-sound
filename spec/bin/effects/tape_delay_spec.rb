RSpec.describe('bin/effects/tape_delay.rb') do
  let(:outfile) { tmp_path('tape_delay_output.flac') }

  it 'can generate an output file' do
    output = `bin/effects/tape_delay.rb --quiet spec/test_data/arp_a7.flac #{outfile.shellescape} 2>&1`
    expect($?).to be_success
    expect(output).to include(outfile)

    info = MB::Sound::FFMPEGInput.parse_info(outfile)
    expect(info[:streams][0][:duration_ts]).to be > 48000
  end

  it 'can generate a graphviz image' do
    # In a fork (see ForkScript); the example above is the real run
    output, status = fork_script('bin/effects/tape_delay.rb', '--quiet', 'spec/test_data/arp_a7.flac', outfile, '--graphviz', env: { 'DISPLAY' => '' })
    expect(status).to be_success, output

    png_line = output.lines.find { |l| l.include?('.png') && l.include?(' image to ') }
    png_file = png_line.strip.rpartition(' image to ').last

    info = MB::Sound::FFMPEGInput.parse_info(png_file)
    expect(info[:format][:format_name]).to include('png')
    expect(info[:format][:size]).to be > 0
  end

  # (delays-2, the maintainer's "Widen range": the header's runaway
  # examples, --feedback 1.06 to 1.15, were refused by the names table's
  # -1..1)
  it 'takes feedback above 1 (a runaway held by the tape saturation)' do
    output, status = fork_script('bin/effects/tape_delay.rb', '--quiet', '--feedback', '1.14', '--delay', '0.05', '--oversample', '1', 'spec/test_data/arp_a7.flac', outfile)
    expect(status).to be_success, output
    data = MB::Sound.read(outfile)
    peak = data.map { |c| c.abs.max }.max
    expect(peak).to be_between(0.05, 1.0) # (held by the softclips, not silent)
  end
end
