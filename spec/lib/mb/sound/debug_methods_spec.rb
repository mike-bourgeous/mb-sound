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
      expect(File.read(File.join(dir, 'ui.txt'))).to match(/\Aui (off|hidden|band|tiles).* on \d+x\d+/) # (ui.list first, ux-1 r3 item 28)
    end
  ensure
    session&.close
    MB::Sound.rewind # (a Session on the shared transport: inspection_spec's stamps failed after this ran first)
  end

  it "writes the exception that ended the console and the terminal's name" do
    old = MB::Sound::TerminalInfo.version
    MB::Sound::TerminalInfo.version = 'Konsole 24.08.1'
    e = (raise NoMethodError, "private method 'eval' called for nil" rescue $!)
    dir = nil
    expect { dir = MB::Sound.debug_dump(tmp_path('crash'), exception: e) }.to output(/Wrote/).to_stdout
    expect(File.read(File.join(dir, 'exception.txt'))).to start_with("NoMethodError: private method 'eval'").and include('debug_methods_spec')
    expect(File.read(File.join(dir, 'terminal.txt'))).to include('Terminal:     Konsole 24.08.1').and include('Size:').and include('Environment:')
  ensure
    MB::Sound::TerminalInfo.version = old
  end
end

RSpec.describe(MB::Sound::TerminalInfo) do
  # (.query! runs once per process: each example starts unasked and puts
  # the process's answer back)
  around do |ex|
    saved = [described_class.instance_variable_get(:@queried), described_class.version, described_class.instance_variable_get(:@no_tty)]
    described_class.instance_variable_set(:@queried, false)
    described_class.instance_variable_set(:@no_tty, false)
    described_class.instance_variable_set(:@version, nil)
    ex.run
  ensure
    described_class.instance_variable_set(:@queried, saved[0])
    described_class.instance_variable_set(:@version, saved[1])
    described_class.instance_variable_set(:@no_tty, saved[2])
  end

  it 'asks XTVERSION once on a terminal and gives typed bytes back' do
    require 'pty'
    PTY.open do |master, slave|
      info = described_class
      answer = Thread.new do
        q = +''
        q << master.readpartial(100) until q.include?("\e[c")
        master.write("x\eP>|Konsole 24.08.1\e\\\e[?62;22c")
        q
      end
      expect(info.query!(input: slave, output: slave, timeout: 2)).to eq('Konsole 24.08.1')
      expect(answer.value).to eq("\e[>0q\e[c")
      expect(slave.read_nonblock(10)).to eq('x')
      expect(info.query!(input: slave, output: slave)).to eq('Konsole 24.08.1') # (once)
    end
  end

  it 'asks nothing without a terminal' do
    info = described_class
    out = StringIO.new
    expect(info.query!(input: StringIO.new, output: out)).to be_nil
    expect(out.string).to eq('')
    expect(info.report(output: out, env: { 'TERM' => 'xterm-256color' })).to include('not asked (stdin or stdout is not a terminal)').and include('TERM=xterm-256color')
  end
end
