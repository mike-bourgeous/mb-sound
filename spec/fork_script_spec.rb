# The fork_script helper (spec/support/fork_script.rb).
RSpec.describe(ForkScript) do
  it 'runs a script in a fork, returning its output and status' do
    script = tmp_path('ok.rb')
    File.write(script, "puts ARGV.join(','); $stderr.puts $0; exit 3\n")
    out, status = fork_script(script, 'a', 2)
    expect(out).to eq("a,2\n#{script}\n")
    expect(status.exitstatus).to eq(3)
  end

  it 'stops a hung script after the timeout, with its output and what its threads wait on' do
    script = tmp_path('hang.rb')
    File.write(script, "puts 'before the hang'\nsleep\n")
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { fork_script(script, timeout: 0.5) }.to raise_error(ForkScript::TimedOut) { |e|
      expect(e.message).to include('ran over 0.5 s and was killed', 'before the hang', 'Threads in the spec process at fork')
      expect(e.message).to match(/thread \d+ \S+: /)
    }
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t).to be < 5
  end
end
