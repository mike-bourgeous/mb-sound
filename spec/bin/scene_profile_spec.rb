require 'shellwords'

RSpec.describe('bin/scene_profile.rb') do
  it 'profiles the scene changes of an offline render' do
    text = `bin/scene_profile.rb -n 800 --bars 10 -t 3 -w off bin/songs/night_bus_flow.rb 2>&1`
    expect($?).to be_success, text

    expect(text).to match(/night_bus_flow\.rb: offline render, 800-frame buffers, 10 bars in [\d.]+ s, YJIT (on|off), form warm-up off/)
    expect(text).not_to include('form warm-up:')
    expect(text).to match(/^scheduled blocks: \d+, slowest/)
    # The intro's end builds the groove's tracks
    expect(text).to match(/bar +9\.00 intro ends +[\d.]+ ms/)
    expect(text).to match(/Synth lanes [\d.]+/)
    expect(text).to match(/^render buffers: \d+, mean [\d.]+ ms, p99 [\d.]+ ms, max [\d.]+ ms \(a buffer is 16\.67 ms\)/)
    expect(text).to match(/where changes landed: \d+ buffers/)
    expect(text).to match(/bar +\d+\.\d\d +[\d.]+ ms \(CPU [\d.]+, outside players [\d.]+\).*drums/)
    # The render thread's CPU and its time outside the players (omnibus10)
    expect(text).to match(/^  render thread CPU: mean [\d.]+ ms, p99 [\d.]+ ms, max [\d.]+ ms/)
    expect(text).to match(/^  outside the players \(changes, catch-up, master and bus chains\): mean [\d.]+ ms/)
    expect(text).to match(/^  most time outside the players:\n    bar +[\d.]+ +[\d.]+ ms outside players of [\d.]+ ms \(CPU [\d.]+\)/)
  end

  it 'plays a song on an emulated sound card with -R', :slow do
    text = `bin/scene_profile.rb -R -n 512 --bars 1 -t 2 bin/songs/small_talk.rb -- --seed 2 2>&1`
    expect($?).to be_success, text

    expect(text).to match(/small_talk\.rb: realtime, 512-frame buffers, emulated card with a 50 ms queue, 1 bars in [\d.]+ s/)
    expect(text).to match(/^underruns: \d+ \([\d.]+ ms of silence\)/)
    expect(text).to match(/^render buffers: \d+/)
    expect(text).to match(/^  render thread CPU: mean [\d.]+ ms/)
  end

  it 'refuses scripts that are not songs' do
    text, status = fork_script('bin/scene_profile.rb', 'bin/effects/flanger.rb')
    expect(status).not_to be_success
    expect(text).to include("isn't a song script")
  end
end
