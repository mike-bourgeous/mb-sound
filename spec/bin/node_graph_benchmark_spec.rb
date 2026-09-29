require 'fileutils'
require 'shellwords'

RSpec.describe('bin/songs/node_graph_benchmark.rb') do
  let(:outfile) { tmp_path('node_graph_output.flac') }

  it 'can save the song to a file' do
    output = `bin/songs/node_graph_benchmark.rb --bars 0.5 #{outfile.shellescape} --overwrite` # 1 second at 120 BPM
    expect($?).to be_success

    expect(output).to include(outfile)

    info = MB::Sound::FFMPEGInput.parse_info(outfile)
    expect(info[:streams][0][:duration_ts]).to eq(48000)
  end
end
