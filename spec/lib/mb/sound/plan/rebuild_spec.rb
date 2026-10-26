# Plan rebuilds when parts of a graph end (render-rebuild-1): how many
# rebuilds a song's end costs, and that every way of rebuilding gives the
# unplanned samples.
RSpec.describe('Plan rebuilds') do
  after { MB::Sound.rewind }

  # A Synth whose voices have three envelopes on one note stream and a sum
  # whose summands end (as fm_bass's lanes), inside a graph a Session
  # installs plans on too, over a clip that ends: when the stream is over
  # every lane's envelopes and envelope inputs leave the plans.
  def ending_song
    m = MB::Sound
    clip = m.seq(m::C3, m::E3, m::G3, m::C4, [m::E3, m::G3]).n8
    synth = m::Synth.new(clip, voices: 3) { |v|
      a = v.fm_env(0, 0.2, 0, 0.1)
      b = v.amp_env(0.001, 0.3, 0.5, 0.1)
      c = v.fm_env(0, 0.1, 0.3, 0.05)
      base = v.hz.glide(50.ms)
      (b * base.sine.pm(a * base.transpose(12).sine + c * base.sine)) * 0.2
    }
    [synth, synth.softclip(0.8, 0.95) + synth.delay(10.ms) * 0.3]
  end

  # Renders the song through an offline Session (+buffers+ buffers of
  # +count+ frames), returning the Synth, the Session's installation, and
  # the buffers.
  def render_song(plan, count: 128, buffers: 600)
    MB::Sound::Plan.enabled = plan
    MB::Sound.rewind
    MB::Sound.with_seed(5) {
      synth, graph = ending_song
      session = MB::Sound::Session.new(realtime: false, buffer_size: count, output: MB::Sound::NullOutput.new(channels: 2, sleep: false, buffer_size: count))
      session.add(graph)
      out = Array.new(buffers) { session.process_buffer(count).map(&:dup) }
      outer = plan ? MB::Sound::Plan.watch[synth].keys.reject { |i| synth.plans.include?(i) }.first : nil
      session.close
      [synth, outer, out]
    }
  ensure
    MB::Sound::Plan.enabled = true
  end

  it 'gives the unplanned samples when every lane\'s envelopes end' do
    _, _, planned = render_song(true)
    _, _, unplanned = render_song(false)
    expect(planned.map { |b| b.map(&:to_binary) }).to eq(unplanned.map { |b| b.map(&:to_binary) })
  end

  it 'leaves out every feeder of a region whose stream is over in one rebuild' do
    # The three envelopes of a lane read one stream, so they finish in the
    # same block; they were found one block at a time (each block unfused
    # and each a rebuild of the lane: 5 rebuilds of some lanes here, up to
    # 4 per lane per buffer in fm_bass)
    synth, _, _ = render_song(true)
    lanes = synth.plans.compact
    expect(lanes.length).to eq(synth.lanes.length)
    expect(lanes.map(&:rebuilds).max).to be <= 3
  end

  it 'never plans a node another installation left out' do
    # The Session's installation reaches the lanes' nodes through the
    # Synth; it took over the nodes the lanes left out (45 here), then
    # rebuilt its whole graph for each one as it ended in turn (18 of
    # fm_bass's rebuilds, up to 9 in one buffer)
    synth, outer, _ = render_song(true)
    expect(outer).not_to be_nil
    left_out = synth.plans.compact.flat_map { |i| i.excluded.keys }
    expect(left_out.length).to be > 30
    claimed = outer.regions.flat_map(&:members).select { |m| left_out.any? { |n| n.equal?(m) } }
    expect(claimed).to be_empty
    expect(outer.candidate_reason(left_out.first)).to start_with('left out by another installation')
  end
end
