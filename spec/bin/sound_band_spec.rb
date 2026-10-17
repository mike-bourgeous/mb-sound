require_relative '../support/ui_helpers'

# The band at the bottom of the console (a pty read by UI::VT): when it
# grows while Pry runs a multi-line command (here the messages strip opening
# for warnings), the command's lines stay on screen and the cursor comes
# back to the prompt (ux-1 r3 item 2: the end line was erased and the
# cursor sat in the band).
RSpec.describe('bin/sound.rb with the band', :aggregate_failures) do
  it 'keeps a multi-line command and the cursor in place when the band grows' do
    require 'pty'
    vt = MB::Sound::UI::VT.new(30, 110, scrollback: 0)
    lock = Mutex.new
    env = { 'MB_SOUND_HELP_DIR' => tmp_path('help'), 'COLUMNS' => '110', 'LINES' => '30', 'OUTPUT_TYPE' => 'null', 'MB_SOUND_LEVEL_CHECK' => '0' }
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
    type.("ui\r")
    expect(wait.('TRACKS')).to eq(true), text.call
    type.("[C2, E2].each do |z|\r")
    sleep 0.2
    type.("warn \"band test \#{z}\"\r")
    sleep 0.2
    type.("end\r")
    expect(wait.('MESSAGES')).to eq(true), text.call
    expect(wait.(/sound\.rb \[3\]/)).to eq(true), text.call
    sleep 0.5 # (the band's next frames)
    lines = lock.synchronize { vt.lines }
    at = lines.index { |l| l.include?('[C2, E2].each do |z|') }
    expect(at).not_to be_nil, text.call
    expect(lines[at + 1]).to include('warn "band test')
    expect(lines[at + 2]).to include('end')
    expect(lines[at + 3]).to include('=> [')
    row, col = lock.synchronize { [vt.row, vt.col] }
    expect(lines[row]).to start_with('sound.rb [3]'), text.call
    expect(col).to eq(lines[row].rstrip.length + 1)
    type.("exit\r")
    Process.wait(pid)
  ensure
    begin
      Process.kill(:KILL, pid) if pid
    rescue Errno::ESRCH
      nil
    end
    reader&.kill
  end
end
