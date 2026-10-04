require 'shellwords'

RSpec.describe('bin/audio_load_check.rb') do
  it 'plays a reference load through the null sound card and reports each setting' do
    # A real process: loads bin/synths/fm_bass.rb and bin/songs/stereo_drone.rb
    args = ['-s', '2', '--loads', 'fm_bass', '--oversample', '1', '--settings', 'safe,800/256/200']
    text = `AUDIO_BACKEND=null bin/audio_load_check.rb #{args.shelljoin} 2>&1`
    expect($?).to be_success, text

    expect(text).to include('1 loads x 2 settings, 2.0 s each, fm_bass oversampled 1x (RUBY_THREAD_TIMESLICE=10)', 'Load: fm_bass')
    expect(text).to match(/^safe +write  800  period  480  queue  4080 \( 85\.0 ms\)  latency .* load mean +\d+% .* spikes +\d+ \(GC \d+ of \d+\)  peak +-\d+\.\d dB  underruns \d+/)
    expect(text).to match(%r{^800/256/200 +write  800  period  256  queue  9600 \(200\.0 ms\)})
    expect(text).not_to include('silent') # each setting gets its own MIDI file and reader
    expect(text).not_to include('parammap') # MB::Sound.synth(parameter_map: false)
  end
end
