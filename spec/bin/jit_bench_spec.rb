require 'json'
require 'shellwords'

load File.expand_path('../../bin/jit_bench.rb', __dir__) unless defined?(JitBench)

RSpec.describe('bin/jit_bench.rb') do
  # Results as a run writes them (JSON: String keys), one of each child
  def results
    render = ->(yjit, mean, landing) {
      {
        'kind' => 'render', 'piece' => 'night_bus_flow', 'buffer' => 128, 'yjit' => yjit, 'yjit_requested' => yjit,
        'buffer_ms' => 2.6666, 'mean_ms' => mean, 'p99_ms' => mean * 2, 'max_ms' => mean * 10, 'gc_ms_per_s' => 30.0, 'music_s' => 15.2,
        'landing' => { 'buffers' => 3, 'max_ms' => landing, 'max_bar' => 9.0, 'mean_ms' => landing / 2 },
        'blocks' => { 'count' => 2, 'total_ms' => 40.0, 'max_ms' => 30.0, 'max_desc' => 'intro ends', 'max_bar' => 9.0 },
        'warm_up_s' => (0.5 if yjit), 'form_warm_up_s' => (1.5 if yjit),
      }
    }
    startup = ->(yjit, mb) {
      { 'kind' => 'startup', 'yjit_requested' => yjit, 'steps' => JitBench::STARTUP_ROWS.to_h { |r| [r, 0.1] }.merge('require mb-sound' => mb) }
    }
    {
      'machine' => { 'cpu' => 'Test CPU', 'cores' => 4, 'os' => 'TestOS', 'ruby' => 'ruby 4.0.9', 'yjit_support' => true, 'yjit_threshold' => 5,
                     'ruby_cc' => 'cc', 'ruby_optflags' => '-O3', 'git' => 'abc123', 'date' => '2026-11-01' },
      'options' => { 'repeats' => 1, 'bars' => 8, 'quick' => true },
      'startup' => [startup.(true, 2.0), startup.(false, 1.5)],
      'render' => [render.(true, 1.0, 4.0), render.(false, 2.0, 12.0)],
      'profile' => [render.(false, 2.0, 12.0).merge('kind' => 'profile', 'profile' => {
        'render' => { 'samples' => 100, 'in_c' => 40.0, 'in_kernels' => 20.0, 'files' => [['lib/mb/sound/plan/program.rb', 15.0]], 'self' => [['MB::Sound::Plan::Program#run_c (lib/mb/sound/plan/program.rb)', 15.0, 15.0, [['MB::Sound::FastPlan.run', 15.0]], [['MB::Sound::Plan::Planned#sample', 15.0]]]],
                      'top_frames' => [], 'inclusive' => [['MB::Sound::Session#render_span (lib/mb/sound/session.rb)', 98.0], ['MB::Sound::Synth#sample (lib/mb/sound/synth.rb)', 60.0]] },
        'build' => { 'samples' => 10, 'self' => [['MB::Sound::Synth#initialize (lib/mb/sound/synth.rb)', 40.0, 0.0, [], []]], 'top_frames' => [], 'inclusive' => [] },
      })],
      'failures' => [],
    }
  end

  it 'reports startup, render cost, scene changes, and the profile as Markdown tables' do
    md = JitBench.markdown(results)

    expect(md).to include('## jit_bench: Test CPU (4 threads)', 'call threshold 5', '1 repeat alternating YJIT on and off')
    expect(md).to include('| require mb-sound | 2.00 | 1.50 | 0.75x |')
    expect(md).to include('| night_bus_flow | 128 | 37.5% | 75.0% | 2.00x | 75.0% | 150.0% | 375% | 750% | 30/30 | 15 |')
    expect(md).to include('| night_bus_flow | 128 | 2.67 | 3 | 4.0 | 12.0 | 30.0 | 30.0 | intro ends | 2.00 |')
    expect(md).to include('| 15.0 | 15.0 | `MB::Sound::Plan::Program#run_c (lib/mb/sound/plan/program.rb)` | `MB::Sound::FastPlan.run` 15.0 | `MB::Sound::Plan::Planned#sample` 15.0 |')
    expect(md).to include("In C functions: 40% of the samples (mb-sound's own extensions 20%", 'Self time by file: `lib/mb/sound/plan/program.rb` 15%')
    # (every sample's frames left out of the subtrees)
    expect(md).to include('Inclusive (the subtrees): `MB::Sound::Synth#sample` 60%')
    expect(md).to include('Scene builds (scheduled blocks, 10 samples), self: `MB::Sound::Synth#initialize` 40%')
    expect(md).not_to include('WARNING', 'Failures')
  end

  it 'says when YJIT did not start' do
    md = JitBench.markdown(results.merge('yjit_missing' => true))
    expect(md).to include('WARNING: YJIT did not start')
  end

  it 'refuses unknown pieces before running anything' do
    expect { JitBench.piece('nope') }.to raise_error(ArgumentError, /Unknown piece "nope" \(tunnel_vision, night_bus_flow, techno, dense/)
    expect { JitBench.piece('bin/effects/flanger.rb') }.to raise_error(ArgumentError, /isn't a song script/)
    expect(JitBench.piece('bin/songs/memory_card.rb')[:song]).to end_with('bin/songs/memory_card.rb')
  end

  it 'tells C functions from Ruby methods by their labels' do
    s = JitBench::Sampler
    expect(%w[Thread.current Kernel#is_a? MB::Sound::FastPlan.run Numo::SFloat#sort].map { |l| s.c_label?(l) }).to all(be true)
    expect(['MB::Sound::Tuning.current', 'MB::Sound::Session#process_buffer', 'block in MB::Sound::Synth#sample', '<main>', 'Nope::Missing#x'].map { |l| s.c_label?(l) }).to all(be false)
  end

  it 'samples a thread, folding C functions into the Ruby method calling them' do
    sampler = JitBench::Sampler
    main = Thread.current
    sampler.where = :render
    sampler.start(main)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    x = Numo::SFloat.new(20_000).rand
    # (Thread.pass hands the sampler the GVL: specs run with Ruby's
    # default 100 ms time slice, the bench's children with 10 ms)
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0 < 0.3
      x = x.sort
      Thread.pass
    end
    sampler.where = nil
    sampler.stop
    r = sampler.report(5)[:render]

    expect(r[:samples]).to be > 10
    owner, pct, in_c, cfuncs, = r[:self].first
    expect(owner).to match(/jit_bench_spec\.rb/)
    expect(pct).to be > 50
    expect(in_c).to be > 0
    expect(cfuncs.map(&:first) & ['Numo::SFloat#sort', 'Thread.pass']).not_to be_empty
  end

  it 'times startup steps in children with YJIT on and off', :slow do
    out = tmp_path('jit.json')
    text = `bin/jit_bench.rb --quick -S startup -o #{out.shellescape} 2>&1`
    expect($?).to be_success, text

    expect(text).to match(/\[1\/2\] startup, YJIT on\.\.\. [\d.]+ s/)
    expect(text).to match(/\| require mb-sound \| [\d.]+ \| [\d.]+ \| [\d.]+x \|/)
    expect(text).to match(/\| C extensions \(inside require mb-sound\) \| [\d.]+ \| [\d.]+ \|/)
    expect(text).to include("the tables in #{out.delete_suffix('.json')}.md")

    r = JSON.parse(File.read(out))
    expect(r['startup'].map { |s| [s['yjit_requested'], s['yjit']] }).to eq([[true, true], [false, false]])
    expect(r['startup'].map { |s| s['extensions'] }).to all(be >= 20)
    expect(File.read("#{out.delete_suffix('.json')}.md")).to include('### Startup')
  end
end
