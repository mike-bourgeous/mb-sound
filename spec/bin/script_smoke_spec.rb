require 'fileutils'
require 'shellwords'

# Runs every script converted to the script runner (see
# MB::Sound::ScriptRunner) with --help and with a short render, checking that
# each one starts, parses its options, and writes a file.  Renders run as
# real processes; --help runs in a fork of the spec process (see ForkScript)
# for scripts that also render here, saving ~0.7 s of startup each.
RSpec.describe('script runner scripts', :smoke) do
  # The real-process renders run a few at a time (see SmokeRuns), started
  # before the examples, each checked by its own example
  runs = SmokeRuns.new(File.join(SpecTmp::ROOT, 'smoke_runs'))
  out_dir = File.join(SpecTmp::ROOT, 'smoke_out')
  infile = File.join(out_dir, 'smoke_effect_input.flac')
  shared_env = { 'MB_SOUND_CHECK_SHARED' => '1' } # (as the around hook below sets for the forks)

  before(:context) do
    FileUtils.mkdir_p(out_dir)
    # (-12 dB: effect scripts play at 0 dB, and dry + wet (flanger, ping
    # pong) went over full scale with 0.5, which renders warn about)
    MB::Sound.write(infile, [220.hz.ramp.at(0.25).sample(4800), 330.hz.ramp.at(0.25).sample(4800)], sample_rate: 48000, overwrite: true)
    # Longest first (the full drums_808 render, the granular song)
    keys = SmokeRuns.selected_keys
    first = keys.select { |k| k.include?('full') || k.include?('granular') }
    runs.start(first + (keys - first))
  end

  after(:context) { runs.stop }

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
    'bin/songs/acid_song.rb' => ['--bars', '0.5', '-F', 'lp4'],
    'bin/songs/antialias_song.rb' => ['--bars', '0.5'],
    'bin/songs/bouncing_ball.rb' => ['--bars', '0.5'],
    'bin/songs/critters.rb' => ['--bars', '0.5', '--binaural', '-s', '2'],
    'bin/songs/drums_808.rb' => ['--bars', '0.5', '-c', '12'],
    'bin/songs/drums_909.rb' => ['--bars', '0.5', '-s', '4'],
    'bin/songs/even_more_cowbell.rb' => ['--bars', '0.5', '-F', '2'],
    'bin/songs/feedback_song.rb' => ['--bars', '0.5', '-e', '0.7'],
    'bin/songs/generative_blur.rb' => ['--bars', '0.5', '-m', 'both', '-u', '0.4', '-t', 'slow', '-C', '0.5'],
    'bin/songs/generative_demo.rb' => ['--bars', '0.5', '-s', '3', '-u', '0.3'],
    'bin/songs/genre_demo.rb' => ['--bars', '0.5', '-G', 'jungle', '-s', '20'],
    'bin/songs/granular_song.rb' => ['--bars', '0.5', '-d', '0.5'],
    'bin/songs/kit_builder.rb' => ['--bars', '0.5', '-s', '0'],
    'bin/songs/loop_church.rb' => ['--bars', '0.5', '-S', '0.6'],
    'bin/songs/memory_card.rb' => ['--bars', '0.5', '-C', '-2'],
    'bin/songs/midi_transforms_song.rb' => ['--bars', '0.5', '-s'],
    'bin/songs/node_graph_benchmark.rb' => ['--bars', '0.5'],
    'bin/songs/node_graph_grit.rb' => ['--bars', '0.5'],
    'bin/songs/night_bus_set.rb' => ['--bars', '0.5', '-c', '900'],
    'bin/songs/night_bus_flow.rb' => ['--bars', '0.5', '--seed', '2'],
    'bin/songs/night_bus_capture.rb' => ['--bars', '0.5', '-Q', '0.5'],
    'bin/songs/press_and_chop.rb' => ['--bars', '0.5', '-l', 'sp1200'],
    'bin/songs/rack_demo.rb' => ['--bars', '0.5', '--show'],
    'bin/songs/random_drum_pentatonic.rb' => ['--bars', '0.5'],
    'bin/songs/scheduled_song.rb' => ['--bars', '0.5'],
    'bin/songs/small_talk.rb' => ['--bars', '0.5', '--seed', '2', '-m', '0.6'],
    'bin/songs/sequence_demo.rb' => ['--bars', '0.5', '--bpm', '100'],
    'bin/songs/stereo_drone.rb' => ['--bars', '0.5'],
    'bin/songs/stereo_song.rb' => ['--bars', '0.5'],
    'bin/songs/swap_song.rb' => ['--bars', '0.5'],
    'bin/songs/swarm_song.rb' => ['--bars', '0.5', '-c', '8'],
    'bin/songs/tempo_song.rb' => ['--bars', '0.5'],
    'bin/songs/tin_roof.rb' => ['--bars', '0.5', '-s', '2'],
    'bin/songs/tunnel_vision.rb' => ['--bars', '0.5', '-D', '8'],
    'bin/songs/tween_song.rb' => ['--bars', '0.5', '-c', '4'],
    'bin/songs/unison_song.rb' => ['--bars', '0.5', '-l', 'even'],
    'bin/songs/vocal_lead_song.rb' => ['--bars', '0.5', '-S', 'pulse', '-t', '1'],
    'bin/songs/wind_chimes.rb' => ['--bars', '0.5', '-G', '2', '-s', '3'],
    'bin/songs/wavetable_song.rb' => ['--bars', '0.5'],
    'bin/stereo_graph_example.rb' => ['--bars', '0.5'],
    'bin/midi/moving_params.rb' => ['--bars', '0.5', '-e', 'knob_arp'],
    'bin/midi/key_lock.rb' => ['--bars', '0.5', '-s', 'chord', '-k', 'a,minor'],
    'bin/synths/fifth_pad.rb' => ['--bars', '0.5'],
  }.freeze

  # Effect script => extra arguments; each processes a short test file
  effects = {
    'bin/effects/flanger.rb' => ['--oversample', '1'],
    'bin/effects/grain_repeater.rb' => ['--delay', '0.05', '-n', '4'],
    'bin/effects/juno_chorus.rb' => ['--mode', 'lush', '--bbd', '--mix', '0.6'],
    'bin/effects/ping_pong_delay.rb' => ['--delay', '0.05', '--feedback', '0.3'],
    'bin/effects/reverb.rb' => ['--preset', 'room', '-w', '-6', '--mod', 'lush', '--drive', '2', '--shimmer', '0.3'],
    'bin/effects/reverse_delay.rb' => ['--delay', '0.1', '--oversample', '1'],
    'bin/effects/tape_delay.rb' => ['--feedback', '0.3', '--oversample', '1'],
    'bin/effects/multitap_delay.rb' => ['--delay', '0.05', '--oversample', '1'],
  }.freeze

  effects.each do |script, args|
    describe script do
      outfile = File.join(out_dir, "smoke_#{File.basename(script, '.rb')}.flac")
      key = "#{script} render"
      runs.add(key, "#{script.shellescape} -q -f #{args.shelljoin} #{infile.shellescape} #{outfile.shellescape}", env: shared_env)

      it 'prints its header and options with --help' do
        # Forked (see ForkScript); the render below is a real process run
        text, status = fork_script(script, '--help')
        expect(status).to be_success, text
        header = File.readlines(script)[1].delete_prefix('#').strip
        expect(text).to include(header, '--output', '--input-channels', '--repeat')
      end

      it 'processes a short file, ringing out after it ends', smoke_run: key do
        text, status = runs.take(key)
        expect(status).to be_success, text
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
    'bin/synths/acid.rb' => [],
    'bin/synths/ambient.rb' => ['-p', 'koto', '-w', '0.5'], # (bowls and the gong ring past the 10 s check)
    'bin/synths/dnb.rb' => ['-p', 'neuro', '-G', '0.5'],
    'bin/synths/drums_808.rb' => ['-c', '6'],
    'bin/synths/drums_909.rb' => ['-k', '0.8', '-d', '2'], # (a long kick: the kit ends when its voices go quiet)
    'bin/synths/electric_pianos.rb' => ['-p', 'reed', '-b', '1.5'],
    'bin/synths/ep2_syn.rb' => [],
    'bin/synths/filter_ping.rb' => [],
    'bin/synths/fm_bass.rb' => [],
    'bin/synths/fm_bell.rb' => [],
    'bin/synths/fm_bellpad.rb' => [],
    'bin/synths/fm_brass.rb' => [],
    'bin/synths/fm_chain.rb' => ['--no-table'],
    'bin/synths/fm_drumbass.rb' => [],
    'bin/synths/fm_epiano.rb' => [],
    'bin/synths/fm_experimental_bell.rb' => [],
    'bin/synths/fm_kick.rb' => [],
    'bin/synths/fm_synth.rb' => [],
    'bin/synths/funk.rb' => ['-p', 'choir', '-d', '1'],
    'bin/synths/jungle.rb' => ['-p', 'breaks', '-c', '4000'],
    'bin/synths/pluck.rb' => ['--stretch', '1', '--damping', '4'],
    'bin/synths/sinewave.rb' => [],
    'bin/synths/sq80_voice.rb' => ['-p', 'flutter_pad', '--cutoff', '700'],
    'bin/synths/stereo_graph_synth_example.rb' => [],
    'bin/synths/vocal_lead.rb' => ['-V', 'i,a,u', '-j', '0.2'],
    'bin/synths/wavetable_bass.rb' => [],
    'bin/wavetable_pr_example.rb' => [],
  }.freeze

  synths.each do |script, args|
    describe script do
      outfile = File.join(out_dir, "smoke_#{File.basename(script, '.rb')}.flac")
      key = "#{script} render"
      runs.add(key, "#{script.shellescape} -q -f #{args.shelljoin} spec/test_data/c2_sustain.mid #{outfile.shellescape}", env: shared_env)

      it 'prints its header and options with --help' do
        # Forked (see ForkScript); the render below is a real process run
        text, status = fork_script(script, '--help')
        expect(status).to be_success, text
        header = File.readlines(script)[1].delete_prefix('#').strip
        expect(text).to include(header, '--output', '--input MIDI')
      end

      it 'plays a MIDI file into an audio file', smoke_run: key do
        text, status = runs.take(key)
        expect(status).to be_success, text
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

  # True if the script's own spec (spec/bin/.../NAME_spec.rb) runs it as a
  # real process (backticks, IO.popen, or run_script(real: true)), so the
  # smoke --help may fork without losing a real-process run.
  real_run_elsewhere = ->(script) {
    rel = script.delete_prefix('bin/').delete_suffix('.rb')
    spec = "spec/bin/#{rel}_spec.rb"
    File.exist?(spec) && File.read(spec).match?(/`[^`]*#{Regexp.escape(script)}|IO\.popen|real: true/)
  }

  general.each do |script|
    describe script do
      real = !real_run_elsewhere.(script)
      key = "#{script} --help"
      runs.add(key, "#{script.shellescape} --help", env: shared_env) if real

      it 'prints its header and options with --help', smoke_run: (key if real) do
        if real
          # A real process run: this is the only run of the script in specs
          text, status = runs.take(key)
        else
          # Forked (see ForkScript); the script's own spec runs it as a
          # real process
          text, status = fork_script(script, '--help')
        end
        expect(status).to be_success, text
        header = File.readlines(script)[1].delete_prefix('#').strip
        expect(text).to include(header, "Options for #{File.basename(script)}", '--help')
      end
    end
  end

  songs.each do |script, args|
    describe script do
      outfile = File.join(out_dir, "smoke_#{File.basename(script, '.rb')}.flac")
      key = "#{script} render"
      # (Loop Church records the master bus with rec_audio)
      env = script == 'bin/songs/loop_church.rb' ? { 'LOOP_CHURCH_AUDIO' => File.join(out_dir, 'rec_audio.flac') } : {}
      runs.add(key, "#{script.shellescape} -q -f #{args.shelljoin} #{outfile.shellescape}", env: shared_env.merge(env))

      it 'prints its header and options with --help' do
        # Forked (see ForkScript); the render below is a real process run
        text, status = fork_script(script, '--help')
        expect(status).to be_success, text
        header = File.readlines(script)[1].delete_prefix('#').strip
        expect(text).to include(header, '--output', '--bars')
      end

      it 'renders a short file', smoke_run: key do
        text, status = runs.take(key)
        expect(status).to be_success, text
        expect(text).to include("to #{outfile}")

        data = MB::Sound.read(outfile)
        expect(data.length).to eq(2)
        expect(data[0].length).to be >= 48000 * 0.5 # at least half a bar at up to 240 BPM
      end
    end
  end

  # One song rendered to its end: half-bar renders never reach end-of-song
  # cases like one-shot clips ending inside a buffer (fixes-14: drums_808's
  # crash clip at bar 13 crashed every full render, "trigger has 685
  # samples, not 800").  About 10 s.
  describe 'bin/songs/drums_808.rb (full length)' do
    outfile = File.join(out_dir, 'smoke_drums_808_full.flac')
    runs.add('drums_808 full render', "bin/songs/drums_808.rb -q -f #{outfile.shellescape}", env: shared_env)

    it 'renders to its end and tail', smoke_run: 'drums_808 full render' do
      text, status = runs.take('drums_808 full render')
      expect(status).to be_success, text

      data = MB::Sound.read(outfile)
      expect(data[0].length).to be >= (48000 * 60 * 4 * 16 / 112.0).floor # 16 bars at 112 BPM
    end
  end
end
