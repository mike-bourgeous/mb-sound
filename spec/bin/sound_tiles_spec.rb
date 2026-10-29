require_relative '../support/ui_helpers'

# The console in a terminal (a pty read by UI::VT), entering the tiled
# screen: the running Pry moves into the REPL pane (:adopt), output from
# `puts`, stderr, and Ctrl-C behave as in a terminal, NAV keys work, and
# `ui off` and `exit` give the terminal back.
RSpec.describe('bin/sound.rb with ui :tiles', :aggregate_failures) do
  it 'moves the console into the REPL pane and back' do
    require 'pty'
    # (scrollback kept: the Ctrl-Z note below may scroll off the top when
    # more output follows it under load; omnibus15)
    vt = MB::Sound::UI::VT.new(30, 110, scrollback: 500)
    lock = Mutex.new
    env = { 'MB_SOUND_HELP_DIR' => tmp_path('help'), 'COLUMNS' => '110', 'LINES' => '30', 'OUTPUT_TYPE' => 'null' }
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
    # The screen and the lines scrolled off it
    all_text = -> { lock.synchronize { (vt.scrollback.map { |row| row.text.delete("\0") } + vt.lines).join("\n") } }
    wait = lambda { |what, t = 20, of: text|
      d = MB::U.clock_now + t
      until MB::U.clock_now > d
        s = of.call
        return true if what.is_a?(Regexp) ? s.match?(what) : s.include?(what)
        sleep 0.03
      end
      false
    }
    type = ->(s) { s.each_char { |c| w.write(c); sleep 0.003 } }

    expect(wait.(/MB::Sound\(0\) >/, 60)).to eq(true), text.call
    type.("ui :tiles\r")
    expect(wait.(' REPL ')).to eq(true), text.call
    expect(lock.synchronize { vt.alt? }).to eq(true)

    type.("puts 'from puts'; $stderr.puts 'from stderr'; 6 * 7\r")
    expect(wait.('=> 42')).to eq(true), text.call
    expect(text.call).to include('from puts', 'from stderr')

    # Ctrl-C during an evaluation interrupts it, as in a terminal
    type.("sleep 20\r")
    sleep 0.4
    w.write("\x03")
    expect(wait.('Interrupt')).to eq(true), text.call

    # NAV: zoom the REPL and back
    w.write("\x1d")
    expect(wait.(' NAV ')).to eq(true)
    type.('z')
    expect(wait.('(zoomed)')).to eq(true)
    type.('zi')
    expect(wait.(' REPL ')).to eq(true)

    # Ctrl-Z hides the tiles (the session plays on); `fg` brings them back
    type.("bg :hum, 110.hz.triangle.at(-30.db)\r")
    expect(wait.(/bg :hum lands|bg :hum landed/)).to eq(true), text.call # (the command's result: Ctrl-Z after the line ran)
    w.write("\x1a")
    d = MB::U.clock_now + 10
    sleep 0.05 while lock.synchronize { vt.alt? } && MB::U.clock_now < d
    expect(lock.synchronize { vt.alt? }).to eq(false), text.call
    # (on the screen or scrolled off it: under load, warnings printed after
    # it pushed it off a scrollback-less VT, sound-design-ui-2's spec:full)
    expect(wait.('tiles hidden; the session plays on', of: all_text)).to eq(true), all_text.call.lines.last(40).join
    type.("players.keys\r")
    expect(wait.('[:hum]')).to eq(true), text.call # still playing
    type.("jobs\r")
    expect(wait.('[ui]+ hidden   ui :tiles')).to eq(true), text.call
    expect(wait.('[bg]  playing   :hum')).to eq(true), text.call # (the next line of the same output: wait for it too)
    type.("fg\r") # as a shell's fg
    expect(wait.(' REPL ')).to eq(true), text.call
    expect(lock.synchronize { vt.alt? }).to eq(true)
    expect(wait.('from puts')).to eq(true), text.call # the pane's scrollback came back
    type.("stop :hum, fade: 0\r")

    type.("ui off\r")
    d = MB::U.clock_now + 10
    sleep 0.05 while lock.synchronize { vt.alt? } && MB::U.clock_now < d
    expect(lock.synchronize { vt.alt? }).to eq(false), text.call
    type.("1 + 2\r")
    expect(wait.('=> 3')).to eq(true), text.call

    # exit with the tiles on: at_exit gives the terminal back
    type.("ui :tiles\r")
    expect(wait.(' REPL ')).to eq(true)
    type.("exit\r")
    Process.wait(pid)
    expect($?.success?).to eq(true)
    sleep 0.1
    expect(lock.synchronize { [vt.alt?, vt.cursor_visible?, vt.bracketed_paste?] }).to eq([false, true, false])
  ensure
    begin
      Process.kill(:KILL, pid) if pid && Process.waitpid(pid, Process::WNOHANG).nil?
    rescue SystemCallError
      nil
    end
    r&.close
    w&.close
    reader&.join(1)
  end
end
