require 'fileutils'
require 'shellwords'

RSpec.describe('bin/songs/node_graph_benchmark.rb') do
  let(:outfile) { 'tmp/node_graph_output.flac' }

  it 'can save the song to a file' do
    FileUtils.mkdir_p(File.dirname(outfile))

    output = `LOOP_COUNT=60 bin/songs/node_graph_benchmark.rb #{outfile.shellescape} --overwrite`
    expect($?).to be_success

    expect(output).to include(outfile)

    info = MB::Sound::FFMPEGInput.parse_info(outfile)
    expect(info[:streams][0][:duration_ts]).to eq(48000)
  end
end
