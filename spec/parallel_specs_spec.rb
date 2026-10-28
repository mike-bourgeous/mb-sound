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

  it 'reports errors outside examples, such as a spec file that does not load (dropouts-2)' do
    write_json(0, [example('spec/a_spec.rb', 0.5)])
    File.write(File.join(out_dir, '1.json'), JSON.generate('examples' => [example('spec/b_spec.rb', 0.25)], 'summary' => { 'errors_outside_of_examples_count' => 1 }))
    ok, output = report([['spec/a_spec.rb'], ['spec/b_spec.rb', 'spec/broken_spec.rb']], [status, status(code: 1)])
    expect(ok).to eq(false)
    expect(output).to include('2 examples, 0 failures, 0 pending, 1 errors outside examples')
    expect(output).to match(/process 1 had 1 error outside examples/)
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

  it 'lists examples that grew RSS over RSS_GROWTH_MB, largest first' do
    write_json(0, [example('spec/a_spec.rb', 0.5)])
    File.write(File.join(out_dir, '0.rss.json'), JSON.generate([
      { 'example' => './spec/a_spec.rb:3', 'description' => 'small', 'grew_mb' => 150, 'rss_mb' => 900 },
      { 'example' => './spec/a_spec.rb:9', 'description' => 'hog', 'grew_mb' => 3500, 'rss_mb' => 4200 },
      { 'example' => './spec/a_spec.rb:7', 'description' => 'big', 'grew_mb' => 250, 'rss_mb' => 1000 },
    ]))

    ok, output = report([['spec/a_spec.rb']], [status])
    expect(ok).to eq(true)
    expect(output).to include("Examples growing RSS over 200 MB")
    expect(output).to match(/\+3500 MB \(to 4200\) spec\/a_spec.rb:9 hog\n.*\+250 MB \(to 1000\) spec\/a_spec.rb:7 big\n/)
    expect(output).not_to include('small')
  end

  describe 'time budgets' do
    let(:budgets) { tmp_path('budgets.yml') }

    def budget_report(examples, yaml, env: nil, scale: 1.0, check: nil)
      File.write(budgets, yaml)
      write_json(0, examples)
      old = ENV['MB_SOUND_SPEC_BUDGET']
      old_check = ENV['MB_SOUND_PLAN_CHECK']
      ENV['MB_SOUND_SPEC_BUDGET'] = env
      ENV['MB_SOUND_PLAN_CHECK'] = check
      result = nil
      output = capture_stdout {
        result = ParallelSpecs.report([examples.map { |e| e['file_path'].delete_prefix('./') }.uniq], [status], 1.5,
                                      out_dir: out_dir, times_path: times_path, budgets_path: budgets, budget_scale: scale)
      }
      [result, output]
    ensure
      ENV['MB_SOUND_SPEC_BUDGET'] = old
      ENV['MB_SOUND_PLAN_CHECK'] = old_check
    end

    let(:yaml) { "default:\n  file: 2\n  example: 1\n" }

    it 'passes files and examples within the default budgets' do
      ok, output = budget_report([example('spec/a_spec.rb', 0.9), example('spec/a_spec.rb', 0.9)], yaml)
      expect(ok).to eq(true)
      expect(output).not_to include('time budget')
    end

    it 'fails on a file or an example over its budget, listing them' do
      ok, output = budget_report([example('spec/a_spec.rb', 1.5), example('spec/a_spec.rb', 0.9)], yaml)
      expect(ok).to eq(false)
      expect(output).to include('Over their time budgets')
      expect(output).to match(%r{2\.40 s >   2\.0 s  spec/a_spec\.rb$})
      expect(output).to match(%r{1\.50 s >   1\.0 s  spec/a_spec\.rb:3 spec/a_spec\.rb works})
    end

    it "takes a file's own budget with a reason, and refuses one without" do
      own = yaml + "files:\n  spec/a_spec.rb:\n    file: 5\n    example: 2\n    reason: renders a whole song twice\n"
      ok, _ = budget_report([example('spec/a_spec.rb', 1.5), example('spec/a_spec.rb', 0.9)], own)
      expect(ok).to eq(true)

      ok, output = budget_report([example('spec/a_spec.rb', 0.5)], yaml + "files:\n  spec/a_spec.rb:\n    file: 5\n")
      expect(ok).to eq(false)
      expect(output).to include('Time budgets without a reason').and include('spec/a_spec.rb')
    end

    it 'only lists them with MB_SOUND_SPEC_BUDGET=report' do
      ok, output = budget_report([example('spec/a_spec.rb', 3)], yaml, env: 'report')
      expect(ok).to eq(true)
      expect(output).to include('not failing')
    end

    it 'only lists them under MB_SOUND_PLAN_CHECK (check mode reruns every block)' do
      ok, output = budget_report([example('spec/a_spec.rb', 3)], yaml, check: '1')
      expect(ok).to eq(true)
      expect(output).to include('MB_SOUND_PLAN_CHECK: not failing')
    end

    it "scales the budgets by the machine's speed" do
      examples = [example('spec/a_spec.rb', 1.5), example('spec/a_spec.rb', 0.9)]
      ok, output = budget_report(examples, yaml, scale: 2.0)
      expect(ok).to eq(true)
      expect(output).not_to include('time budget')

      ok, output = budget_report(examples, yaml, scale: 1.2)
      expect(ok).to eq(false)
      expect(output).to include('scaled x1.20 for this machine')
      expect(output).to match(%r{1\.50 s >   1\.2 s  spec/a_spec\.rb:3})
    end

    it "measures the machine's speed once per CPU and PARALLEL, relative to the reference, never below 1" do
      speeds = tmp_path('speed.json')
      File.write(budgets, yaml + "reference:\n  machine: the runner\n  seconds: 0.25\n")
      File.write(speeds, JSON.generate(ParallelSpecs.host_key(3) => 0.5))
      scale, why = ParallelSpecs.budget_scale(3, budgets_path: budgets, speed_path: speeds)
      expect(scale).to eq(2.0)
      expect(why).to include('host speed 0.500 s').and include('PARALLEL=3').and include('the runner').and include('budgets x2.00')

      File.write(speeds, JSON.generate(ParallelSpecs.host_key(3) => 0.1))
      expect(ParallelSpecs.budget_scale(3, budgets_path: budgets, speed_path: speeds)[0]).to eq(1.0)

      File.write(budgets, yaml)
      expect(ParallelSpecs.budget_scale(3, budgets_path: budgets, speed_path: speeds)).to eq([1.0, nil])
      expect(ParallelSpecs.host_key(3)).to match(/ x\d+, PARALLEL=3\z/)
    end

    it 'has a reference speed in the real budgets' do
      data = YAML.safe_load_file(ParallelSpecs::BUDGETS_PATH)
      expect(data.dig('reference', 'seconds')).to be_a(Numeric).and be > 0
      expect(data.dig('reference', 'machine')).to be_a(String)
      expect(File.exist?(ParallelSpecs::HOST_SPEED_SCRIPT)).to eq(true)
    end

    it 'has a reason for every entry of the real budgets' do
      data = YAML.safe_load_file(ParallelSpecs::BUDGETS_PATH)
      expect(data.fetch('default').keys.sort).to eq(%w[example file])
      (data['files'] || {}).each do |file, e|
        expect(File.exist?(File.join(ParallelSpecs::ROOT, file))).to eq(true), "#{file} is gone; remove its budget"
        expect(e['reason'].to_s.strip.length).to be >= 10, "#{file} needs a reason"
      end
    end
  end

  it 'makes rake spec:parallel exit nonzero when a process crashes' do
    rakefile = File.read(File.expand_path('../Rakefile', __dir__))
    expect(rakefile).to match(/ok = ParallelSpecs\.run(_default)?\b.*\n\s*abort .* unless ok/)
  end

  it 'defaults to half the CPUs, capped by available memory, and lets PARALLEL win' do
    allow(Etc).to receive(:nprocessors).and_return(16)
    allow(ParallelSpecs).to receive(:available_memory).and_return(30 * 1024**3)
    expect(ParallelSpecs.default_count({}).first).to eq(8)
    allow(ParallelSpecs).to receive(:available_memory).and_return(5 * 1024**3)
    expect(ParallelSpecs.default_count({}).first).to eq(3)
    allow(ParallelSpecs).to receive(:available_memory).and_return(nil)
    expect(ParallelSpecs.default_count({}).first).to eq(8)
    allow(Etc).to receive(:nprocessors).and_return(1)
    expect(ParallelSpecs.default_count({}).first).to eq(1)
    expect(ParallelSpecs.default_count({ 'PARALLEL' => '12' })).to eq([12, 'PARALLEL'])
  end
end
