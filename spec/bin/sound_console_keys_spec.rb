require_relative '../support/ui_helpers'

# UI keys where Reline reads the keyboard itself (ux-1 round 3 items 17,
# 18): bin/sound.rb in a pty (read by a UI::VT).  Ctrl-] in the plain
# console and under the band switches to the tiled screen in NAV with the
# line being typed kept; the IDE editing keys edit the line.
RSpec.describe('bin/sound.rb console keys', :aggregate_failures) do
  it 'edits with Ctrl-Backspace and Ctrl-Delete, and Ctrl-] from the console and the band opens the tiles in NAV keeping the line' do
    require 'pty'
    vt = MB::Sound::UI::VT.new(30, 110, scrollback: 0)
    lock = Mutex.new
    env = { 'MB_SOUND_HELP_DIR' => tmp_path('help'), 'COLUMNS' => '110', 'LINES' => '30', 'OUTPUT_TYPE' => 'null', 'INPUTRC' => tmp_path('inputrc') }
    File.write(env['INPUTRC'], "# empty\n")
    r, w, pid = PTY.spawn(env, 'bin/sound.rb')
    w.winsize = [30, 110]
    reader = Thread.new do
      loop do
        d = r.readpartial(65_536)
        lock.synchronize do
          vt.feed(d)
          x = vt.take_replies
          w.write(x) unless x.empty?
        end
      end
    rescue IOError, SystemCallError
      nil
    end

    text = -> { lock.synchronize { vt.text } }
    wait = lambda { |what, t = 20|
      d = MB::U.clock_now + t
      until MB::U.clock_now > d
        s = text.call
        return true if what.is_a?(Regexp) ? s.match?(what) : s.include?(what)
        sleep 0.03
      end
      false
    }
    type = ->(s) { s.each_char { |c| w.write(c); sleep 0.003 } }

    expect(wait.(/MB::Sound\(0\) >/, 60)).to eq(true), text.call

    # Ctrl-Backspace (^H) deletes the word before the cursor
    type.('6 * 7 + 99')
    w.write("\x08")
    sleep 0.1
    type.("0\r")
    expect(wait.('=> 42')).to eq(true), text.call
    # Ctrl-Delete deletes the next word; Ctrl-Shift-Delete to the end
    type.('8 * 5 junk')
    w.write("\e[D" * 5) # before " junk"
    w.write("\e[3;5~")
    sleep 0.1
    type.("\r")
    expect(wait.('=> 40')).to eq(true), text.call
    type.('9 * 9 junk')
    w.write("\e[D" * 5)
    w.write("\e[3;6~")
    sleep 0.1
    type.("\r")
    expect(wait.('=> 81')).to eq(true), text.call

    # Ctrl-] in the plain console: the tiles, in NAV, the line kept
    type.('1 + ')
    w.write("\x1d")
    expect(wait.(' NAV ')).to eq(true), text.call
    expect(lock.synchronize { vt.alt? }).to eq(true)
    w.write("\x1d")
    expect(wait.(' REPL ')).to eq(true), text.call
    type.("2\r")
    expect(wait.('=> 3')).to eq(true), text.call

    # From the band: the band's tiled counterpart, in NAV
    type.("ui :band\r")
    d = MB::U.clock_now + 10
    sleep 0.05 while lock.synchronize { vt.alt? } && MB::U.clock_now < d
    expect(lock.synchronize { vt.alt? }).to eq(false), text.call
    expect(wait.('TRACKS')).to eq(true), text.call
    type.('20 + ')
    w.write("\x1d")
    expect(wait.(' NAV ')).to eq(true), text.call
    type.('i')
    expect(wait.(' REPL ')).to eq(true), text.call
    type.("22\r")
    expect(wait.('=> 42')).to eq(true), text.call

    type.("ui off\r")
    d = MB::U.clock_now + 10
    sleep 0.05 while lock.synchronize { vt.alt? } && MB::U.clock_now < d
    type.("exit\r")
    Timeout.timeout(20) { Process.wait(pid) }
    pid = nil
  ensure
    if pid
      Process.kill(:KILL, pid) rescue nil
      Process.wait(pid) rescue nil
    end
    reader&.kill
    [r, w].each { |io| io&.close rescue nil }
  end
end
