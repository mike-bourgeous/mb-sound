# debug_dump (ux-1 item 20).
RSpec.describe(MB::Sound::DebugMethods) do
  it 'writes the state to a folder, each part on its own' do
    session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    MB::Sound::Session.with_context(session: session) do
      session.add(220.hz.triangle.at(-20.db), name: :tri, at: :now)
      3.times { session.process_buffer }
      dir = nil
      expect { dir = MB::Sound.debug_dump(tmp_path('dump')) }.to output(/Wrote/).to_stdout
      files = Dir.children(dir).sort
      expect(files).to include('changes.txt', 'graphs', 'midi.txt', 'now.txt', 'players.txt', 'take.rb', 'threads.txt', 'ui.txt')
      expect(File.read(File.join(dir, 'players.txt'))).to include(':tri')
      expect(File.read(File.join(dir, 'graphs', 'tri.rb'))).to include('220.hz.triangle')
      expect(File.read(File.join(dir, 'threads.txt'))).to include('debug_methods')
    end
  ensure
    session&.close
  end
end
