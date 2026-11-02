require 'pty'

# bin/record.rb (play-ui-1): the input's meters on the terminal UI's :vis
# band (the old text meters, MB::Sound::Meter, are gone), Ctrl-C closing
# the file.  Records miniaudio's null device (silence).
RSpec.describe('bin/record.rb') do
  it 'records with the input meters on a band, and Ctrl-C closes the file' do
    path = tmp_path('rec.flac')
    vt = MB::Term::VT.new(30, 100, scrollback: 0)
    lock = Mutex.new
    r, w, pid = PTY.spawn({ 'INPUT_TYPE' => 'device', 'AUDIO_BACKEND' => 'null', 'COLUMNS' => '100', 'LINES' => '30' }, 'bin/record.rb', path)
    w.winsize = [30, 100]
    reader = Thread.new do
      loop { d = r.readpartial(65_536); lock.synchronize { vt.feed(d); x = vt.take_replies; w.write(x) unless x.empty? } }
    rescue IOError, SystemCallError
      nil
    end
    text = -> { lock.synchronize { vt.text } }
    d = MB::U.clock_now + 30
    sleep 0.05 until text.call.include?('SCOPE') || MB::U.clock_now > d
    expect(text.call).to include('MASTER', 'SCOPE', 'LUFS')
    w.write("\x03")
    _, status = Process.wait2(pid)
    reader.join(1)
    expect(status).to be_success
    expect(MB::Sound.read(path)[0].length).to be > 0
  ensure
    if pid && !status
      Process.kill(:KILL, pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end
end
