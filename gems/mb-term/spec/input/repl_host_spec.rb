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
