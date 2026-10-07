require 'fileutils'
require 'shellwords'

# Runs every script converted to the script runner (see
# MB::Sound::ScriptRunner) with --help and with a short render, checking that
# each one starts, parses its options, and writes a file.  Renders run as
# real processes; --help runs in a fork of the spec process (see ForkScript)
# for scripts that also render here, saving ~0.7 s of startup each.
RSpec.describe('script runner scripts', :smoke) do
  # Scripts here check that no node modifies a buffer a Tee shares among
  # its branches (see GraphNode::Tee.shared_check), raising if one does
  around(:each) do |example|
    old_env = ENV['MB_SOUND_CHECK_SHARED']
    old_check = MB::Sound::GraphNode::Tee.shared_check
    ENV['MB_SOUND_CHECK_SHARED'] = '1'
    MB::Sound::GraphNode::Tee.shared_check = :raise
    example.run
  ensure
    ENV['MB_SOUND_CHECK_SHARED'] = old_env
    MB::Sound::GraphNode::Tee.shared_check = old_check
  end

  # Script => extra arguments for a short render
  songs = {
    'bin/songs/antialias_song.rb' => ['--bars', '0.5'],
    'bin/songs/bouncing_ball.rb' => ['--bars', '0.5'],
    'bin/songs/node_graph_benchmark.rb' => ['--bars', '0.5'],
    'bin/songs/node_graph_grit.rb' => ['--bars', '0.5'],
    'bin/songs/random_drum_pentatonic.rb' => ['--bars', '0.5'],
    'bin/songs/scheduled_song.rb' => ['--bars', '0.5'],
    'bin/songs/sequence_demo.rb' => ['--bars', '0.5', '--bpm', '100'],
    'bin/songs/stereo_drone.rb' => ['--bars', '0.5'],
    'bin/songs/stereo_song.rb' => ['--bars', '0.5'],
    'bin/songs/swap_song.rb' => ['--bars', '0.5'],
    'bin/songs/swarm_song.rb' => ['--bars', '0.5', '-c', '8'],
    'bin/songs/tempo_song.rb' => ['--bars', '0.5'],
    'bin/songs/tween_song.rb' => ['--bars', '0.5', '-c', '4'],
    'bin/songs/unison_song.rb' => ['--bars', '0.5', '-l', 'even'],
    'bin/songs/wavetable_song.rb' => ['--bars', '0.5'],
    'bin/stereo_graph_example.rb' => ['--bars', '0.5'],
    'bin/synths/fifth_pad.rb' => ['--bars', '0.5'],
  }.freeze

  # Effect script => extra arguments; each processes a short test file
  effects = {
    'bin/effects/fdn_reverb.rb' => ['--decay', '0.3'],
    'bin/effects/flanger.rb' => ['--oversample', '1'],
    'bin/effects/grain_repeater.rb' => ['--delay', '0.05', '-n', '4'],
    'bin/effects/ping_pong_delay.rb' => ['--delay', '0.05', '--feedback', '0.3'],
    'bin/effects/reverb.rb' => ['--preset', 'room', '-w', '-6'],
    'bin/effects/reverse_delay.rb' => ['--delay', '0.1', '--oversample', '1'],
    'bin/effects/tape_delay.rb' => ['--feedback', '0.3', '--oversample', '1'],
    'bin/effects/multitap_delay.rb' => ['--delay', '0.05', '--oversample', '1'],
  }.freeze

  let(:infile) { tmp_path('smoke_effect_input.flac') }

  effects.each do |script, args|
    describe script do
      let(:outfile) { tmp_path("smoke_#{File.basename(script, '.rb')}.flac") }

      it 'prints its header and options with --help' do
        # Forked (see ForkScript); the render below is a real process run
        text, status = fork_script(script, '--help')
        expect(status).to be_success, text
        header = File.readlines(script)[1].delete_prefix('#').strip
        expect(text).to include(header, '--output', '--input-channels', '--repeat')
      end

      it 'processes a short file, ringing out after it ends' do
        MB::Sound.write(infile, [220.hz.ramp.at(0.5).sample(4800), 330.hz.ramp.at(0.5).sample(4800)], sample_rate: 48000, overwrite: true)

        text = `#{script.shellescape} -q -f #{args.shelljoin} #{infile.shellescape} #{outfile.shellescape} 2>&1`
        expect($?).to be_success, text
        expect(text).to include("to #{outfile}")

        data = MB::Sound.read(outfile)
        expect(data.length).to be >= 2
        expect(data[0].length).to be > 4800 # longer than the input
        expect(data.map { |c| c.abs.max }.max).to be > 0.01
      end
    end
  end

  # Synth script => extra arguments; each plays a short MIDI file
  synths = {
    'bin/synths/ep2_syn.rb' => [],
    'bin/synths/filter_ping.rb' => [],
    'bin/synths/fm_bass.rb' => [],
    'bin/synths/fm_bell.rb' => [],
    'bin/synths/fm_brass.rb' => [],
    'bin/synths/fm_bellpad.rb' => [],
    'bin/synths/fm_chain.rb' => ['--no-table'],
    'bin/synths/fm_drumbass.rb' => [],
    'bin/synths/fm_epiano.rb' => [],
    'bin/synths/fm_experimental_bell.rb' => [],
    'bin/synths/fm_kick.rb' => [],
    'bin/synths/fm_synth.rb' => [],
    'bin/synths/sinewave.rb' => [],
    'bin/synths/sq80_voice.rb' => [],
    'bin/synths/stereo_graph_synth_example.rb' => [],
    'bin/synths/wavetable_bass.rb' => [],
    'bin/wavetable_pr_example.rb' => [],
  }.freeze

  synths.each do |script, args|
    describe script do
      let(:outfile) { tmp_path("smoke_#{File.basename(script, '.rb')}.flac") }

      it 'prints its header and options with --help' do
        # Forked (see ForkScript); the render below is a real process run
        text, status = fork_script(script, '--help')
        expect(status).to be_success, text
        header = File.readlines(script)[1].delete_prefix('#').strip
        expect(text).to include(header, '--output', '--input MIDI')
      end

      it 'plays a MIDI file into an audio file' do
        text = `#{script.shellescape} -q -f #{args.shelljoin} spec/test_data/c2_sustain.mid #{outfile.shellescape} 2>&1`
        expect($?).to be_success, text
        expect(text).to include("to #{outfile}")

        # Notes ring out after the last MIDI event, then the runner stops after
        # a second of quiet (counted in whole buffers, so allow a little less),
        # or fades out after at most 10 s of tail
        music_end = MB::Sound::MIDI::MIDIFile.new('spec/test_data/c2_sustain.mid').music_end
        data = MB::Sound.read(outfile)
        expect(data[0].length).to be_between(48000 * (music_end + 0.9), 48000 * (music_end + 11))
        expect(data.map { |c| c.abs.max }.max).to be > 0.001
      end
    end
  end

  # Every general script (MB::Sound.script) prints its header and options
  general = Dir['bin/**/*.rb'].select { |f| File.read(f).match?(/MB::Sound\.script\b/) }.sort

  general.each do |script|
    describe script do
      it 'prints its header and options with --help' do
        # A real process run: this is the only run of general scripts here
        text = `#{script.shellescape} --help 2>&1`
        expect($?).to be_success, text
        header = File.readlines(script)[1].delete_prefix('#').strip
        expect(text).to include(header, "Options for #{File.basename(script)}", '--help')
      end
    end
  end

  songs.each do |script, args|
    describe script do
      let(:outfile) { tmp_path("smoke_#{File.basename(script, '.rb')}.flac") }

      it 'prints its header and options with --help' do
        # Forked (see ForkScript); the render below is a real process run
        text, status = fork_script(script, '--help')
        expect(status).to be_success, text
        header = File.readlines(script)[1].delete_prefix('#').strip
        expect(text).to include(header, '--output', '--bars')
      end

      it 'renders a short file' do
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
