# song_script --take: a scripted run recorded as a take (ScriptRunner#run_song,
# ScriptRunner.replay_song), and replay scripts' options.
RSpec.describe('song_script --take') do
  after { MB::Sound.rewind }

  # A song with a form pick drawn from the root generator, a synth, and a
  # reverb, at a tempo whose bars aren't whole frames.
  let(:song) {
    ->(p) {
      MB::Sound.bpm 150
      set = MB::Sound::Session.current.arrangement
      set.track(:lead) { |c| c.synth(voices: 3) { |v| v.hz.saw.lp4(1500) * v.env(0.01, 0.2, 0.5, 0.3) }.at(-12.db).reverb(:room, mix: 0.2) }
      set.scene(:a, lead: MB::Sound.seq(MB::Sound::C4, MB::Sound::E4, MB::Sound::G4).n8.loop)
      set.scene(:b, lead: MB::Sound.seq(MB::Sound::A3, MB::Sound::C4).n8.transpose(p.shift).loop)
      MB::Sound.flow(on: :now) do
        a 1
        pick :a, :b
        b 1
      end
    }
  }

  def runner(argv)
    MB::Sound::ScriptRunner.new(:song, { shift: [0, Integer, 'Transpose the b section'] }, argv: argv, script: 'bin/example_take_song.rb')
  end

  # The Replay a saved take script builds (without running its main).
  def load_take(path)
    eval(File.read(path).sub(/\.main\(ARGV, __FILE__\)\s*\z/, ''), TOPLEVEL_BINDING, path) # rubocop:disable Security/Eval
  end

  it 'saves a replay that renders the run bit for bit, at other buffer sizes too' do
    out = tmp_path('song.flac')
    take = tmp_path('take.rb')
    MB::Sound.seed(12)
    expect { runner([out, '-q', '--bars', '3', '--shift', '2', '--take', take]).run_song { |p| song.(p) } }
      .to output(/Rendered.*Saved the take to .*take\.rb/m).to_stdout

    text = File.read(take)
    expect(text).to include('ScriptRunner.replay_song("bin/example_take_song.rb", { shift: 2 })')
    expect(text).to include("end.main(ARGV, __FILE__)")
    expect(File.executable?(take)).to eq(true)

    original = MB::Sound.read(out)
    three_bars = (3 * 240 / 150r * 48000).ceil
    [[800], [367, 368]].each do |sizes|
      replay = tmp_path("replay_#{sizes.join('_')}.flac")
      expect { load_take(take).render(replay, buffer_sizes: sizes) }.not_to output.to_stderr
      MB::Sound.rewind
      data = MB::Sound.read(replay)
      expect(data[0][0...three_bars]).to eq(original[0][0...three_bars]), "buffer sizes #{sizes}"
      expect(data[0].abs.max).to be > 0.01
    end
  end

  it 'writes --bpm and non-default parameters into the take line, and leaves defaults out' do
    take = tmp_path('take.rb')
    expect { runner([tmp_path('x.flac'), '-q', '--bars', '0.25', '--bpm', '100', '--take', take]).run_song { |p| song.(p) } }
      .to output(/Saved the take/).to_stdout
    expect(File.read(take)).to include('ScriptRunner.replay_song("bin/example_take_song.rb", bpm: 100.0)')
  end

  it 'refuses --take with a render window' do
    r = runner([tmp_path('x.flac'), '-q', '--take', tmp_path('t.rb'), '--from', '2'])
    expect { r.run_song(bars: 2) { |p| song.(p) } }.to raise_error(ArgumentError, /--take records a whole run/)
  end

  it 'names scripts inside mb-sound relative to its root' do
    root = MB::Sound::ScriptRunner::ROOT
    expect(MB::Sound::ScriptRunner.take_path(File.join(root, 'bin/songs/x.rb'))).to eq('bin/songs/x.rb')
    expect(MB::Sound::ScriptRunner.take_path('/elsewhere/song.rb')).to eq('/elsewhere/song.rb')
  end

  describe 'real processes' do
    it 'records a bin song with --take and replays the saved script with -f and an audio file name' do
      out = tmp_path('blur.flac')
      take = tmp_path('blur_take.rb')
      text, status = run_script('bin/songs/generative_blur.rb', '-q', '-m', 'grains', '-c', '20', '--bars', '0.5', '-o', out, '--take', take, real: true)
      expect(status).to be_success, text
      expect(text).to match(/Saved the take to/)

      replay = tmp_path('replay.flac')
      File.write(replay, 'old') # -f overwrites without asking
      text, status = run_script('ruby', take, '-f', replay, real: true)
      expect(status).to be_success, text
      half_bar = (0.5 * 240 / 84r * 48000).ceil
      expect(MB::Sound.read(replay)[0][0...half_bar]).to eq(MB::Sound.read(out)[0][0...half_bar])
    end
  end
end
