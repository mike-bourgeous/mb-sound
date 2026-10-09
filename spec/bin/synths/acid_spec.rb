require 'shellwords'

RSpec.describe('bin/synths/acid.rb') do
  before(:all) { load File.expand_path('../../../bin/synths/acid.rb', __dir__) }

  # Renders +count+ samples of +node+ in 800-sample buffers
  def render(node, count)
    bufs = []
    total = 0
    while total < count && (b = node.sample(800))
      bufs << b.dup
      total += b.length
    end
    bufs.reduce(:concatenate)[0...count]
  end

  def rms(data)
    Math.sqrt((Numo::DFloat.cast(data)**2).mean)
  end

  let(:s) { MB::Sound }
  let(:plain) { s.acid(s::A1, s::A1, s::A1, s::A1, s::A1, s::A1, s::A1, s::A1) }
  let(:accented) { s.acid(!s::A1, !s::A1, !s::A1, !s::A1, !s::A1, !s::A1, !s::A1, !s::A1) }

  it 'plays a clip' do
    out = render(s.acid_voice(plain), 48000)
    expect(out.abs.max).to be_between(0.05, 0.95)
    expect(out.isfinite.all?).to eq(true)
  end

  it 'makes accents louder, building up over a run with the sweep' do
    a = render(s.acid_voice(accented), 48000)
    expect(rms(a)).to be > rms(render(s.acid_voice(plain), 48000)) * 1.3

    # 120 BPM: notes every 6000 samples; the fourth accent is brighter (more
    # energy in the first difference) than the first with the sweep, and
    # about the same as the second without
    bright = ->(d, from) { rms(d[(from + 1)...(from + 3000)] - d[from...(from + 2999)]) }
    flat = render(s.acid_voice(accented, sweep: false), 48000)
    expect(bright.(a, 18000)).to be > bright.(a, 0) * 1.2
    expect(bright.(flat, 18000)).to be_within(5).percent_of(bright.(flat, 6000))
  end

  it 'holds the sound through slides and gaps it otherwise' do
    slid = s.acid(~s::A1, ~s::C2, ~s::A1, s::C2)
    # 120 BPM: a sixteenth is 6000 samples; without slides the gate closes
    # at 3000
    out = render(s.acid_voice(slid), 24000)
    gap = render(s.acid_voice(s.acid(s::A1, s::C2, s::A1, s::C2)), 24000)
    expect(out[4000...5800].abs.max).to be > 0.02
    expect(gap[4000...5800].abs.max).to be < out[4000...5800].abs.max * 0.2
  end

  it 'takes the lp4, square waves, and node knobs' do
    d = render(s.acid_voice(plain), 24000)
    l = render(s.acid_voice(plain, filter: :lp4, wave: :square, cutoff: 2.hz.lfo.at(200..800), reso: 0.4.constant), 24000)
    expect(l.abs.max).to be > 0.02
    expect(l).not_to eq(d)
    expect { s.acid_voice(plain, filter: :moog) }.to raise_error(ArgumentError, /moog/)
  end
end
