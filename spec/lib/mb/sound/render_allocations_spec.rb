# Guards for allocation-free rendering (alloc-1, 2026-10-21; measure the
# whole picture with bin/alloc_audit.rb).  Every object a buffer allocates
# costs GC time on the render thread, so render paths shouldn't build
# throwaway objects: these specs fail when recipe recording runs while
# sampling, or when a small fixed song's allocations per buffer grow.
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

  it 'allocates few objects per buffer in steady playback' do
    start_song
    render(1500)

    GC.start
    a0 = GC.stat(:total_allocated_objects)
    render(750)
    per_buffer = (GC.stat(:total_allocated_objects) - a0) / 750.0

    puts "\n\e[1mrender allocations: #{per_buffer.round(1)} objects per 128-frame buffer\e[0m" if ENV['ALLOC_REPORT']
    expect(per_buffer).to be < 600
  end
end
