require 'pty'
require_relative '../support/ui_helpers'

# The terminal after bin/sound.rb exits (ux-friction-1, the maintainer,
# 2026-11-21: "`exit`ing from the UI didn't restore the terminal echo and I
# had to do `stty sane`"): every way into a screen and out of the console
# leaves the terminal's mode (`stty -g`) as it was before the console
# started.  Ctrl-] and F2 from the plain console enter the tiles while
# Reline holds the terminal raw, so the screen used to put back raw input
# without echo when it left.  A guard: a new way into a screen gets a row.
RSpec.describe('bin/sound.rb terminal mode at exit', :aggregate_failures) do
  # Runs bin/sound.rb under sh on a pty, types +keys+ (each followed by a
  # wait for +wait+ or a pause), exits with +exit_with+, and returns
  # [stty -g before, stty -g after, the screen text].
  def console_modes(keys, exit_with: "exit\r")
    before = tmp_path('before')
    after = tmp_path('after')
    vt = MB::Term::VT.new(30, 120, scrollback: 500)
    lock = Mutex.new
    env = { 'MB_SOUND_HELP_DIR' => tmp_path('help'), 'COLUMNS' => '120', 'LINES' => '30', 'OUTPUT_TYPE' => 'null', 'TERM' => 'xterm-256color' }
    r, w, pid = PTY.spawn(env, 'sh', '-c', "stty sane; stty -g > #{before}; bin/sound.rb; stty -g > #{after}; echo MODES_DONE")
    w.winsize = [30, 120]
    reader = Thread.new do
      loop do
        d = r.readpartial(65_536)
        lock.synchronize { vt.feed(d); x = vt.take_replies; w.write(x) unless x.empty? }
      end
    rescue IOError, SystemCallError
      nil
    end
    text = -> { lock.synchronize { vt.text_between(vt.dropped, vt.dropped + vt.total_lines - 1) } }
    wait = ->(what, t = 30) { wait_until(timeout: t) { text.call.include?(what) } }

    expect(wait.(') >', 60)).to be_truthy, text.call
    keys.each do |k, until_text|
      w.write(k)
      until_text ? expect(wait.(until_text)).to(be_truthy, text.call) : sleep(0.5)
    end
    exit_with.each_char { |c| w.write(c); sleep 0.003 }
    expect(wait.('MODES_DONE', 60)).to be_truthy, text.call
    [File.read(before).strip, File.read(after).strip, text.call]
  ensure
    Process.kill(:KILL, pid) rescue nil if pid
    Process.wait(pid) rescue nil if pid
    reader&.join(2)
  end

  {
    'ui :tiles, then exit' => [["ui :tiles\r", ' REPL ']],
    'Ctrl-] from the console, then exit in the REPL pane' => [["\x1d", ' NAV '], ['i', ' REPL ']],
    'Ctrl-] from the console, ui off, then exit at the plain console' => [["\x1d", ' NAV '], ['i', ' REPL '], ["ui off\r", nil]],
    'F2 from the console, then exit' => [["\eOQ", nil], ["\x1d", nil], ['i', ' REPL ']],
  }.each do |name, keys|
    it "puts the terminal's mode back: #{name}" do
      before, after, screen = console_modes(keys)
      expect(after).to eq(before), screen
    end
  end

  it "puts the terminal's mode back after Ctrl-D in the tiles", :slow do
    before, after, screen = console_modes([["ui :wall\r", ' REPL ']], exit_with: "\x04")
    expect(after).to eq(before), screen
  end
end
