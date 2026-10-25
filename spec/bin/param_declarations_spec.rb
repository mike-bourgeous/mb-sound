require_relative '../support/param_guard'

# The param guard over bin/ (param-1): every script's option
# declarations build MB::Sound::Params (names-table ranges included) that
# give a help line, a knob, and a document line, with defaults in range
# (spec/support/param_guard.rb).  Each script is read in a fork with
# ScriptRunner.declarations_of (loaded with its helper stopping before it
# runs anything), so the scripts' constants stay out of this process.
RSpec.describe('bin/ script param declarations', :aggregate_failures) do
  def root = File.expand_path('../..', __dir__)

  # Scripts without a ScriptingMethods helper, with the reason.
  def without_helper
    {
      'bin/sound.rb' => 'the console',
      'bin/alloc_audit.rb' => 'an OptionParser tool (the 2026-10-19 allocation audit), no script helper',
    }
  end

  # [file, kind, [[problems, built, text], ...]] for one script, from a
  # fork.
  def read_script(file)
    rd, wr = IO.pipe
    pid = fork do
      rd.close
      $stdout.reopen(File::NULL)
      result = begin
        found = MB::Sound::ScriptRunner.declarations_of(file)
        found && [found[0], found[1].map { |sp| [*ParamGuard.check(sp.param), sp.param.to_ruby] }]
      rescue Exception => e # rubocop:disable Lint/RescueException
        [:error, "#{e.class}: #{e.message}"]
      end
      wr.write(Marshal.dump(result))
      wr.close
      exit!(0)
    end
    wr.close
    data = rd.read
    rd.close
    Process.wait(pid)
    Marshal.load(data)
  end

  it 'covers every script with a helper' do
    files = Dir.glob('bin/**/*.rb', base: root).sort
    expect(files.length).to be >= 100
    counts = { scripts: 0, params: 0, knobs: 0, documents: 0 }
    files.each do |f|
      next if without_helper.key?(f)
      result = read_script(File.join(root, f))
      expect(result).not_to be_nil, "#{f} calls no script helper (add it to without_helper with a reason?)"
      next if result.nil?
      expect(result[0]).not_to eq(:error), "#{f}: #{result[1]}"
      next if result[0] == :error
      counts[:scripts] += 1
      result[1].each do |problems, built, text|
        expect(problems).to eq([]), "#{f} #{text}: #{problems.join('; ')}"
        counts[:params] += 1
        counts[:knobs] += 1 if built[:knob]
        counts[:documents] += 1 if built[:document]
      end
    end
    expect(counts[:scripts]).to be >= 100
    expect(counts[:params]).to be >= 400
  end
end
