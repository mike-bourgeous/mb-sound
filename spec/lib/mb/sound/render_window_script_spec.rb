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
    expect { r.run_song(bars: 2) { song } }.to raise_error(MB::Sound::ScriptRunner::InputError, /--seek goes with --from/)
    r = MB::Sound::ScriptRunner.new(:song, {}, argv: [out, '-q', '--to', '3', '--bars', '1'], script: 'bin/example.rb')
    expect { r.run_song(bars: 2) { song } }.to raise_error(MB::Sound::ScriptRunner::InputError, /--to or --bars/)
    r = MB::Sound::ScriptRunner.new(:song, {}, argv: [out, '-q', '--from', '0'], script: 'bin/example.rb')
    expect { r.run_song(bars: 2) { raise 'not built' } }.to raise_error(MB::Sound::ScriptRunner::InputError, '--from is a section, label, or marker name, or a bar number from 1 (got 0)')
  end

  # ux-fix-2: a misspelled --from was checked after the form started (live:
  # after its 2 s warm-up), with different messages live and in renders.
  it 'refuses a --from or --to name the form lacks as the form starts, with one message live and in renders' do
    out = tmp_path('song.flac')
    messages = [['-q'], [out, '-q']].flat_map { |argv|
      ['--from', '--to'].map { |opt|
        r = MB::Sound::ScriptRunner.new(:song, {}, argv: argv + [opt, 'drp'], script: 'bin/example.rb')
        after_form = false
        message = nil
        expect { r.run_song(bars: 2) { song; after_form = true } }.to raise_error(MB::Sound::ScriptRunner::InputError) { |e|
          message = e.message
          expect(MB::Sound::ErrorFormat.message_and_suggestions(e).last).to eq([':drop'])
        }
        expect(after_form).to eq(false)
        expect(MB::Sound::Session.current.arrangement.playback).to be_nil
        expect(MB::Sound::Session.current.arrangement.instance_variable_get(:@form_checks)).to be_empty
        message.sub(opt, 'OPT')
      }
    }
    expect(messages.uniq.length).to eq(1)
    expect(messages.first).to start_with('OPT no section, label, or marker :drp (sections and labels: :intro, :gap, :drop, :outro)')
    expect(File.exist?(out)).to eq(false) # no empty file left behind
  ensure
    MB::Sound.bpm 120
  end
end
