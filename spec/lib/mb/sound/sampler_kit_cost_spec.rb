require_relative '../../../support/sf2_writer'

# What a SoundFont drum kit costs to render (sf2-cost-1, 2026-11-22: the
# maintainer's acoustic kit, `track :drums, sf2(...)` with a Euclidean
# clip, was named by the slow-player warning).  Acoustic kits release
# their one-shots over ~100 s (releaseVolEnv near its 8000 timecent
# limit), so a lane's envelope keeps releasing long after its sample
# ended.  These count work (blocks, allocations), not wall time.
RSpec.describe('SoundFont kit render cost', :aggregate_failures) do
  let(:m) { MB::Sound }

  # A kit of short mono hits on keys 36-38, two velocity layers each, with
  # a ~100 s release (as acoustic kits have) and a pan on the snare (any
  # pan makes the instrument stereo).
  def kit_path(release: 8000)
    path = tmp_path('kit.sf2')
    samples = []
    zones = []
    [36, 37, 38].each do |k|
      2.times do |l|
        data = Array.new(2000) { |i| Math.sin(2 * Math::PI * (80 + 200 * (k - 36)) * i / 44100.0) * Math.exp(-i / 400.0) * (0.4 + 0.4 * l) }
        samples << { name: "k#{k}l#{l}", data: data, rate: 44100, pitch: 60 }
        zones << { key_range: [k, k], vel_range: l == 0 ? [0, 63] : [64, 127], sample_id: samples.length - 1, pan: k == 38 ? 300 : 0 }
      end
    end
    SF2Writer.write(path, samples: samples,
      instruments: [{ name: 'Kit', global: { release_vol_env: release }, zones: zones }],
      presets: [{ name: 'Kit', program: 0, zones: [{ instrument: 0 }] }])
  end

  # Plays +clip+ on a patch track of the kit at +size+-frame buffers for
  # +seconds+; returns [session, left, right].
  def run(clip, size, seconds, path: kit_path)
    m.rewind
    m.seed(1)
    out = m::Sampler::CaptureOutput.new(channels: 2, buffer_size: size)
    s = m::Session.new(output: out, realtime: false)
    @sessions << s
    m::Session.with_context(session: s) {
      m.track(:drums, m.sf2(path))
      m.bg(:drums, clip)
    }
    (seconds * 48000 / size).ceil.times { |i| yield i * size / 48000.0 if block_given?; s.process_buffer }
    [s, *out.captured.first(2).map { |c| Numo::SFloat.cast(c)[0...(seconds * 48000).round] }]
  end

  before { @sessions = [] }
  after {
    @sessions.each(&:close)
    m.rewind
  }

  let(:beat) { m.seq(m::C2.n8, m::Cs2.n8, m::D2.n8.vel(1), m::C2.n8.vel(0.4)).loop }

  # Counts the sampler voices' whole and split blocks of +size+ once
  # +after+ seconds have played (every lane has played a note by then).
  def count_pieces(size, after)
    pieces = Hash.new(0)
    counting = false
    allow_any_instance_of(m::GraphNode::SamplerVoice).to receive(:sample).and_wrap_original { |orig, count|
      pieces[count == size ? :whole : :piece] += 1 if counting
      orig.call(count)
    }
    [pieces, ->(t) { counting = t >= after }]
  end

  it 'renders a lane waiting out a long release in whole blocks, not split at each grid point' do
    pieces, clock = count_pieces(512, 2.5)
    _, l512, r512 = run(beat, 512, 4) { |t| clock.(t) }
    # (a lane splits a block only where it could fall asleep; with its
    # envelope releasing for 100 s it can't, so its blocks stay whole but
    # for note events and the idle spare lanes: 148 pieces to 2200 whole
    # blocks; before, each lane split every block crossing an 800-sample
    # grid point: 2416 pieces to 1066)
    expect(pieces[:whole]).to be > 1000
    expect(pieces[:piece]).to be < pieces[:whole] / 10

    # the same samples as blocks that never cross a grid point
    _, l400, r400 = run(beat, 400, 4)
    expect(l512).to eq(l400)
    expect(r512).to eq(r400)
    expect(l512.abs.max).to be > 0.1
  end

  it 'still splits where a lane may fall asleep (a short release), the same samples at any buffer size' do
    pieces, clock = count_pieces(512, 2.5)
    path = kit_path(release: -6000)
    _, l512, = run(beat, 512, 4, path: path) { |t| clock.(t) }
    expect(pieces[:piece]).to be > 0
    _, l400, = run(beat, 400, 4, path: path)
    expect(l512).to eq(l400)
  end
end
