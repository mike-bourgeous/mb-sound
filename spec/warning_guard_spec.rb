# The spec-side warning guard (spec/support/warning_guard.rb).  Each example
# drains what it records with WarningGuard.take / take_subprocess, so the
# guard's own after hook doesn't fail it.
RSpec.describe(WarningGuard) do
  it 'records a warning printed to the real stderr, with where it came from and the example' do
    # (Warning.warn would print it after this returns true, as without the
    # guard; called directly here to keep the suite's output clean)
    line = __LINE__ + 1
    expect(WarningGuard.handle("warning guard spec: a stray warning\n", nil)).to eq(true)
    records = WarningGuard.take
    expect(records.length).to eq(1)
    expect(records[0].message).to eq("warning guard spec: a stray warning\n")
    expect(records[0].origin).to eq("#{__FILE__}:#{line}")
    expect(records[0].example).to eq(RSpec.current_example.location)
    expect(records[0].report_only).to eq(false)
  end

  it 'leaves warnings printed under an output matcher to the matcher' do
    expect { warn 'expected' }.to output("expected\n").to_stderr
    expect { warn 'expected' }.to output("expected\n").to_stderr_from_any_process
    expect(WarningGuard.take).to be_empty
  end

  it 'records :deprecated warnings, and lets allowed ones through silently (Ruby leaves that category off)' do
    expect(WarningGuard.handle("x.rb:1: warning: something old\n", :deprecated)).to eq(true)
    expect(WarningGuard.take.map(&:category)).to eq(['deprecated'])

    allowed = "/usr/local/bundle/gems/prettyprint-0.2.0/lib/prettyprint.rb:184: warning: literal string will be frozen in the future\n"
    expect(WarningGuard.handle(allowed, :deprecated)).to eq(false)
    expect(WarningGuard.take).to be_empty
  end

  it 'records :performance warnings without printing them, even under an output matcher' do
    msg = "x.rb:1: warning: The class X reached 8 shape variations\n"
    expect(WarningGuard.handle(msg, :performance)).to eq(false)
    expect { expect(WarningGuard.handle(msg, :performance)).to eq(false) }.not_to output.to_stderr
    records = WarningGuard.take
    expect(records.map(&:category)).to eq(['performance', 'performance'])
    expect(records.map(&:report_only)).to eq([WarningGuard::REPORT_ONLY.include?('performance')] * 2)
  end

  it 'fails :performance warnings unless MB_SOUND_WARNINGS_PERFORMANCE=report' do
    expected = ENV['MB_SOUND_WARNINGS_PERFORMANCE'] == 'report' ? ['performance'] : []
    expect(WarningGuard::REPORT_ONLY).to eq(expected)
  end

  it 'adds a hint to failures from shape variation warnings' do
    rec = WarningGuard::Record.new(message: "x.rb:1: warning: The class X reached 8 shape variations\n", category: 'performance')
    expect(WarningGuard.message_for([rec], 'intro')).to include('GraphNode::IvarPreset')
    expect(WarningGuard.message_for([WarningGuard::Record.new(message: 'other')], 'intro')).not_to include('IvarPreset')
  end

  it 'collects warnings from Ruby subprocesses, with their script' do
    script = tmp_path('warns.rb')
    File.write(script, "warn 'from a child'\n")
    out = IO.popen(['ruby', script], err: [:child, :out], &:read)
    expect(out).to eq("from a child\n")

    records = WarningGuard.take_subprocess
    expect(records.map(&:to_s)).to eq(["#{script}:1: from a child (in #{script})"])
  end

  it 'collects warnings from fork_script children, without $VERBOSE (as in a new process)' do
    script = tmp_path('fork_warns.rb')
    File.write(script, "warn 'forked' if $VERBOSE == false\n")
    out, status = fork_script(script)
    expect(status).to be_success
    expect(out).to eq("forked\n")
    expect(WarningGuard.take_subprocess.map(&:message)).to eq(["forked\n"])
  end
end
