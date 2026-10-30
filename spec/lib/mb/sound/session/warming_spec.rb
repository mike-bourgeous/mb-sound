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
