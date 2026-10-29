require 'pry'

# The REPL pane's pty host (research-ui-4 option (a2)).
RSpec.describe(MB::Term::Input::ReplHost, :aggregate_failures) do
  after do
    @host&.stop
  end

  # A screen switch copies the REPL's lines right after the console wrote
  # them; the pty's reader thread (low priority) may not have fed them to
  # the VT yet (the Mac's sound_ui_switch_spec failure, 2026-10-17: the
  # replayed line read "ui :min").  #sync_output waits for them.
  it 'waits in #sync_output until the VT has everything the program wrote, however far behind the reader is' do
    prompt = Pry::Prompt.new('host-spec', 'host spec', [proc { 'h> ' }, proc { 'h* ' }])
    @host = described_class.new(rows: 8, cols: 60, mode: :thread, pry: { prompt: prompt, color: false, pager: false })
    @host.start
    d = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    sleep 0.02 until @host.vt.text.include?('h> ') || Process.clock_gettime(Process::CLOCK_MONOTONIC) > d
    expect(@host.vt.text).to include('h> ')

    held = Queue.new
    release = Queue.new
    holder = Thread.new { @host.synchronize { held << true; release.pop } } # (the reader can't feed meanwhile)
    held.pop
    @host.instance_variable_get(:@slave).write("written by the program\r\n")
    sleep 0.1
    expect(@host.vt.text).not_to include('written by the program') # (the reader is behind)
    Thread.new { sleep 0.2; release << true }
    expect(@host.sync_output).to eq(true)
    expect(@host.vt.text).to include('written by the program')
    holder.join
  end

  it 'returns false from #sync_output when not hosting' do
    @host = described_class.new(rows: 8, cols: 60, mode: :thread)
    expect(@host.sync_output).to eq(false)
  end
end

RSpec.describe('MB::Term::Input::ReplHost :command', :aggregate_failures) do
  after { @host&.stop }

  def wait_for(timeout = 10)
    d = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.01 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > d
    yield
  end

  it 'runs a program on the pty at the host\'s size, feeding the VT and a mirror, and sees it end' do
    mirrored = +''.b
    mirror = Object.new
    mirror.define_singleton_method(:write) { |b| mirrored << b }
    @host = MB::Term::Input::ReplHost.new(rows: 7, cols: 33, mode: :command, command: ['sh', '-c', 'stty size; read line; echo "got $line"'])
    @host.mirror = mirror
    @host.start
    expect(wait_for { @host.vt.text.include?('7 33') }).to eq(true)
    @host.write("hello\r")
    expect(wait_for { @host.vt.text.include?('got hello') }).to eq(true)
    expect(wait_for { @host.exited? }).to eq(true)
    expect(@host.status.success?).to eq(true)
    expect(mirrored).to include('7 33', 'got hello')
  end

  it 'interrupts with ^C through the line discipline and hangs up on #stop' do
    @host = MB::Term::Input::ReplHost.new(rows: 5, cols: 40, mode: :command, command: ['sh', '-c', 'trap "echo caught" INT; echo ready; while :; do sleep 0.05; done'])
    @host.start
    expect(wait_for { @host.vt.text.include?('ready') }).to eq(true)
    @host.interrupt
    expect(wait_for { @host.vt.text.include?('caught') }).to eq(true)
    @host.stop
    expect(@host.active?).to eq(false)
  end

  it 'needs a command' do
    expect { MB::Term::Input::ReplHost.new(rows: 5, cols: 40, mode: :command) }.to raise_error(ArgumentError, /needs a command/)
  end
end

RSpec.describe('MB::Term::Input::ReplHost :command replies', :aggregate_failures) do
  after { @host&.stop }

  it 'answers a program\'s cursor position query through the pty' do
    @host = MB::Term::Input::ReplHost.new(rows: 6, cols: 60, mode: :command, command: ['sh', '-c', 'printf "abc"; stty raw -echo; printf "\033[6n"; dd bs=1 count=6 2>/dev/null | od -c | head -1; stty sane'])
    @host.start
    d = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    sleep 0.01 until @host.vt.text.include?('033') || Process.clock_gettime(Process::CLOCK_MONOTONIC) > d
    expect(@host.vt.text).to include('033   [   1   ;   4   R')
  end
end
