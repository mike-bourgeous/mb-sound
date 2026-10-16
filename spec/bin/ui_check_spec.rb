require 'pty'

RSpec.describe('bin/ui_check.rb', :aggregate_failures) do
  it 'says so without a terminal' do
    text = `bin/ui_check.rb < /dev/null 2>&1`
    expect($?).to be_success
    expect(text).to include('Not a terminal')
  end

  it 'reports what a terminal answers (here UI::VT on a pty)' do
    vt = MB::Sound::UI::VT.new(24, 80, scrollback: 0)
    r, w, pid = PTY.spawn('bin/ui_check.rb', '-t', '3')
    out = +''
    loop do
      d = r.readpartial(65_536)
      out << d
      vt.feed(d)
      reply = vt.take_replies
      w.write(reply) unless reply.empty?
    rescue EOFError, Errno::EIO
      break
    end
    Process.wait(pid)
    expect($?).to be_success
    text = MB::U.remove_ansi(out)
    expect(text).to include('Ambiguous width:   1 column')
    expect(text).to match(/Mode 2004: +yes/)
    expect(text).to match(/Mode 2026: +not recognized/)
    expect(text).to include('Device attributes: ?62;22')
    expect(text).to include('Size:              24 rows x 80 columns')
    expect(vt.alt?).to eq(false)
  ensure
    r&.close
    w&.close
  end
end
