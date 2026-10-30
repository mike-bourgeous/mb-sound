require_relative 'memcheck_parallel'

RSpec.describe(MemcheckParallel) do
  let(:weights) { { 'a' => 10.0, 'b' => 8.0, 'c' => 5.0, 'd' => 4.0, 'e' => 3.0 } }
  let(:weight) { ->(f) { weights.fetch(f) } }

  describe '.partition' do
    it 'puts the longest files first into the least loaded group' do
      groups = MemcheckParallel.partition(weights.keys, 2, weight)
      expect(groups).to eq([[%w[a d], 14.0], [%w[b c e], 16.0]])
    end

    it 'leaves out empty groups' do
      expect(MemcheckParallel.partition(%w[a b], 4, weight).length).to eq(2)
    end
  end

  describe '.default_count' do
    let(:files) { weights.keys }

    it 'takes the fewest processes within 10% of the best expected time' do
      # 31, 17, 12, 11, 11 s with 1-5 processes (1 s startup each): 3 is enough
      count, reason = MemcheckParallel.default_count(files, weight, startup: 1.0, env: {}, cpus: 16, memory: 64 * 1024**3)
      times = (1..5).map { |n| MemcheckParallel.expected_seconds(files, n, weight, 1.0) }
      expect(times.min).to eq(11.0)
      expect(times).to eq([31.0, 17.0, 12.0, 11.0, 11.0])
      expect(count).to eq(3)
      expect(reason).to match(/at most 5: half of 16 CPUs/)
    end

    it 'is limited by available memory and CPUs' do
      count, = MemcheckParallel.default_count(files, weight, startup: 0, env: {}, cpus: 16, memory: MemcheckParallel::MEMORY_PER_PROCESS * 1.5)
      expect(count).to eq(1)
      count, = MemcheckParallel.default_count(files, weight, startup: 0, env: {}, cpus: 4, memory: nil)
      expect(count).to eq(2)
    end

    it 'takes MEMCHECK_PARALLEL when set' do
      expect(MemcheckParallel.default_count(files, weight, startup: 0, env: { 'MEMCHECK_PARALLEL' => '3' })).to eq([3, 'MEMCHECK_PARALLEL'])
    end
  end

  describe '.estimator' do
    it 'uses memcheck times, else native times scaled by the median slowdown' do
      table = { 'files' => { 'x' => { 'seconds' => 20.0 }, 'y' => { 'seconds' => 90.0 }, 'z' => { 'seconds' => 30.0 } } }
      native = { 'x' => 1.0, 'y' => 3.0, 'z' => 2.0, 'new' => 2.0 }
      est = MemcheckParallel.estimator(table, native)
      expect(est.('x')).to eq(20.0)
      expect(est.('new')).to eq(40.0) # median slowdown of 15, 20, 30
    end
  end

  describe '.file_times_from_json' do
    it 'sums example times per file' do
      json = { 'examples' => [
        { 'file_path' => './spec/a_spec.rb', 'run_time' => 1.5 },
        { 'file_path' => './spec/a_spec.rb', 'run_time' => 0.5 },
        { 'file_path' => 'spec/b_spec.rb', 'run_time' => 3.0 },
      ] }
      expect(MemcheckParallel.file_times_from_json(json)).to eq(
        'spec/a_spec.rb' => { 'seconds' => 2.0, 'examples' => 2 },
        'spec/b_spec.rb' => { 'seconds' => 3.0, 'examples' => 1 },
      )
    end
  end

  describe '.tree_rss' do
    it 'sums a process and its descendants' do
      table = { 1 => [0, 100], 2 => [1, 10], 3 => [2, 1], 4 => [0, 1000] }
      expect(MemcheckParallel.tree_rss(1, table)).to eq(111)
    end

    it 'measures this process' do
      expect(MemcheckParallel.tree_rss(Process.pid, MemcheckParallel.process_table)).to be > 1024**2
    end
  end

  # The whole runner with a stand-in for Valgrind that writes an XML file
  # (with an invalid read for bad_spec.rb's process) and runs rspec natively
  describe '.run' do
    before(:all) { require 'ruby_memcheck' }

    let(:dir) { File.dirname(tmp_path('x')) }
    let(:fake_valgrind) {
      path = File.join(dir, 'fake_valgrind')
      File.write(path, <<~'SH')
        #!/bin/sh
        xml=
        while [ $# -gt 0 ]; do
          case "$1" in
            --xml-file=*) xml="${1#--xml-file=}" ;;
            --*) ;;
            *) break ;;
          esac
          shift
        done
        xml=$(echo "$xml" | sed "s/%p/$$/")
        error=
        case "$*" in
          *bad_spec.rb*) error='<error><kind>InvalidRead</kind><what>Invalid read of size 4</what><stack><frame><fn>mb_fake</fn><obj>/x/fake.so</obj></frame></stack></error>' ;;
        esac
        printf '<?xml version="1.0"?>\n<valgrindoutput>\n%s\n</valgrindoutput>\n' "$error" > "$xml"
        exec "$@"
      SH
      File.chmod(0o755, path)
      path
    }

    def spec_file(name, body)
      path = File.join(dir, name)
      File.write(path, "RSpec.describe('#{name}') { #{body} }\n")
      path
    end

    it 'runs groups in parallel, merging times and reporting each process' do
      files = [
        spec_file('good_spec.rb', "it('passes') { expect(ENV['FAKE_ENV']).to eq('1') }; it('again') { }"),
        spec_file('bad_spec.rb', "it('passes too') { }"),
        spec_file('failing_spec.rb', "it('fails') { expect(1).to eq(2) }"),
      ]
      table = File.join(dir, 'table.json')
      File.write(table, JSON.generate('files' => {}))
      times = File.join(dir, 'times.json')
      out = StringIO.new
      config_for = ->(io) {
        RubyMemcheck::Configuration.new(valgrind: fake_valgrind, valgrind_options: [], output_io: io,
                                        valgrind_suppressions_dir: File.join(dir, 'none'), temp_dir: Dir.mktmpdir(nil, dir))
      }

      expect {
        MemcheckParallel.run(files, config_for: config_for, env: { 'FAKE_ENV' => '1' }, count: 3, out: out,
                             out_dir: File.join(dir, 'logs'), times_path: times, table_path: table)
      }.to raise_error(MemcheckParallel::Failed, /1 of 3 processes failed, 1 with Valgrind errors/)

      text = out.string
      expect(text).to match(/3 spec files in 3 Valgrind processes/)
      expect(text).to match(/Valgrind errors in a process running \S*bad_spec\.rb:\nInvalid read of size 4\n  mb_fake/)
      expect(text).to match(%r{FAILED \(1\).*see \S*logs/\d\.log})
      expect(text).to match(/expected: 2\s+got: 1/)

      merged = JSON.parse(File.read(times))
      expect(merged['summary']).to include('example_count' => 4, 'failure_count' => 1)
      expect(merged['processes'].map { |p| p['exit'] }.sort).to eq([0, 0, 1])
      expect(merged['processes'].map { |p| p['peak_rss'] }).to all(be > 0)

      # Only processes that passed record times
      recorded = JSON.parse(File.read(table))
      expect(recorded['files'].keys.map { |f| File.basename(f) }).to contain_exactly('good_spec.rb', 'bad_spec.rb')
      expect(recorded['files'].values.map { |v| v['examples'] }.sort).to eq([1, 2])
      expect(recorded['startup']).to be > 0
    end
  end
end
