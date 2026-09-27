require 'fileutils'
require 'shellwords'

# Runs every script converted to the script runner (see
# MB::Sound::ScriptRunner) with --help and with a short render, checking that
# each one starts, parses its options, and writes a file.
RSpec.describe('script runner scripts') do
  # Script => extra arguments for a short render
  songs = {
    'bin/songs/node_graph_benchmark.rb' => ['--bars', '0.5'],
    'bin/songs/node_graph_grit.rb' => ['--bars', '0.5'],
    'bin/songs/random_drum_pentatonic.rb' => ['--bars', '0.5'],
    'bin/songs/scheduled_song.rb' => ['--bars', '0.5'],
    'bin/songs/sequence_demo.rb' => ['--bars', '0.5', '--bpm', '100'],
    'bin/songs/stereo_drone.rb' => ['--bars', '0.5'],
    'bin/songs/stereo_song.rb' => ['--bars', '0.5'],
    'bin/songs/swap_song.rb' => ['--bars', '0.5'],
    'bin/songs/tempo_song.rb' => ['--bars', '0.5'],
    'bin/synths/fifth_pad.rb' => ['--bars', '0.5'],
  }.freeze

  songs.each do |script, args|
    describe script do
      let(:outfile) { "tmp/smoke_#{File.basename(script, '.rb')}.flac" }

      it 'prints its header and options with --help' do
        text = `#{script.shellescape} --help 2>&1`
        expect($?).to be_success
        header = File.readlines(script)[1].delete_prefix('#').strip
        expect(text).to include(header, '--output', '--bars')
      end

      it 'renders a short file' do
        FileUtils.mkdir_p('tmp')
        File.unlink(outfile) if File.exist?(outfile)

        text = `#{script.shellescape} -q -f #{args.shelljoin} #{outfile.shellescape} 2>&1`
        expect($?).to be_success, text
        expect(text).to include("to #{outfile}")

        data = MB::Sound.read(outfile)
        expect(data.length).to eq(2)
        expect(data[0].length).to be >= 48000 * 0.5 # at least half a bar at up to 240 BPM
      end
    end
  end
end
