# refine's worker process (hand-tune-2): started while nothing plays (a
# process start holds the GVL), it runs the search in its own process, so
# the console only waits on its progress lines.  Measured live with the
# dropout probe (design/notes/hand_tune.md, Refine): the render thread's
# GVL waits stayed at the idle baseline with the worker, against about
# 1400 waits of up to 20 ms in 30 s with the search in-process.  Here: the
# same proposal as in-process, the refusal to start while a render thread
# runs, and the console process's CPU while a prestarted worker refines
# beside a playing Session.
RSpec.describe(MB::Sound::HandTune::Worker, :aggregate_failures) do
  WK_CODE = 'synth(CLIP, voices: 1) { |v| v.hz.saw.lp4(1234.5, resonance: 0.25) * v.amp_env(0.01, 0.2, 0.5, 0.1) }'.freeze

  after {
    @worker&.close
    MB::Sound::Session.default.close
    MB::Sound.use_output(nil)
    MB::Sound.rewind
  }

  let(:fit) { MB::Sound::FitPatch.save(:worker_fit, WK_CODE, { cutoff: (100.0..8000.0).at(1234.5), resonance: (0.0..1.0).at(0.25) }) }
  let(:reference) { MB::Sound::Sample.new(MB::Sound::HandTune.render(fit.version, { cutoff: 700.0, resonance: 0.4 }, note: 45, hold: 0.3, seconds: 0.5), name: 'ref') }

  # The job for track :lead of +session+ (a fit patch with its reference).
  def job(session, **opts)
    MB::Sound::Session.with_context(session: session) do
      MB::Sound.track(:lead, fit)
      MB::Sound.bg(:lead, MB::Sound.seq(MB::Sound::A2).n4.loop)
      MB::Sound.ab(:lead, reference)
      MB::Sound::HandTune.refine_job(session, :lead, **opts)
    end
  end

  it 'finds what an in-process search finds, and refuses to start while a render thread runs' do
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), channels: 1, realtime: false)
    j = job(s, evals: 12)
    here = MB::Sound::HandTune.refine_run(j)
    @worker = described_class.start
    expect(@worker.wait_ready).to eq(true)
    @worker.submit(j)
    msgs = []
    msgs << @worker.next_message(30) until msgs.last&.key?('result') || msgs.last&.key?('error') || msgs.length > 200
    got = MB::Sound::HandTune::RefineResult.from_json_data(msgs.last.fetch('result'))
    expect(got.values).to eq(here.values)
    expect(got.best).to eq(here.best)
    expect(got.history).to eq(here.history)
    s.close

    @worker.close
    MB::Sound.use_output(MB::Sound::NullOutput.new(channels: 2, buffer_size: 800, sleep: :virtual))
    MB::Sound.bg(:try, 220.hz.sine.at(-30.db))
    Thread.pass until MB::Sound::Session.default.running?
    expect { described_class.start }.to raise_error(ArgumentError, /starts only while nothing plays/)
    expect(SpawnGuard.take).to eq([])
  end

  it 'refines beside a playing Session with the console process nearly idle' do
    @worker = described_class.start
    expect(@worker.wait_ready).to eq(true)
    MB::Sound.use_output(MB::Sound::NullOutput.new(channels: 2, buffer_size: 800, sleep: :virtual))
    s = MB::Sound::Session.default
    j = job(s, evals: 40)
    Thread.pass until s.running?
    cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
    t0 = MB::U.clock_now
    r = MB::Sound::HandTune::Refinement.new(s, :lead, job: j).start.wait
    wall = MB::U.clock_now - t0
    used = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu
    expect(r.state).to eq(:done)
    expect(r.result.evals).to be >= 40
    expect(used / wall).to be < 0.25, "the console used #{(used * 1000).round} ms of CPU in #{(wall * 1000).round} ms"
    expect(SpawnGuard.take).to eq([])
  end

  it 'is not started at startup with MB_SOUND_REFINE_WORKER=0' do
    expect(ENV['MB_SOUND_REFINE_WORKER']).to eq('0') # (spec_helper)
    expect(described_class.prestart).to be_nil
  end
end
