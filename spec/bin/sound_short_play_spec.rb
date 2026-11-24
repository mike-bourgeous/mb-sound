require_relative '../support/ui_helpers'

# A very short foreground `play` in the console (fixes-19, from a merge
# train's pty run: `play 440.hz.sine.at(-20.db).until(0.01)` didn't return
# until the next line was typed, and that line was lost).  Two causes: the
# scope band asked the terminal for the cursor row and waited for the
# report forever (a terminal that doesn't answer ESC[6n, as here, never
# sends one, so the next typed line was read as the report), and the
# playback's end, first checked after the band's setup, missed a sound
# that had started and ended by then and waited 8 s of rendered audio
# (PlaybackEnd::START_SECONDS).
RSpec.describe('bin/sound.rb playing a very short sound', :aggregate_failures) do
  it 'gets the prompt back and runs the next line, on a terminal that never answers cursor queries' do
    require 'pty'
    vt = MB::Term::VT.new(30, 110, scrollback: 0)
    lock = Mutex.new
    env = { 'MB_SOUND_HELP_DIR' => tmp_path('help'), 'COLUMNS' => '110', 'LINES' => '30', 'OUTPUT_TYPE' => 'null', 'PLOT' => '1',
            'MB_SOUND_LEVEL_CHECK' => '0', 'MB_SOUND_CHECKOUT_TMP' => tmp_path('checkout') }
    r, w, pid = PTY.spawn(env, 'bin/sound.rb')
    w.winsize = [30, 110]
    reader = Thread.new do
      loop do
        d = r.readpartial(65_536)
        lock.synchronize do
          vt.feed(d)
          vt.take_replies # (dropped: this terminal answers nothing)
        end
      end
    rescue IOError, SystemCallError
      nil
    end
    text = -> { lock.synchronize { vt.text } }
    wait = lambda { |what, t = 20|
      d = MB::U.clock_now + t
      until MB::U.clock_now > d
        return true if text.call.match?(what)
        sleep 0.03
      end
      false
    }
    type = ->(s) { s.each_char { |c| w.write(c); sleep 0.003 } }

    expect(wait.(/sound\.rb \[1\]/, 90)).to eq(true), text.call
    t = MB::U.clock_now
    type.("play 440.hz.sine.at(-20.db).until(0.01)\r")
    # (Reline's own cursor query at each prompt waits 0.5 s here, the
    # band's another 0.5 s once; before: never, or 8 s)
    expect(wait.(/sound\.rb \[2\]/, 30)).to eq(true), text.call
    expect(MB::U.clock_now - t).to be < 5
    type.("p 6 * 7\r")
    expect(wait.(/^42\s*$/, 10)).to eq(true), text.call
    expect(wait.(/sound\.rb \[3\]/, 10)).to eq(true), text.call
    type.("exit\r")
    Process.wait(pid)
    pid = nil
  ensure
    begin
      Process.kill(:KILL, pid) if pid
      Process.wait(pid) if pid
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    reader&.kill
  end
end
