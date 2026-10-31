require 'open3'
require 'rbconfig'

RSpec.describe(MB::Sound::Session::Warming) do
  # A stereo session at 256 frames (the maintainer's live buffer size);
  # +warm+ sets #warm_changes.
  def new_session(warm)
    out = MB::Sound::NullOutput.new(channels: 2, sleep: false)
    s = MB::Sound::Session.new(master_gain: 1, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 2, buffer_size: 256, realtime: false, raise_errors: true)
    s.warm_changes = warm
    s
  end

  def run(s, buffers)
    buffers.times.map { s.process_buffer.map(&:dup) }.transpose.map { |c| SpecBuffers.join(c) }
  end

  # Plays a song that draws seeds as it goes (synth lanes, random phases,
  # noise) and lands a new bus with a send, a master chain, and a new
  # graph while it plays; returns the mix and the session's warm-ups.
  def song(warm, &extra)
    MB::Sound.seed(3)
    s = new_session(warm)
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.track(:keys) { |clip| clip.synth(voices: 2) { |v| v.hz.saw.rnd * v.amp_env(0.01, 0.1, 0.5, 0.05) * 0.2 } }
      MB::Sound.bg(:keys, MB::Sound.seq(MB::Sound::C3, MB::Sound::E3).n4.loop)
      mix = run(s, 20)
      MB::Sound.bus(:verb) { |sig| sig.reverb(:room, mix: 1) }
      MB::Sound.feed(:keys, :verb, -6.db)
      MB::Sound.master { |m| m.softclip(0, 0.5) + MB::Sound.noise.at(0.001) }
      MB::Sound.bg(:air, 330.hz.triangle.rnd.at(0.05))
      extra&.call(s)
      rest = run(s, 400)
      [mix.zip(rest).map { |a, b| a.concatenate(b) }, s.warmed]
    ensure
      s.close
    end
  end

  before { described_class.forget! }

  it 'warms new bus and master chains and graphs without changing the samples' do
    cold, none = song(false)
    warm, list = song(true)
    expect(none).to eq([])
    expect(list.map { |w| [w.kind, w.name, w.result] }).to include([:bus, :verb, :played], [:master, :master, :played], [:graph, :air, :played], [:graph, :keys, :played])
    expect(warm.map(&:to_a)).to eq(cold.map(&:to_a))
  end

  it 'only builds a copy that shares a node with the live graphs' do
    lfo = nil
    play = ->(warm) {
      song(warm) { |s|
        lfo = 0.5.hz.lfo
        s.add(lfo * 0.01, name: :wob)
        s.bus(:wob_bus) { |sig| sig * (lfo * 0.5 + 0.5) }
      }
    }
    cold, = play.(false)
    warm, list = play.(true)
    expect(list.find { |w| w.name == :wob_bus }.result).to eq(:built)
    expect(warm.map(&:to_a)).to eq(cold.map(&:to_a))
  end

  it 'warms a kind and set of node classes once per process' do
    _, list = song(true) { |s| s.bus(:verb2) { |sig| sig.reverb(:room, mix: 1) } }
    expect(list.find { |w| w.name == :verb2 }.result).to eq(:known)
  end

  it 'skips a warm-up in a scheduled block without the time for it' do
    s = new_session(true)
    s.add(110.hz.saw.at(0.1), name: :a)
    run(s, 4)
    # (as the scheduler thread runs a block 0.1 s before its time)
    MB::Sound::Session.with_context(session: s, time: s.transport.position + 1/20r) do
      s.bus(:late) { |sig| sig.reverb(:room, mix: 1) }
    end
    expect(s.warmed.last).to have_attributes(name: :late, result: :skipped, reason: /0.10 s before the block's time/)
  ensure
    s&.close
  end

  it "warms in an offline render's scheduled block, which runs half a bar ahead" do
    s = new_session(true)
    MB::Sound::Session.with_context(session: s) do
      s.add(110.hz.saw.at(0.1), name: :a)
      MB::Sound.at_bar(2) { MB::Sound.bus(:late) { |sig| sig.reverb(:room, mix: 1) } }
      run(s, 380) # (bar 2 at 120 BPM: 375 buffers)
    end
    expect(s.warmed.find { |w| w.name == :late }).to have_attributes(result: :played)
  ensure
    s&.close
  end

  # (session-2, the maintainer's "In background": the console returns at
  # once; the change lands once warm)
  describe 'in the background' do
    # A session warming console commands' new graphs in the background,
    # each warm-up round waiting for a token from the returned Queue.
    def background_session
      s = new_session(true)
      s.warm_background = true
      gate = Queue.new
      allow(s).to receive(:warm_round).and_wrap_original { |m, *a, **k, &b| gate.pop; m.call(*a, **k, &b) }
      [s, gate]
    end

    def landed?(s, name) = s.journal.changes.any? { |e| e.subject == name && e.kind == :bg && e.status == :landed }

    # Waits (up to 10 s) until no queued change of +s+ waits for a warm-up
    # and +name+'s warm-up is listed.
    def wait_released(s, name)
      deadline = MB::U.clock_now + 10
      until s.warmed.any? { |w| w.name == name } && s.instance_variable_get(:@changes).none? { |c| s.send(:held?, c) }
        raise 'the warm-up never finished' if MB::U.clock_now > deadline
        sleep 0.01
      end
    end

    it 'returns at once, holding the change until the warm-up is done, then lands it (one hold per command)' do
      s, gate = background_session
      MB::Sound::Session.with_context(session: s) do
        entry = MB::Sound.bg(:pad, 220.hz.triangle.at(0.1))
        expect(entry.to_s).to match(/bg :pad lands .* \(queued\)/)
        mix = run(s, 10)
        expect(mix[0].abs.max).to eq(0)
        expect(s.queued(:pad).length).to eq(1)

        2.times { gate << true } # (two rounds)
        wait_released(s, :pad)
        mix = run(s, 2)
        expect(mix[0].abs.max).to be > 0.05
        expect(s.warmed.find { |w| w.name == :pad }).to have_attributes(kind: :graph, result: :played)
      end
    ensure
      s&.close
    end

    it 'lands a change whose time passed meanwhile on its launch point\'s next alignment' do
      s, gate = background_session
      MB::Sound::Session.with_context(session: s) do
        s.warm_changes = false
        s.add(0.0.constant, name: :clock, on: :now) # (keeps the timeline moving)
        s.warm_changes = true
        bar = 96000 / 256 # (buffers a bar at 120 BPM)
        MB::Sound.bg(:pad, 220.hz.triangle.at(0.1), on: :bar)
        (bar + 20).times { s.process_buffer } # (past the bar it was for)
        expect(landed?(s, :pad)).to eq(false)
        2.times { gate << true }
        wait_released(s, :pad)
        entry = s.queued(:pad).first
        expect(entry.lands.to_s).to eq('3:1')
        s.process_buffer until s.frame >= 2 * 96000 + 256
        expect(landed?(s, :pad)).to eq(true)
        expect(s.journal.changes.find { |e| e.subject == :pad }.lands.to_s).to eq('3:1')
      end
    ensure
      s&.close
    end

    it 'warms in the foreground in scheduled blocks, offline (by default), and in replays' do
      s = new_session(true)
      expect(s.warm_background).to eq(:auto)
      expect(s.send(:warm_hold_for_add)).to be_nil # (offline)
      s.warm_background = true
      MB::Sound::Session.with_context(session: s, time: 1r) { expect(s.send(:warm_hold_for_add)).to be_nil }
      expect(s.send(:warm_hold_for_add)).to be_a(MB::Sound::Session::Warming::WarmHold)
      expect { s.warm_background = :yes }.to raise_error(ArgumentError, /:auto, true, or false/)
    ensure
      s&.close
    end
  end

  it 'is on for realtime sessions with YJIT, off offline, and never in sandboxes' do
    s = new_session(:auto)
    expect(s.warming?).to eq(false)
    box = s.warm_sandbox
    described_class.always = true
    expect(s.warming?).to eq(true)
    expect(box.warming?).to eq(false)
  ensure
    described_class.always = false
    box&.close
    s&.close
  end

  it 'raises for other settings' do
    s = new_session(false)
    expect { s.warm_changes = :yes }.to raise_error(ArgumentError, /:auto, true, or false/)
  ensure
    s&.close
  end

  # The point of it (dropouts-2): with YJIT, a new bus's landing buffer
  # compiled ~60 ms of code on the render thread (offline, 256 frames).
  # Measured in a subprocess with YJIT (specs run without it) as YJIT's
  # compiled block count, which doesn't depend on machine load the way
  # compile milliseconds do (fixes-1030: 13-16 ms under suite load vs 7
  # alone).
  it 'leaves almost nothing for YJIT to compile where a warmed bus lands' do
    skip 'needs YJIT' unless defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enable)

    script = <<~'RUBY'
      require 'mb/sound'
      s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false, buffer_size: 256, channels: 2)
      s.warm_changes = ENV['WARM'] == '1'
      compiled = -> { RubyVM::YJIT.runtime_stats[:compiled_block_count] }
      MB::Sound::Session.with_context(session: s) do
        MB::Sound.bg(:pad, 220.hz.saw.lp4(800, resonance: 0.3).at(0.1))
        200.times { s.process_buffer }
        MB::Sound.bus(:verb) { |sig| sig.reverb(:hall, mix: 1) }
        MB::Sound.feed(:pad, :verb, -6.db, on: :bar)
        worst = 200.times.map { c = compiled.call; s.process_buffer; compiled.call - c }.max
        puts "worst #{worst}"
      end
      s.close
    RUBY
    worst = %w[0 1].map { |w|
      out, status = Open3.capture2e({ 'MB_SOUND_YJIT' => '1', 'WARM' => w }, RbConfig.ruby, '-I', File.expand_path('../../../../../lib', __dir__), '-e', script)
      expect(status).to be_success, out
      Integer(out[/worst (\d+)/, 1])
    }
    # (Mac container, 2026-10-30, the same at any load: cold 1735 blocks
    # (~70 ms), warm 184 (~7 ms), the rest the feed's undo snapshot and
    # knob glide)
    expect(worst[1]).to be < [400, worst[0] / 4].min
  end
end
