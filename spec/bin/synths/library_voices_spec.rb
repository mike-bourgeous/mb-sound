# The library voices (one instrument per synthesis approach; each is also a
# preset, checked against its document in save_presets_spec.rb).
require File.expand_path('../../../bin/synths/library_voices.rb', __dir__)

RSpec.describe('bin/synths/library_voices.rb') do
  after { MB::Sound.rewind }

  # A short phrase in each voice's register: two overlapping notes (legato
  # for the mono voices' glide), then a chord released at 0.45 s
  def phrase(name)
    tags = MB::Sound::LIBRARY_VOICES.fetch(name)[:tags]
    base = tags.include?(:bass) ? 33 : tags.include?(:lead) ? 69 : 57
    patch_notes([base, 0, 0.2, 1.0], [base + 7, 0.18, 0.3, 0.7], [base, 0.32, 0.45, 0.9], [base + 4, 0.32, 0.45, 0.9], [base + 7, 0.32, 0.45, 0.9])
  end

  def render(name, seconds = 0.6, **knobs)
    MB::Sound.with_seed(0) { render_patch(MB::Sound.library_voice(phrase(name), name, **knobs), seconds) }
  end

  it 'plays every voice at a usable level, finite, without DC' do
    MB::Sound::LIBRARY_VOICES.each_key do |name|
      data = render(name)
      expect(data.length).to be_between(1, 2), name.to_s
      data.each do |c|
        expect(c.isfinite.all?).to be(true), name.to_s
        expect(peak_db(c)).to be_between(-16, 7), "#{name} #{peak_db(c).round(1)}" # (before the master's -10 dB; the pluck's chord peaks highest)
        expect(c.mean.abs).to be < 0.01 * c.abs.max, name.to_s
      end
    end
  end

  MB::Sound::LIBRARY_VOICES.each do |name, s|
    it "reads every knob of #{name}: turning one changes the sound" do
      plain = render(name)
      s[:knobs].each do |knob, (default, range, _description)|
        other = (default - range.begin).abs > (range.end - default).abs ? range.begin : range.end
        turned = render(name, **{ knob => other })
        diff = plain.zip(turned).map { |a, b| rms_db(a[0...[a.length, b.length].min] - b[0...[a.length, b.length].min]) - rms_db(a) }.max
        expect(diff).to be > -60, "#{name} #{knob} #{default} -> #{other}"
      end
    end
  end

  # The energy more than 3% away from every harmonic of +f0+, in dB under
  # the total, of +data+ from +a+ to +b+ seconds.
  def between_harmonics_db(data, f0, a, b)
    s = seconds(data, a, b)
    n = 16384
    s = s.concatenate(Numo::SFloat.zeros([n - s.length, 0].max))[0...n]
    m = MB::Sound.real_fft(s * Numo::SFloat.new(n).seq.map { |i| 0.5 - 0.5 * Math.cos(2 * Math::PI * i / n) }).abs**2
    h = (Numo::DFloat.new(m.length).seq * 48000.0 / n / f0)
    near = ((h - h.round).abs / h.round.clip(1, nil)).lt(0.03) & h.round.gt(0)
    10 * Math.log10(m[near.eq(0)].sum / m.sum)
  end

  def held(name, note, seconds, **knobs)
    MB::Sound.with_seed(0) { render_patch(MB::Sound.library_voice(patch_notes([note, 0, seconds - 0.2, 0.8]), name, **knobs), seconds)[0] }
  end

  it 'keeps breath_vowel\'s breath near the harmonics, lower while a note holds (Bench round 2)' do
    data = held(:breath_vowel, 69, 1.4, vibrato: 0)
    early = between_harmonics_db(data, 440, 0.03, 0.2)
    steady = between_harmonics_db(data, 440, 0.6, 1.2)
    expect(steady).to be < -28 # (round 1, broadband breath: -22.9 dB; now -33.4)
    expect(steady).to be < early - 10
  end

  it 'plays noise_bands in narrow bands (Bench round 2: "Bands too wide")' do
    expect(between_harmonics_db(held(:noise_bands, 57, 1.4), 220, 0.6, 1.2)).to be < -12 # (round 1, Q 40: -6.6 dB; now -13.9)
  end

  it 'restarts sync_lead\'s sweep on every note, legato or not (Bench round 2: "only one attack")' do
    # (each note's start is brighter than its end: crossings of zero per second)
    zc = ->(x) { (x[1..] * x[0...-1]).lt(0).count_true / (x.length / 48000.0) }
    notes = [[69, 0, 0.26], [72, 0.25, 0.51], [76, 0.5, 0.76], [74, 0.75, 1.0]]
    data = MB::Sound.with_seed(0) { render_patch(MB::Sound.library_voice(patch_notes(*notes), :sync_lead), 1.0)[0] }
    notes.each do |_, on, _|
      expect(zc.(seconds(data, on + 0.005, on + 0.03))).to be > 1.3 * zc.(seconds(data, on + 0.17, on + 0.24)), "note at #{on}"
    end
  end

  it 'takes nodes for knobs and refuses knobs a voice lacks' do
    a = render(:fm_ep, index: 3.0)
    b = render(:fm_ep, index: 3.0.constant)
    expect(b).to eq(a)
    expect { MB::Sound.library_voice(phrase(:fm_ep), :fm_ep, sweep: 2) }.to raise_error(ArgumentError, /fm_ep has no knob :sweep.*index/)
    expect { MB::Sound.library_voice(phrase(:fm_ep), :nope) }.to raise_error(ArgumentError, /Unknown library voice :nope/)
  end

  it 'gives every voice a description, tags with its role, and knob descriptions' do
    MB::Sound::LIBRARY_VOICES.each do |name, s|
      expect(s[:about]).to match(/\A[A-Z].{40,}[^.]\z/), name.to_s
      expect(s[:tags] & %i[bass lead keys pad pluck]).not_to be_empty, name.to_s
      s[:knobs].each_value { |default, range, description| expect([range.cover?(default), description.length > 8]).to eq([true, true]) }
    end
  end
end
