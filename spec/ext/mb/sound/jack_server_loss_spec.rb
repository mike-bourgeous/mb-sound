require 'open3'

# Closing JACK clients after their server is gone (fix-flaky-1104).  Once a
# client of a process loses its server, libjack's next jack_client_open in
# that process ("Jack server was closed but clients are still allocated,
# cleanup...") closes and deletes every client the process still has, so a
# close afterwards read a deleted client: batch 13's suite segfaulted in
# jack_deactivate closing a FastMIDI output after its stalled dummy server
# dropped it, and FastAudio.jack_close crashed in jack_client_close the same
# way.  Each case runs in a child process (a crash fails the example instead
# of ending the suite) with a server of its own, ended between the opens
# and the closes.
RSpec.describe('JACK clients after their server is gone', :aggregate_failures) do
  before(:each) do
    @jack_error = JackDummy.start
    skip @jack_error if @jack_error
  end

  after(:each) { JackDummy.stop }

  JACK_LOSS_CHILD = <<~'RUBY'.freeze
    require 'bundler/setup'
    require 'mb-sound'
    midi = ARGV[0] == 'midi'
    out = MB::Sound::FastMIDI::Output.new(:jack, 'mbspec_lost_out', nil, 'out') if midi
    MB::Sound::FastAudio.jack_open('mbspec_lost_audio') unless midi
    puts 'open'
    STDOUT.flush
    STDIN.gets
    if midi
      sleep 0.3 # (its client's thread reads the end of the server)
    else
      deadline = MB::U.clock_now + 5
      sleep 0.01 until MB::Sound::FastAudio.jack_info.nil? || MB::U.clock_now > deadline
      puts "lost #{MB::Sound::FastAudio.jack_info.nil?}"
    end
    # (any open now makes libjack delete this process's clients: here, the
    # listing's client)
    p MB::Sound::FastMIDI.input_ports(:jack, 'mbspec_lost_list')
    out&.close
    MB::Sound::FastAudio.jack_close
    puts 'closed'
  RUBY

  # Runs JACK_LOSS_CHILD with +mode+, ending the server once it has opened its client.
  # Returns [stdout, stderr, status].
  def lose_server(mode)
    lib = File.expand_path('../../../../lib', __dir__)
    Open3.popen3(RbConfig.ruby, '-I', lib, '-e', JACK_LOSS_CHILD, mode) do |stdin, stdout, stderr, thread|
      err = Thread.new { stderr.read }
      line = stdout.gets
      expect(line).to eq("open\n"), -> { err.join(30)&.value.to_s } # (stderr only on a failure: it ends with the child)
      st = JackDummy.kill_server
      expect(st.success? || st.signaled?).to eq(true)
      stdin.puts 'go'
      stdin.close
      out = stdout.read
      [line + out, err.value, thread.value]
    end
  end

  it 'closes a FastMIDI output whose server ended' do
    out, err, st = lose_server('midi')
    expect(st.success?).to eq(true), "#{st.inspect}\n#{out}\n#{err.lines.grep_v(/^\h+-\h+ /).first(40).join}"
    expect(out).to end_with("[]\nclosed\n")
  end

  it 'closes the shared FastAudio client whose server ended' do
    out, err, st = lose_server('audio')
    expect(st.success?).to eq(true), "#{st.inspect}\n#{out}\n#{err.lines.grep_v(/^\h+-\h+ /).first(40).join}"
    expect(out).to eq("open\nlost true\n[]\nclosed\n")
  end
end
