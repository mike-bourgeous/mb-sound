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
