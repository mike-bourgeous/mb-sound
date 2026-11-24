RSpec.describe(MB::Sound::Tone, '#prime_render') do
  # demo-cold-start-1: a synced tone built BandLimit's sync tables (the sine
  # table: 75-125 ms and a major GC) in its first buffer, on the render
  # thread, in the first live buffer of a cold demo `start`.  Session#add
  # primes them now (GraphNodeInput#prime), on the thread adding the graph.
  let(:session) { MB::Sound::Session.new(realtime: false, output: MB::Sound::NullOutput.new(channels: 1, sleep: false), channels: 1, buffer_size: 512, transport: MB::Sound::Sequence::Transport.new(bpm: 120)) }

  after { session.close }

  # Runs the block with BandLimit's sync tables not built yet, counting the
  # sine table's builds by phase, then puts the built tables back.
  def with_fresh_tables
    bl = MB::Sound::BandLimit
    kept = %i[@sync_poly_tables @sync_sine_tables].to_h { |iv| [iv, bl.instance_variable_get(iv)] }
    kept.each_key { |iv| bl.instance_variable_set(iv, nil) }
    builds = []
    allow(bl).to receive(:sync_sine_table).and_wrap_original { |m, *a| builds << @phase; m.call(*a) }
    yield builds
  ensure
    kept.each { |iv, v| bl.instance_variable_set(iv, v) }
  end

  {
    'a hard-synced sine' => -> { 110.hz.sine.sync(ratio: 1.7) },
    'a hard-synced complex shape' => -> { 110.hz.complex_triangle.sync(ratio: 2) },
    'a reset complex shape (clean)' => -> {
      110.hz.complex_triangle.tap { |t| t.reset(MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(4096).tap { |z| z[700] = 1 }], repeat: true)) }.clean
    },
  }.each do |what, make|
    it "builds #{what}'s sine table where its graph is added, not in its first buffer" do
      tone = make.call
      with_fresh_tables do |builds|
        @phase = :add
        session.add(tone * 0.1, on: :now)
        @phase = :render
        2.times { session.process_buffer }
        expect(builds).to eq([:add])
      end
    end
  end

  it 'leaves the sine table unbuilt for synced waves other than sines' do
    with_fresh_tables do |builds|
      @phase = :add
      session.add(110.hz.saw.sync(ratio: 1.7) * 0.1, on: :now)
      @phase = :render
      2.times { session.process_buffer }
      expect(builds).to be_empty
      expect(MB::Sound::BandLimit.instance_variable_get(:@sync_poly_tables)).not_to be_nil
    end
  end

  it 'gives every wave the same tables as before the split' do
    poly = MB::Sound::BandLimit.sync_tables(:saw)
    sine = MB::Sound::BandLimit.sync_tables(:sine)
    expect(poly[5]).to be_nil
    expect(sine[0..4]).to eq(poly[0..4])
    expect(sine[5]).to eq(MB::Sound::BandLimit.sync_sine_table(poly[3]))
  end
end
