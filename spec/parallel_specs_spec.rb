require_relative 'parallel_specs'

RSpec.describe(ParallelSpecs) do
  let(:out_dir) { File.dirname(tmp_path('parallel/x')).tap { |d| FileUtils.mkdir_p(d) } }
  let(:times_path) { tmp_path('times.json') }

  # A real Process::Status: exit code +code+, or killed by +signal+
  def status(code: 0, signal: nil)
    pid = fork do
      Process.kill(signal, Process.pid) if signal
      exit!(code)
    end
    Process.wait2(pid).last
  end

  def example(file, time, status = 'passed')
    { 'file_path' => "./#{file}", 'run_time' => time, 'status' => status, 'line_number' => 3, 'full_description' => "#{file} works" }
  end

  def write_json(i, examples)
    File.write(File.join(out_dir, "#{i}.json"), JSON.generate('examples' => examples))
  end

  def report(groups, statuses)
    result = nil
    output = capture_stdout { result = ParallelSpecs.report(groups, statuses, 1.5, out_dir: out_dir, times_path: times_path) }
    [result, output]
  end

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end

  it 'passes when every process wrote its report' do
    write_json(0, [example('spec/a_spec.rb', 0.5)])
    write_json(1, [example('spec/b_spec.rb', 0.25)])
    File.write(File.join(out_dir, '0.log'), "..\n")

    ok, output = report([['spec/a_spec.rb'], ['spec/b_spec.rb']], [status, status])
    expect(ok).to eq(true)
    expect(output).to include('2 examples, 0 failures')
    expect(output).not_to include('CRASHED')
    expect(JSON.parse(File.read(times_path))).to eq('spec/a_spec.rb' => 0.5, 'spec/b_spec.rb' => 0.25)
  end

  it 'reports a process that died without its JSON, and still writes the others\' times' do
    File.write(times_path, JSON.generate('spec/old_spec.rb' => 9.0, 'spec/c_spec.rb' => 4.0))
    write_json(0, [example('spec/a_spec.rb', 0.5)])
    File.write(File.join(out_dir, '1.json'), '') # rspec opened it and died
    File.write(File.join(out_dir, '1.log'), "....*.**...[BUG] Segmentation fault at 0x00006068aedf06e4\nmore\n")

    statuses = [status, status(signal: 'ABRT')]
    ok, output = report([['spec/a_spec.rb'], ['spec/c_spec.rb', 'spec/d_spec.rb']], statuses)

    expect(ok).to eq(false)
    expect(output).to match(%r{process 1 CRASHED: it was killed by SIGABRT \(6\) without its JSON report after 11 examples \(log .*1\.log\)})
    expect(output).to include('[BUG] Segmentation fault at 0x00006068aedf06e4')
    expect(output).to include("Its 2 files:\n    spec/c_spec.rb\n    spec/d_spec.rb\n")
    expect(output).to include('1 examples, 0 failures')

    # The crashed group's files keep their earlier times
    expect(JSON.parse(File.read(times_path))).to eq('spec/old_spec.rb' => 9.0, 'spec/c_spec.rb' => 4.0, 'spec/a_spec.rb' => 0.5)
  end

  it 'treats a missing JSON file as a crash, also after a normal exit' do
    write_json(0, [example('spec/a_spec.rb', 0.5, 'failed')])

    ok, output = report([['spec/a_spec.rb'], ['spec/e_spec.rb']], [status(code: 1), status(code: 1)])
    expect(ok).to eq(false)
    expect(output).to include('process 1 CRASHED: it exited with 1 without its JSON report after 0 examples')
    expect(output).to include('spec/e_spec.rb')
    expect(output).to include('spec:parallel: process 0 exited with 1')
    expect(output).to include('rspec ./spec/a_spec.rb:3 # spec/a_spec.rb works')
  end

  it 'lists stray warnings with the examples that printed them, and reported ones apart' do
    write_json(0, [example('spec/a_spec.rb', 0.5, 'failed')])
    File.write(File.join(out_dir, '0.warnings.json'), JSON.generate([
      { 'message' => "oops\n", 'origin' => 'lib/x.rb:3', 'example' => './spec/a_spec.rb:3' },
      { 'message' => "oops\n", 'origin' => 'lib/x.rb:3', 'example' => './spec/a_spec.rb:9' },
      { 'message' => "y.rb:1: warning: old\n", 'category' => 'deprecated', 'process' => 'bin/y.rb' },
      { 'message' => "z.rb:2: warning: The class Z reached 8 shape variations\n", 'category' => 'performance', 'report_only' => true },
    ]))

    ok, output = report([['spec/a_spec.rb']], [status(code: 1)])
    expect(ok).to eq(false)
    expect(output).to include("Reported warnings (1; not failing")
    expect(output).to include('  warning: The class Z reached 8 shape variations [performance]')
    expect(output).to include("Stray warnings (2;")
    expect(output).to include("  lib/x.rb:3: oops\n    from ./spec/a_spec.rb:3, ./spec/a_spec.rb:9")
    expect(output).to include("  y.rb:1: warning: old [deprecated] (in bin/y.rb)\n    from outside examples")
  end

  it 'makes rake spec:parallel exit nonzero when a process crashes' do
    rakefile = File.read(File.expand_path('../Rakefile', __dir__))
    expect(rakefile).to match(/ok = ParallelSpecs\.run\(.*\n\s*abort .* unless ok/)
  end
end
