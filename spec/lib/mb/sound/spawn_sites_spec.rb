require 'prism'

# Process starts in library code (spawner-1): every one goes through
# MB::Sound::Starter (.spawn, .popen, .capture), which starts it in the
# process starter bin/sound.rb launches before anything plays, so the
# console never forks while audio plays (a fork holds the GVL: a dropout
# risk; spec/support/spawn_guard.rb fails direct starts while a Session
# plays).  This reads lib/ (and the mb-term gem's lib/) with Prism and
# lists every direct start: Process.spawn/fork/exec, Kernel#spawn/system/
# exec/fork without a receiver, backticks and %x, IO.popen, Open3, and
# PTY.spawn.  Any not in ALLOWED fails, naming its file and line.
RSpec.describe('direct process starts in lib/') do
  ROOT = File.expand_path('../../../..', __dir__)

  # Files that may start processes directly, with the reason.
  ALLOWED = {
    'lib/mb/sound/starter.rb' => 'the starter itself: its own launch (at startup, before anything plays) and the direct ' \
                                 'fallback where no starter runs (scripts, forks, a dead starter)',
    'lib/mb/sound/starter/server.rb' => 'the starter\'s own process (plain Ruby, no mb-sound) starts the children',
    'lib/mb/sound/sound_guard/runner.rb' => 'rake golden:check renders each piece in its own process and waits for them ' \
                                            'by pid (a rake task: nothing plays)',
    'lib/mb/sound/sound_guard/golden_set.rb' => 'rake golden tasks read the checkout\'s git state (nothing plays)',
    'lib/mb/sound/plot/make_font.rb' => 'a developer script that rebuilds the plot font with ffmpeg (run by hand)',
    'lib/mb/sound/granular/kernel_ruby.rb' => 'not a process: the Ruby grain kernel\'s own #spawn (a grain)',
    'gems/mb-term/lib/mb/term/input/reline_keys.rb' => 'mb-term reads `stty -a` once per process (memoized) when the ' \
                                                       'prompt is set up, before anything plays; mb-term has no mb-sound',
    'gems/mb-term/lib/mb/term/input/repl_host.rb' => 'mb-term\'s network REPL host runs its program on a PTY (examples/' \
                                                     'share_repl.rb, its own process)',
  }.freeze

  KERNEL = %i[spawn system exec fork].freeze
  RECEIVERS = {
    'Process' => %i[spawn fork exec daemon],
    'Kernel' => %i[spawn system exec fork],
    'IO' => %i[popen],
    'Open3' => %i[capture2 capture2e capture3 popen2 popen2e popen3 pipeline pipeline_r pipeline_w pipeline_rw pipeline_start],
    'PTY' => %i[spawn getpty],
  }.freeze

  # [relative path, line, what] for each direct start in +path+.
  def starts(path)
    rel = path.delete_prefix("#{ROOT}/")
    found = []
    stack = [Prism.parse_file(path).value]
    while (n = stack.pop)
      case n
      when Prism::XStringNode, Prism::InterpolatedXStringNode
        found << [rel, n.location.start_line, 'backticks']
      when Prism::CallNode
        r = n.receiver
        if r.nil? ? KERNEL.include?(n.name) && (n.arguments || n.name == :fork) : RECEIVERS[r.slice.delete_prefix('::')]&.include?(n.name)
          found << [rel, n.location.start_line, [r&.slice, n.name].compact.join('.')]
        end
      end
      stack.concat(n.compact_child_nodes)
    end
    found
  end

  let(:files) { Dir[File.join(ROOT, '{lib,gems/mb-term/lib}/**/*.rb')].sort }

  it 'finds direct starts only in the allowed files' do
    all = files.flat_map { |f| starts(f) }
    bad = all.reject { |rel, _, _| ALLOWED.key?(rel) }
    list = bad.map { |rel, line, what| "#{rel}:#{line} #{what}" }
    expect(list).to eq([]), "direct process starts: #{list.join(', ')}; start processes through MB::Sound::Starter " \
      '(.spawn, .popen, .capture: no fork of the console while audio plays), or add the file to ALLOWED with a reason'
  end

  it 'finds the starts it should (the scanner works)' do
    path = File.join(SpecTmp::ROOT, 'spawn_sites_probe.rb')
    File.write(path, <<~RUBY)
      `date`
      x = %x(date)
      system('true')
      Process.spawn('true')
      IO.popen(%w[true])
      Open3.capture2e('true')
      ::Process.fork { }
      fork
      spawn('true')
      obj.system('not a process')
      MB::Sound::Starter.capture('true')
    RUBY
    got = starts(path).map { |_, line, what| [line, what] }.sort
    expect(got).to eq([[1, 'backticks'], [2, 'backticks'], [3, 'system'], [4, 'Process.spawn'], [5, 'IO.popen'],
                       [6, 'Open3.capture2e'], [7, '::Process.fork'], [8, 'fork'], [9, 'spawn']])
  end

  it 'allows only files that exist and still start processes' do
    ALLOWED.each_key do |rel|
      path = File.join(ROOT, rel)
      expect(File.file?(path)).to eq(true), "#{rel} (ALLOWED) is gone"
      expect(starts(path)).not_to be_empty, "#{rel} (ALLOWED) no longer starts processes: remove it from ALLOWED" if File.file?(path)
    end
  end
end
