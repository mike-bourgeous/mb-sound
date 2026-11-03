# refine (hand-tune-2; the maintainer, 2026-11-03: "optionally I'd like to
# be able to trigger an optimizer pass with time or range limitations on
# top of my own settings to refine them"): from his knobs, inside his
# limits, against the reference; a proposal he can A/B three ways, applied
# only when asked as one journaled change.  Searches run in-process here
# (mode: :here; the worker's own spec runs it in a process).  Synthetic
# fits and references only.
RSpec.describe(MB::Sound::RefineMethods, :aggregate_failures) do
  RF_CODE = 'synth(CLIP, voices: 1) { |v| v.hz.saw.lp4(1234.5, resonance: 0.25) * v.amp_env(0.01, 0.2, 0.5, 0.1) }'.freeze
  RF_FIT = "fit = fit_patch :refine_fit, #{RF_CODE.inspect}, cutoff: (100.0..8000.0).at(1234.5), resonance: (0.0..1.0).at(0.25)".freeze
  # The reference: the same voice darker and more resonant.
  RF_REF = 'MB::Sound::Sample.new(MB::Sound::HandTune.render(fit.version, { cutoff: 700.0, resonance: 0.4 }, note: 45, hold: 0.3, seconds: 0.5), name: "ref")'.freeze

  let(:session) {
    MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1,
                           buffer_size: 800, realtime: false, raise_errors: true)
  }

  after {
    session.close
    MB::Sound.rewind
  }

  # Plays +lines+ ({ buffer => [console lines] }) for +buffers+ buffers.
  # Returns [the mix, the take].
  def perform(lines, buffers:)
    b = MB::Sound::Take.console_binding
    MB::Sound.seed(5)
    t = MB::Sound::Take.new(session: session)
    out = []
    buffers.times do |i|
      lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: session) { t.line(code, b) } }
      out << session.process_buffer[0].dup
    end
    [SpecBuffers.join(out), t]
  end

  let(:setup) { { 0 => [RF_FIT, 'track :lead, fit', 'bg :lead, seq(A2).n4.loop', "ab :lead, #{RF_REF}"], 4 => ['turn :"lead/cutoff", 1000'] } }

  def knob(name) = session.knobs[name]&.value

  def refine(**opts)
    r = nil
    expect { r = MB::Sound::Session.with_context(session: session) { MB::Sound.refine(:lead, mode: :here, **opts) } }.to output(/refine :lead: loss/).to_stdout
    r
  end

  it 'proposes knob values closer to the reference inside its trust region, and changes nothing until asked' do
    expect { perform(setup, buffers: 10) }.to output.to_stdout
    r = refine(evals: 40, within: 0.1)
    expect(r.result.evals).to be_between(40, 50) # (a generation in progress ends; each run scores its start point)
    expect(r.result.ended).to eq(:evals)
    expect(r.result.best).to be < r.result.start
    expect(r.proposal.keys).to include(:cutoff)
    spec = session.knobs[:"lead/cutoff"].spec
    expect((spec.position(r.proposal[:cutoff]) - spec.position(1000.0)).abs).to be <= 0.1 + 1e-9
    expect(r.proposal[:cutoff]).to be < 1000.0 # (toward the reference's 700)
    expect(r.turn_line).to match(/\Aturn :lead, cutoff: [\d.]+(, resonance: [\d.]+)?\z/)
    expect(r.to_s).to include('refine.ab', 'refine.apply')
    # (never applied without being asked)
    expect(knob(:"lead/cutoff")).to eq(1000.0)
    expect(knob(:"lead/resonance")).to eq(0.25)
    expect(session.arrangement.tracks.keys).not_to include(:lead_refined)
  end

  it 'keeps to per-knob ranges, only:/except:, and its time budget, and is the same for a seed' do
    expect { perform(setup, buffers: 10) }.to output.to_stdout
    r = refine(evals: 16, only: [:cutoff], cutoff: 900..1100)
    expect(r.job.params).to eq([:cutoff])
    expect(r.proposal.keys).to eq([:cutoff])
    expect(r.proposal[:cutoff]).to be_between(900.0, 1100.0)
    again = refine(evals: 16, only: [:cutoff], cutoff: 900..1100)
    expect(again.proposal).to eq(r.proposal)
    expect(again.result.history).to eq(r.result.history)
    expect(refine(evals: 4, except: [:cutoff], within: nil).job.params).to eq([:resonance])

    timed = refine(seconds: 0.5)
    expect(timed.result.ended).to eq(:time)
    expect(timed.result.seconds).to be < 0.5 + 1.0 # (it ends after the evaluation that crosses the budget, plus one at its best)
    expect(timed.result.evals).to be >= 1

    MB::Sound::Session.with_context(session: session) do
      expect { MB::Sound.refine(:lead, evals: 5, mode: :here, nope: 1..2) }.to raise_error(ArgumentError, /no knob :nope \(its knobs: cutoff, resonance\)/)
      expect { MB::Sound.refine(:lead, evals: 5, mode: :here, within: 2) }.to raise_error(ArgumentError, /within: is a share/)
    end
  end

  it 'stops cleanly, keeping the best so far' do
    expect { perform(setup, buffers: 10) }.to output.to_stdout
    r = MB::Sound::Session.with_context(session: session) { MB::Sound.refine(:lead, evals: 10_000, mode: :here, wait: false) }
    expect(r.state).to eq(:running)
    Thread.pass until r.progress && r.progress[0] >= 3
    r.stop
    expect { r.wait }.not_to output.to_stdout
    expect(r.result.ended).to eq(:stop)
    expect(r.result.evals).to be < 100
    expect(r.result.best).to be <= r.result.start
    expect(MB::Sound::Session.with_context(session: session) { MB::Sound.refine }).to equal(r)
  end

  it 'A/Bs his settings, the proposal, and the reference, applies as one undo step, and replays from the take' do
    lines = setup.merge(
      10 => ['refine :lead, evals: 30, mode: :here'],
      20 => ['refine.ab'], # (the refined copy)
      30 => ['refine.ab'], # (the reference)
      40 => ['ab'],        # (his again)
      60 => ['refine.apply'],
    )
    live = take = nil
    expect { live, take = perform(lines, buffers: 140) }.to output(/refine :lead: loss/).to_stdout
    r = MB::Sound::Session.with_context(session: session) { MB::Sound.refine }
    pair = MB::Sound::Reference.pair(session, :lead)
    expect(pair.alt).to be_nil # (apply stops the copy)
    expect(pair.hearing).to eq(:patch)
    r.proposal.each { |p, v| expect(knob(:"lead/#{p}")).to eq(v) }
    expect(knob(:"lead_refined/cutoff")).to eq(r.proposal[:cutoff])

    text = take.to_ruby
    expect(text).to include('refine(:lead, proposal: { cutoff: ', 'searched: "evals: 30, seed: 1, ', 'refine(:lead, apply: { cutoff: ')
    expect(text).not_to include('refine :lead, evals: 30')
    t = take.turns
    expect(t.flips.map(&:hearing)).to eq(%i[alt ref patch])
    expect(t.rows.select { |x| x.kind == :refine }.map(&:knob)).to eq(r.proposal.keys.map { |p| :"lead/#{p}" })

    # (one undo step puts every knob back)
    MB::Sound::Session.with_context(session: session) { MB::Sound.undo(on: :now) }
    3.times { session.process_buffer }
    expect(knob(:"lead/cutoff")).to eq(1000.0)
    expect(knob(:"lead/resonance")).to eq(0.25)

    path = tmp_path('take.rb')
    File.write(path, text)
    load path
    MB::Sound.seed(5)
    out = []
    expect {
      MB::Sound::Take::Replay.last.render(MB::Sound::NullOutput.new(channels: 1, sleep: false), channels: 1, buffer_sizes: [800], tail: 0) { |mix| out << mix[0].dup }
    }.to output.to_stdout
    data = SpecBuffers.join(out)
    expect((data[0...live.length] - live).abs.max).to eq(0)
  end

  it 'turns a track\'s knobs together as one change, build knobs with one rebuild' do
    expect { perform(setup, buffers: 6) }.to output.to_stdout
    MB::Sound::Session.with_context(session: session) do
      MB::Sound.turn(:lead, cutoff: 500.0, resonance: 0.5)
      2.times { session.process_buffer }
      expect(knob(:"lead/cutoff")).to eq(500.0)
      expect(knob(:"lead/resonance")).to eq(0.5)
      MB::Sound.undo(on: :now)
      2.times { session.process_buffer }
      expect(knob(:"lead/cutoff")).to eq(1000.0)
      expect(knob(:"lead/resonance")).to eq(0.25)
      expect { MB::Sound.turn(:lead, cutof: 500.0) }.to raise_error(ArgumentError, /:lead has no knob cutof \(did you mean cutoff:\?\) \(its knobs: cutoff, resonance\)/)
      expect { MB::Sound.turn(:lead, cutoff: 500.0, over: 1) }.to raise_error(ArgumentError, /take plain values/)
    end
  end
end
