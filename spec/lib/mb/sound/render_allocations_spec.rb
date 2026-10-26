require_relative '../../../support/allocation_budget'

# Guards for allocation-free rendering (alloc-1, 2026-10-21; per-buffer
# budgets since alloc-2, 2026-10-25; measure the whole picture with
# bin/alloc_audit.rb).  Every object a buffer allocates costs GC time on
# the render thread (a minor collection every second or two at these
# rates, and allocation is what eventually starts a major one, which
# stops the render thread for 45-80 ms), so render paths shouldn't build
# throwaway objects: these specs fail when recipe recording runs while
# sampling, or when a representative graph's steady-state allocation per
# 128-frame buffer grows past its budget, naming the top allocators.
#
# Budgets are a little above what alloc-2 measured (in the comments; no
# YJIT, as specs run).  When one fails: look at the named sites first
# (reused buffers, cached Arrays, no per-buffer Hashes/Procs/Rationals;
# see design/notes/graph_nodes.md), and raise a budget only with a reason.
#
# One pass: the Sessions here run #process_buffer, never a mastered
# render's loudness targeting (Mastering::Targeting's pass 1 records every
# buffer, which would show up as old objects and major GCs).
RSpec.describe('render-path allocations') do
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:output) { MB::Sound::NullOutput.new(channels: 2, buffer_size: 128, sleep: false) }
  let(:session) {
    MB::Sound::Session.new(output: output, transport: transport, channels: 2, buffer_size: 128, realtime: false, raise_errors: true)
  }

  after { session.close }

  def ctx(&block)
    MB::Sound::Session.with_context(session: session, &block)
  end

  # A small song: a looping clip on an 8-voice synth with re-strikes that
  # add energy, a drum grid, and a filtered drone.
  def start_song
    ctx do
      riff = MB::Sound.seq(MB::Sound::C3, MB::Sound::E3, MB::Sound::G3, MB::Sound::Rest).n8.loop
      MB::Sound.bg(:keys, riff.synth(voices: 8) { |v|
        v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.1).retrigger(:add)
      })
      MB::Sound.bg(:drums, MB::Sound.tr808(MB::Sound.grid(kick: 'x...x...', closed_hat: '..x...x.')))
      MB::Sound.bg(:drone, 55.hz.ramp.filter(:lowpass, cutoff: 400, quality: 2) * 0.1)
    end
  end

  def render(buffers)
    ctx { buffers.times { session.process_buffer } }
  end

  # Steady-state allocation per buffer of the session after +warm+
  # buffers, checked against +objects+ and +bytes+ per buffer.
  def expect_budget(objects:, bytes:, warm: 1500, buffers: 400)
    render(warm)
    m = ctx { AllocationBudget.measure(buffers: buffers) { session.process_buffer } }
    puts "\n\e[1m#{RSpec.current_example.description}\e[0m\n#{m.report}" if ENV['ALLOC_REPORT']
    expect(m.objects_per_buffer).to be <= objects, "over the budget of #{objects} objects per buffer:\n#{m.report}"
    expect(m.bytes_per_buffer).to be <= bytes, "over the budget of #{bytes} bytes per buffer:\n#{m.report}"
    m
  end

  it 'records no graph recipe calls while sampling (swaps and seeks included)' do
    start_song
    render(50)

    recipe = MB::Sound::GraphNode::Recipe
    calls = []
    sampling = false
    allow(recipe).to receive(:call).and_wrap_original { |m, *args, **kwargs, &block|
      calls << [args[0].class, args[1]] if sampling
      m.call(*args, **kwargs, &block)
    }

    ctx { MB::Sound.swap(:keys, MB::Sound.seq(MB::Sound::D3, MB::Sound::F3).n8.loop) }
    sampling = true
    render(800)
    sampling = false
    ctx { MB::Sound.seek(2) }
    sampling = true
    render(400)
    sampling = false

    expect(calls.tally).to eq({})
  end

  describe 'budgets per 128-frame buffer' do
    # Plans without check mode, also under MB_SOUND_PLAN_CHECK=1: its
    # unfused rerun and state snapshots of every block allocate on their
    # own, and these budgets are for what a render allocates (omnibus13)
    around do |ex|
      old = MB::Sound::Plan.check
      MB::Sound::Plan.check = nil
      ex.run
    ensure
      MB::Sound::Plan.check = old
    end

    it 'a small song: synth, drum kit, filtered drone' do
      start_song
      expect_budget(objects: 55, bytes: 5_000) # (master-ai before alloc-2: 87.9 objects, 4.5 kB; alloc-2: 42.7, 3.2 kB)
    end

    it 'a routed mix: a bus with a reverb, sends, a ducked bass, a master limiter' do
      ctx do
        MB::Sound.bus(:verb) { |sig| sig.reverb(:room, mix: 1) }
        MB::Sound.sidechain(:pump, MB::Sound.grid(16, 'x...x...x...x...').loop)
        MB::Sound.bg(:keys, MB::Sound.seq(MB::Sound::C4, MB::Sound::G4).n8.loop.synth(voices: 4) { |v| v.hz.triangle * v.amp_env(0.01, 0.1, 0.5, 0.1) }, send: { verb: -6.db })
        MB::Sound.bg(:bass, (MB::Sound.seq(MB::Sound::C2).n4.loop.synth(voices: 1) { |v| v.hz.saw * v.amp_env }).duck(:pump), to: :verb)
        MB::Sound.master { |mix| mix.limit }
      end
      expect_budget(objects: 160, bytes: 9_000) # (before: 475, 33 kB; alloc-2: 126, 6.2 kB)
    end

    it 'a modulated synth on dense_modulated.mid (8 busy voices, controllers and bend every 10 ms)' do
      MB::Sound.seed(0)
      ctx do
        MB::Sound.bg(:fm, MB::Sound.synth('spec/test_data/dense_modulated.mid', voices: 8) { |v|
          base = v.hz.glide(50.ms)
          mod = v.cc(1, range: 1.0..2.0)
          e = v.fm_env(0, 1, 0.5, 0.3) * base.transpose(12).sine.pm(mod * base.sine)
          (v.amp_env * base.sine.pm(e * mod + v.bend) * 0.1).filter(:lowpass, cutoff: 2000 + 1000 * mod, quality: 2)
        })
      end
      expect_budget(objects: 175, bytes: 13_000, warm: 400, buffers: 300) # (before: 172.5, 10.1 kB; alloc-2: 138.5, 9.2 kB; MIDI events' Rationals lead)
    end

    it 'a hard-synced lead through a delay (sync pulses, delay lines)' do
      ctx do
        lead = MB::Sound.seq(MB::Sound::A3, MB::Sound::C4, MB::Sound::E4).n8.loop.synth(voices: 2) { |v|
          m = v.hz.saw
          v.hz.transpose(7).ramp.sync(m.wraps) * v.amp_env(0.01, 0.2, 0.6, 0.2)
        }
        MB::Sound.bg(:lead, lead.delay(3.n16, feedback: 0.4, wet: 0.3))
      end
      expect_budget(objects: 135, bytes: 17_000) # (before: 558, 67 kB; alloc-2: 107, 12.7 kB)
    end
  end
end
