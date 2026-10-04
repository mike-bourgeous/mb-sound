require 'shellwords'

RSpec.describe('bin/audio_load_check.rb') do
  it 'plays a reference load through the null sound card and reports each setting' do
    # A real process: loads bin/synths/fm_bass.rb and bin/songs/stereo_drone.rb
    args = ['-s', '2', '--load', 'fm_bass', '--buffers', '800', '--periods', '256', '--latencies', '0.2']
    text = `AUDIO_BACKEND=null bin/audio_load_check.rb #{args.shelljoin} 2>&1`
    expect($?).to be_success, text

    expect(text).to include('Load: fm_bass; 1 settings, 2.0 s each (RUBY_THREAD_TIMESLICE=10)')
    expect(text).to match(/^write  800  period  256  queue  9600 \(200\.0 ms\)  latency .* load mean +\d+% .* underruns \d+/)
    expect(text).not_to include('parammap') # MB::Sound.synth(parameter_map: false)
  end
end
