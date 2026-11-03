# The tuner (hand-tune-3; the maintainer, 2026-11-03: "I'd like a
# wizard-ish UI for hand tuning where I can select a reference and paired
# synth from a list"): its steps as a transition table, the references
# (queue items walked with Prism, a folder's files with their lengths,
# loaded samples) and their summaries, the synths for a reference in their
# order, one tune line per kind that the take reader reads, auditions, and
# a take whose tuner line replays to the same setup.  Synthetic references
# and queue items only (never the maintainer's tmp/hand-tune-queue).
RSpec.describe(MB::Sound::HandTune::Wizard, :aggregate_failures) do
  S = MB::Sound unless defined?(S)

  # Synthetic references: a sine "kick" with a falling level, a filtered
  # saw bass note, a noise burst.
  def make_refs(dir)
    FileUtils.mkdir_p(dir)
    S.write(File.join(dir, 'kick_sine.wav'), (110.hz.sine * S.adsr(0.001, 0.2, 0, 0.05)).until(0.4), overwrite: true)
    S.write(File.join(dir, 'bass_saw.flac'), (55.hz.saw.lp4(800) * S.adsr(0.005, 0.1, 0.7, 0.2)).until(0.8), overwrite: true)
    S.write(File.join(dir, 'snare_noise.wav'), (S.noise * S.adsr(0.001, 0.12, 0, 0.05)).until(0.3), overwrite: true)
  end

  # A queue item as the queue writes them (the reference relative to the
  # directory above the queue, a play clip, a level line after).
  QUEUE_ITEM = <<~RUBY.freeze
    # Hand-tune queue 1: synthetic kick (a test item): paste into bin/sound.rb (run from /app)
    # ok (peak 0.5): fit patch kick_fit: 2 knobs (tune, decay)
    tune :kick, "synth(midi, voices: 1) { |v| v.hz.sine * v.amp_env(0.0015, 0.2345, 0.0, 0.05) * 0.875 }",
      ref: "refs/kick_sine.wav", play: seq(A1).n4.loop,
      gain: [(0.1..2.0).at(0.875), "the level"],
      decay: (0.01..2.0).at(0.2345)
    level :kick, -2.0.db   # (quieter)
  RUBY

  FAILING_ITEM = <<~RUBY.freeze
    # Hand-tune queue 2: a clap that fails (a test item): paste into bin/sound.rb (run from /app)
    # FAILS: MB::Sound::FitPatch::Error: fit_patch clap_fit: the document doesn't load or play
    tune :clap, "kit(grid(16, clap: 'X...'), seed: 1) { voice(:clap) { |h| h.noise(decay: 0.2) } }",
      ref: "refs/snare_noise.wav", play: seq(Ds2).n4.loop,
      decay: (0.01..1.0).at(0.2)
  RUBY

  before(:all) do
    @root = Dir.mktmpdir('tuner-', SpecTmp::ROOT)
    make_refs(File.join(@root, 'refs'))
    FileUtils.mkdir_p(File.join(@root, 'queue'))
    File.write(File.join(@root, 'queue', '01_kick.rb'), QUEUE_ITEM)
    File.write(File.join(@root, 'queue', '02_clap.rb'), FAILING_ITEM)
  end

  let(:session) {
    S::Session.new(output: S::NullOutput.new(channels: 1, sleep: false), transport: S::Sequence::Transport.new(bpm: 120), channels: 1,
                   buffer_size: 800, realtime: false, raise_errors: true)
  }

  before do
    @env = ENV.to_h.slice('MB_SOUND_TUNE_QUEUE', 'MB_SOUND_REFS')
    # (the queue's refs/ sits beside queue/, as tmp/hand-tune-queue/refs
    # would under the checkout: the item's relative path is found there)
    ENV['MB_SOUND_TUNE_QUEUE'] = File.join(@root, 'queue')
    ENV['MB_SOUND_REFS'] = File.join(@root, 'refs')
    # (fits of this example only: tune writes kick_fit.mbg.rb)
    @fits = ENV['MB_SOUND_FITS']
    ENV['MB_SOUND_FITS'] = File.join(Dir.mktmpdir('fits-', SpecTmp::ROOT), 'fits')
    FileUtils.rm_f(described_class.state_path)
    described_class::Background.inline = true
  end

  after do
    described_class.close
    S::UI::Design.instance_variable_set(:@open, false)
    S::UI::Design.instance_variable_set(:@last, nil)
    session.close
    S.rewind
    %w[MB_SOUND_TUNE_QUEUE MB_SOUND_REFS].each { |k| @env.key?(k) ? ENV[k] = @env[k] : ENV.delete(k) }
    ENV['MB_SOUND_FITS'] = @fits
    described_class::Background.inline = nil
  end

  def run(&block) = S::Session.with_context(session: session) { S.instance_eval(&block) }

  def wizard = described_class.open(session: session)

  it 'has a row for every state and event' do
    expect(described_class::TRANSITIONS.keys).to match_array(described_class::STATES.product(described_class::EVENTS))
    expect(described_class::TRANSITIONS.values.map(&:first)).to all(satisfy { |s| described_class::STATES.include?(s) })
    expect(described_class.table.lines.length).to eq(9)
  end

  it 'lists the queue items (walked, never run), the folder\'s files with their lengths, and loaded samples' do
    w = wizard
    q = described_class.queue_items
    expect(q.map(&:number)).to eq([1, 2])
    expect(q[0]).to have_attributes(title: 'synthetic kick (a test item)', status: :ok, track: :kick, note: 33,
                                    ref_path: File.join(@root, 'refs', 'kick_sine.wav'), play: 'seq(A1).n4.loop')
    expect(q[0].lines).to start_with('tune :kick, "synth(midi').and(include("ref: #{File.join(@root, 'refs', 'kick_sine.wav').inspect}")).and(end_with('level :kick, -2.0.db'))
    expect(q[1]).to have_attributes(status: :fails, track: :clap)
    expect(q[1].problem).to start_with('MB::Sound::FitPatch::Error')

    # (a queue item's reference isn't listed again under the folder)
    expect(w.refs.reject { |r| r.kind == :sample }.map { |r| [r.kind, r.name] }).to eq([[:queue, '1 synthetic kick (a test item)'], [:queue, '2 a clap that fails (a test item)'], [:file, 'bass_saw.flac']])
    expect(w.refs.reject { |r| r.kind == :sample }.map(&:seconds).map { |x| x&.round(2) }).to eq([0.4, 0.3, 0.42])
    expect(w.folder).to eq(File.join(@root, 'refs'))

    # A Sample read in this process (else nobody holds it: the cache is weak)
    other = tmp_path('other_ref.wav')
    S.write(other, 220.hz.triangle.until(0.2), overwrite: true)
    keep = S::Sample[other]
    w.refresh
    expect(w.refs.last).to have_attributes(kind: :sample, name: 'other_ref.wav', path: File.expand_path(other), about: 'read in this session')
    expect(keep.file).to eq(File.expand_path(other))

    # Another folder, remembered for the next tuner
    w.folder = File.dirname(other)
    expect(w.refs.map(&:name)).to include('other_ref.wav')
    expect(described_class.remembered_folder).to eq(File.dirname(File.expand_path(other)))
  end

  it 'works out summaries in the background and caches them' do
    w = wizard
    refs = w.refs.to_h { |r| [r.name, r] }
    expect(w.summary(refs['bass_saw.flac'])).to be_nil # (asked for: queued)
    w.summary(refs['1 synthetic kick (a test item)'])
    w.background.drain # (Background.inline: no thread, the jobs run here)
    bass = w.summary(refs['bass_saw.flac'])
    kick = w.summary(refs['1 synthetic kick (a test item)'])
    expect(bass).to have_attributes(note: 33, shape: :percussive)
    expect(bass.to_s).to start_with('A1 ')
    expect(kick.to_s).to match(/\AA2 [+-]\d+ cents, percussive, -20 dB at \d+ ms\z/)
    expect(kick.decay).to be_between(0.05, 0.4)
    expect(described_class.summarize(tmp_path('missing.wav')).error).to be_a(String)
  end

  it 'lists the synths for a reference: its queue fit, the track\'s fits, init, blank, other fits, then the library, kits first for a kick' do
    w = wizard
    run { fit_patch :kick_old, 'synth(midi, voices: 1) { |v| v.hz.sine * v.amp_env(0.002, 0.3, 0.0, 0.07) }', decay: (0.01..2.0).at(0.3) }
    run { fit_patch :pad_fit, 'synth(midi, voices: 1) { |v| v.hz.saw * v.amp_env(0.2, 0.3, 0.6, 0.7) }', decay: (0.01..2.0).at(0.3) }
    w.pick(0)
    expect(w.state).to eq(:synth)
    expect(w.track).to eq(:kick)
    expect(w.note).to eq(33) # (the queue item's play clip)
    kinds = w.synths.map { |x| [x.kind, x.name] }
    expect(kinds.first(5)).to eq([[:queue, :kick_fit], [:fit, :kick_old], [:init, :init], [:blank, :blank], [:fit, :pad_fit]])
    lib = w.synths.select { |x| x.kind == :library }
    expect(lib.first(2).map(&:name)).to eq(%i[tr808 tr909])
    expect(lib.find { |x| x.name == :tr909 }.ears).to eq(true)
    expect(lib.find { |x| x.name == :dnb_reese }.ears).to eq(false)
    expect(w.synths.map(&:name)).not_to include(:init_fit) # (init once)

    w.back
    w.pick(1)
    expect(w.synths.first).to have_attributes(kind: :queue, problem: start_with('MB::Sound::FitPatch::Error'))
    expect { w.pick(0) }.to raise_error(ArgumentError, /can't load/)
    w.back
    w.pick(2) # (a folder file: its track from its name, its note from its pitch)
    w.background.drain
    expect(w.track).to eq(:bass)
    expect(w.play_code).to eq('seq(A1).n4.loop') # (0.42 s: a quarter note at 120 BPM)
    expect(w.role).to eq(:bass)
    expect(w.synths.select { |x| x.kind == :library }.first(3).map(&:name)).to all(satisfy { |n| %i[dnb_sub funk_bass jungle_reese jungle_sub sq80_prime_bass square_bass house_bass acid roller dnb_reese].include?(n) })
  end

  it 'writes one tune line per kind, each read back by the take reader' do
    w = wizard
    w.pick(0)
    run { fit_patch :kick_old, 'synth(midi, voices: 1) { |v| v.hz.sine * v.amp_env(0.002, 0.3, 0.0, 0.07) }', decay: (0.01..2.0).at(0.3) }
    w.back
    w.pick(0)
    by = w.synths.to_h { |x| [x.name, x] }
    ref = File.join(@root, 'refs', 'kick_sine.wav').inspect
    expect(w.tune_line(by[:kick_fit])).to eq(described_class.queue_items[0].lines)
    expect(w.tune_line(by[:init])).to eq("tune :kick, L.inst.init, ref: #{ref}, play: seq(A1).n4.loop, as: :kick_init")
    expect(w.tune_line(by[:tr909])).to eq("tune :kick, L.kit.tr909, ref: #{ref}, play: seq(C2).n4.loop") # (a kit: its kick's note)
    expect(w.tune_line(by[:dnb_sub])).to end_with(', as: :kick_dnb_sub')
    expect(w.tune_line(by[:kick_old])).to match(%r{\Atune :kick, ".*/versions/kick_old-\h{12}\.mbg\.rb", ref: .*, as: :kick_old\z})
    blank = w.tune_line(by[:blank])
    expect(blank).to match(/\Atune :kick, "synth\(midi\) \{ \|v\| v\.hz\.sine \* v\.amp_env\(.*\) \}", ref: .*, as: :kick_blank,\n  attack: .*release: /)

    # (the reader rebuilds each line's document and starts its knobs there)
    { kick_fit: :gain, init: :cutoff, kick_old: :decay, blank: :decay, dnb_sub: nil }.each do |name, param|
      line = w.tune_line(by[name])
      take = "MB::Sound::Take::Replay.new(bpm: 120) do |r|\n  r.line 0r, [], #{line.inspect}\nend\n"
      t = S::Take.read(take)
      expect(t.versions[:kick]&.first&.text).to include('from: "fit_patch"'), "#{name}: no version"
      expect(t.values(:kick, :start)).to have_key(param) if param
    end
  end

  it 'scores the synth looked at against the reference in the background (documents and kits)' do
    w = wizard
    w.pick(0)
    by = w.synths.to_h { |x| [x.name, x] }
    expect(w.score(by[:kick_fit])).to be_nil
    w.score(by[:tr909])
    w.score(by[:init])
    w.background.drain
    fit = w.score(by[:kick_fit])
    expect(fit.error).to be_nil
    expect(fit.total).to be_a(Float).and(be > 0)
    expect(fit.lufs).to be_between(-60, 0)
    expect(w.score(by[:tr909]).total).to be_a(Float)
    expect(w.score(by[:init]).total).to be > fit.total # (a 110 Hz sine fit against a 110 Hz sine: closer than two saws)
  end

  it 'gives audition lines that play the reference loudness-matched and a synth on the reference\'s note' do
    w = wizard
    w.pick(0)
    by = w.synths.to_h { |x| [x.name, x] }
    ref = w.ref
    expect(w.audition_line(ref)).to eq("audition #{ref.path.inspect}")
    expect(w.audition_line(by[:init])).to eq('audition L.inst.init, note: A1')
    expect(w.audition_line(by[:kick_fit])).to match(%r{\Aaudition ".*/versions/kick_fit-\h{12}\.mbg\.rb", note: A1\z})
    w.score(by[:init])
    w.background.drain
    expect(w.audition_line(ref, match: by[:init])).to match(/\Aaudition ".*", lufs: -\d+\.\d\z/)

    out = []
    expect {
      [w.audition_line(ref), w.audition_line(by[:kick_fit]), w.audition_line(by[:tr909])].each do |line|
        out << S::UI.run_line(line, session)
        30.times { session.process_buffer }
      end
    }.not_to output.to_stderr
    expect(out.map(&:to_s)).to all(include('on MAIN at -6 dB'))
    expect(out[0].to_s).to include('kick_sine.wav once at -20.0 LUFS')
    expect(session.players.keys).to include(:audition)
    run { audition off }
    session.process_buffer
  end

  # His session with the tuner: a reference and a synth picked, the line
  # run as a console line; a turn.  The take keeps the tune line (not the
  # tuner's steps) and replays to the same knobs and samples.
  it 'runs the picked line as a take line that replays to the same setup' do
    w = wizard
    w.pick(0)
    w.pick(w.synths.index { |x| x.kind == :init })
    expect(w.state).to eq(:tuning)
    line = w.line
    b = S::Take.console_binding
    S.seed(5)
    take = S::Take.new(session: session)
    live = []
    expect {
      120.times do |i|
        S::Session.with_context(session: session) { take.line(line, b) } if i == 0
        S::Session.with_context(session: session) { take.line('turn :"kick/cutoff", 900', b) } if i == 40
        live << session.process_buffer[0].dup
      end
    }.to output(/fit patch kick_init: 16 knobs.*design :kick: kick_init on track :kick.*ab :kick: hearing the patch/m).to_stdout
    expect(w.tuned).to eq(:kick)
    expect(S::Reference.pair(session, :kick).source).to eq(w.ref.path)
    expect(session.knobs[:"kick/cutoff"].value).to eq(900.0)
    text = take.to_ruby
    expect(text).to include('tune :kick, L.inst.init, ref: ').and(include('turn :"kick/cutoff", 900'))
    expect(text).not_to match(/^\s*tuner\b/)

    turns = take.turns
    expect(turns.versions[:kick].first.text).to include('name: "kick_init"', 'Tuned from L.inst.init')
    expect(turns.changed).to include(:"kick/cutoff")

    path = tmp_path('take.rb')
    expect { take.save(path) }.to output(/Saved/).to_stdout
    session.close
    S::UI::Design.instance_variable_set(:@open, false)
    load path
    replay = S::Take::Replay.last
    S.seed(5)
    out = []
    expect {
      replay.render(S::NullOutput.new(channels: 1, sleep: false), channels: 1, buffer_sizes: [800], tail: 0) { |mix| out << mix[0].dup }
    }.to output(/kick_init/).to_stdout
    a = SpecBuffers.join(live)
    r = SpecBuffers.join(out)
    expect(a.abs.max).to be > 0.01
    expect((r[0...a.length] - a).abs.max).to eq(0)
  end

  it 'goes back a step and restarts, keeping the reference under the cursor' do
    w = wizard
    w.cursor[:reference] = 2
    w.pick(w.under_cursor)
    expect(w.step).to eq(2)
    w.query[:synth] = 'tr9'
    expect(w.shown.map(&:name)).to eq([:tr909])
    w.back
    expect(w.state).to eq(:reference)
    expect(w.under_cursor.name).to eq('bass_saw.flac')
    w.query[:reference] = 'clap fails'
    expect(w.shown.map(&:name)).to eq(['2 a clap that fails (a test item)'])
    w.restart
    expect(w.state).to eq(:reference)
  end
end
