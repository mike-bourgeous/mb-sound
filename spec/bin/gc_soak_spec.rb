require 'shellwords'

RSpec.describe('bin/gc_soak.rb') do
  # A real process: a song played live on the virtual-clock output, GC off
  # once the music starts, sites traced in chunks, one chunk dumped
  it 'plays a song live with GC off and reports its growth, types, and sites' do
    dump = tmp_path('chunk.jsonl')
    text = `bin/gc_soak.rb -n 512 --speed 4 --seconds 6 --window 2 --sites 5 --dump #{dump.shellescape} bin/songs/tempo_song.rb 2>&1`
    expect($?).to be_success, text
    expect(text).to match(/tempo_song\.rb: 512-frame buffers, speed 4\.0x, GC off, YJIT on; [\d.]+ s of audio after the warm-up/)
    expect(text).to match(/first 2 s: \+-?\d+ MB .*after it: -?[\d.]+ MB\/s, [\d.]+ k objects\/s \(render thread [\d.]+ k\/s\)/)
    expect(text).to include('after the first 2 s, by category (objects/s, KB/s):', 'top 5 lines by bytes')
    expect(File.size(dump)).to be > 0
  end

  it 'explains a script that is not a song' do
    text, status = fork_script('bin/gc_soak.rb', 'bin/effects/flanger.rb')
    expect(status).not_to be_success
    expect(text).to include("isn't a song script")
  end

  # The soak (dropouts-2, maintainer 2026-10-28: "I'd like to be able to
  # run for an hour with GC off"): tunnel_vision (buses, ducks, hard sync,
  # reverbs, scene changes) live for a minute of audio with GC off; the
  # steady RSS slope must stay under the budget.  2026-10-28 in the Mac
  # container at 256 frames: master-ai 6.0 MB/s, dropouts-2 1.3.  An hour
  # with 3.5 GB of headroom needs under ~1 MB/s.
  it 'grows less than 2 MB per audio second with GC off (tunnel_vision, 256 frames)', :slow do
    text = `bin/gc_soak.rb -n 256 --speed 1.5 --seconds 75 --window 25 --budget 2.0 bin/songs/tunnel_vision.rb 2>&1`
    expect($?).to be_success, text
    expect(text).to match(/after it: [\d.]+ MB\/s/)
  end
end
