# Song scripts' --from, --to, and --seek (ScriptRunner#run_song; see
# render_window_spec.rb for render(from:, to:, preroll:)).
RSpec.describe(MB::Sound::ScriptRunner, 'render windows') do
  include RenderWindowSong

  after { MB::Sound.rewind }

  it 'renders --from SECTION --to SECTION, and --from BAR with --bars' do
    out = tmp_path('song.flac')
    r = MB::Sound::ScriptRunner.new(:song, {}, argv: [out, '-q', '--from', 'drop', '--to', 'outro'], script: 'bin/example.rb')
    expect { r.run_song(bars: 10) { song } }.to output(/Rendered/).to_stdout
    MB::Sound.rewind
    a = MB::Sound.read(out)
    # The reference at the script's master gain (the default -10 dB)
    whole = tmp_path('whole.flac')
    MB::Sound.render(whole, bars: 4) { song }
    MB::Sound.rewind
    ref = MB::Sound.read(whole)
    start = frame_of(5/2r)
    expect(a[0][0...48000]).to eq(ref[0][start...(start + 48000)])

    r = MB::Sound::ScriptRunner.new(:song, {}, argv: [out, '-q', '-f', '--from', '4', '--bars', '0.5'], script: 'bin/example.rb')
    expect { r.run_song(bars: 10) { song } }.to output(/Rendered/).to_stdout
    MB::Sound.rewind
    b = MB::Sound.read(out)
    start = frame_of(5/2r) # bar 4 is the drop's first bar
    expect(b[0][0...1000]).to eq(ref[0][start...(start + 1000)])
  end

  it 'renders to the end of the song\'s bars with --from alone' do
    out = tmp_path('song.flac')
    r = MB::Sound::ScriptRunner.new(:song, {}, argv: [out, '-q', '--from', '4'], script: 'bin/example.rb')
    expect { r.run_song(bars: 5) { MB::Sound.bpm 168; MB::Sound.bg(:t, 220.hz.sine.at(0.1), fade: 0) } }.to output(/Rendered/).to_stdout
    MB::Sound.rewind
    expect(MB::Sound.read(out)[0].length).to eq((5 * 240 / 168r * 48000).ceil - frame_of(3))
  end

  it 'refuses --seek without --from and --to with --bars' do
    out = tmp_path('song.flac')
    r = MB::Sound::ScriptRunner.new(:song, {}, argv: [out, '-q', '--seek'], script: 'bin/example.rb')
    expect { r.run_song(bars: 2) { song } }.to raise_error(ArgumentError, /--seek goes with --from/)
    r = MB::Sound::ScriptRunner.new(:song, {}, argv: [out, '-q', '--to', '3', '--bars', '1'], script: 'bin/example.rb')
    expect { r.run_song(bars: 2) { song } }.to raise_error(ArgumentError, /--to or --bars/)
  end
end
