# Event-driven nodes left out of planning once their MIDI stream is over
# come back when the stream restarts or seeks (live sets loop and seek).
RSpec.describe('MB::Sound::Plan stream restarts') do
  around do |ex|
    old = MB::Sound::Plan.precision
    MB::Sound::Plan.precision = :exact
    ex.run
  ensure
    MB::Sound::Plan.precision = old
  end

  # c2_sustain.mid ends at 0.6875 s; the release rings on after that
  def end_sample = (0.6875 * 48000).ceil

  def make
    src = MB::Sound::MIDI::FileSource.new('spec/test_data/c2_sustain.mid')
    n = MB::Sound::Notes.new(MB::Sound::MIDI::Stream.new(src))
    [n.hz.ramp.pm(n.env * 2) * n.amp_env(0.01, 0.1, 0.5, 0.5), src]
  end

  # Renders with +jump+ (called with the source) once the stream has ended,
  # recording the installation's state a few blocks before and after.
  def render(plan, jump)
    g, src = make
    inst = plan ? MB::Sound::Plan.install(g) : nil
    sizes = [128, 37, 512, 1, 800]
    out = []
    jumped_at = nil
    info = {}
    300.times do |k|
      if jumped_at.nil? && out.length > end_sample + 4800
        info[:excluded_before] = inst&.excluded&.values&.grep(/stream is over/)&.length
        info[:members_before] = inst&.regions&.sum { |r| r.members.length }
        jump.call(src)
        jumped_at = k
      end
      info[:members_after] = inst.regions.sum { |r| r.members.length } if inst && jumped_at && k == jumped_at + 3

      b = g.sample(sizes[k % sizes.length])
      break if b.nil?

      out.concat(b.to_a)
    end
    [out, info]
  end

  {
    'restart' => ->(src) { src.restart },
    'a seek back' => ->(src) { src.seek(0.25) },
  }.each do |name, jump|
    it "plans the nodes again after #{name}, with the unplanned graph's samples" do
      planned, info = render(true, jump)
      unplanned, _ = render(false, jump)

      expect(info[:excluded_before]).to be > 3
      expect(info[:members_after]).to be > info[:members_before]
      expect(planned.length).to be > end_sample + 15000
      expect(planned).to eq(unplanned)
    end
  end

  it 'gives the same samples in check mode' do
    old = MB::Sound::Plan.check
    MB::Sound::Plan.check = :raise
    planned, info = render(true, ->(src) { src.restart })
    expect(info[:members_after]).to be > info[:members_before]
  ensure
    MB::Sound::Plan.check = old
  end
end
