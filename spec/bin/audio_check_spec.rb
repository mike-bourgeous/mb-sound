require 'shellwords'

RSpec.describe('bin/audio_check.rb') do
  # Real processes on miniaudio's null device (a timer-driven fake sound
  # card), so the device thread and the queue run as they would on hardware.
  def run(*args)
    text = `AUDIO_BACKEND=null bin/audio_check.rb #{args.shelljoin} 2>&1`
    expect($?).to be_success, text
    text
  end

  it 'lists backends and devices' do
    text = run('--list')
    expect(text).to include('miniaudio 0.11.25', 'Backend: null', '0: NULL Playback Device (default)', 'Capture devices:')
    expect(text).not_to include('Opened:')
  end

  it 'plays a click track and reports the queue, latency, and underruns' do
    text = run('-s', '1.2', '--latency', '0.05')
    expect(text).to include(
      'Opened: #<MB::Sound::DeviceOutput null "NULL Playback Device" 2ch 48000Hz>',
      'sample rate: 48000 Hz (asked for 48000)',
      'queue limit: 2400 frames (50.0 ms)',
      'Clicks: left, right, both, both...',
      'Played 1.2 s in'
    )
    expect(text).to match(/Underruns while playing: \d+/)
  end

  it 'explains how to test without a sound card when no backend starts' do
    text = `AUDIO_BACKEND=sndio bin/audio_check.rb 2>&1`
    expect($?).not_to be_success
    expect(text).to include('AUDIO_BACKEND=null')
  end
end
