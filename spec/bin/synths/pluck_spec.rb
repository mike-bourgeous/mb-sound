require 'shellwords'

RSpec.describe('bin/synths/pluck.rb') do
  before(:all) { load File.expand_path('../../../bin/synths/pluck.rb', __dir__) }

  E = MB::Sound::MIDI::Event unless defined?(E)

  def render(events, seconds, seed: 0, **options)
    MB::Sound.seed(seed)
    synth = MB::Sound::Synth.new(MB::Sound::MIDI::Stream.new(MIDIListSource.new(*events)), voices: 1) { |v| MB::Sound.pluck_voice(v, **options) }
    out = []
    (seconds * 48000 / 480).round.times { b = synth.sample(480); break if b.nil?; out.concat(b.to_a) }
    Numo::SFloat.cast(out)
  end

  def note_events(number, velocity = 0.9)
    [E.note_on(number, velocity, time: 0r), E.note_off(number, time: 1r)]
  end

  def window(data, from, to)
    data[(from * 48000).round...(to * 48000).round]
  end

  def rms_db(data)
    10 * Math.log10((data**2).mean + 1e-30)
  end

  # The fundamental of +data+ in Hz from its autocorrelation's strongest
  # peak between +lo+ and +hi+ Hz
  def pitch(data, lo, hi)
    x = Numo::DFloat.cast(data) - data.mean
    lags = ((48000 / hi).floor..(48000 / lo).ceil).to_a
    corr = lags.map { |l| (x[0...(x.length - l)] * x[l..]).sum / (x.length - l) }
    i = corr.each_with_index.max[1]
    # parabolic interpolation
    a, b, c = corr[i - 1], corr[i], corr[i + 1]
    lag = lags[i] + 0.5 * (a - c) / (a - 2 * b + c)
    48000 / lag
  end

  let(:note) { note_events(45) }

  it 'renders a MIDI file with the attack, brightness, and glide options' do
    out_file = tmp_path('pluck.flac')
    out = `bin/synths/pluck.rb -q -a 2 -A s -H 9000 -G 0.1 -v 1 spec/test_data/c_major.mid #{out_file.shellescape} 2>&1`
    expect($?).to be_success, out
    expect(File.size(out_file)).to be > 1000
  end

  it 'fades the clean voice in over --attack periods after the first period' do
    period = (48000 / 110.0).round
    plain = render(note, 0.2, voice: :clean, attack: 0)
    faded = render(note, 0.2, voice: :clean, attack: 2)
    expect(faded[0...(period - 2)].abs.max).to eq(0)
    expect(faded[period...(2 * period)].abs.max).to be < plain[period...(2 * period)].abs.max * 0.6
    expect((faded[(4 * period)...(5 * period)] - plain[(4 * period)...(5 * period)]).abs.max).to be < 1e-3 * plain.abs.max
  end

  it 'glides legato notes without plucking again' do
    events = [E.note_on(45, 0.9, time: 0r), E.note_on(52, 0.9, time: 1/2r), E.note_off(45, time: 0.55r), E.note_off(52, time: 1r)]
    glide = render(events, 0.8, glide: 0.1)
    pluck = render(events, 0.8)
    before = glide[(0.45 * 48000).round...(0.5 * 48000).round].abs.max
    after = glide[(0.5 * 48000).round...(0.56 * 48000).round].abs.max
    expect(after).to be < before * 1.3
    expect(pluck[(0.5 * 48000).round...(0.56 * 48000).round].abs.max).to be > before * 3
  end

  describe 'voices by pitch' do
    it 'plays the bright voice from the note-on at low notes and the clean one after a period at high notes' do
      low = render(note_events(45), 0.1)
      expect(low[0...20].abs.max).to be > 0
      expect(low).to eq(render(note_events(45), 0.1, voice: :bright))

      high = render(note_events(93), 0.1)
      expect(high[0...20].abs.max).to eq(0)
      expect(high).to eq(render(note_events(93), 0.1, voice: :clean))
    end

    it 'crossfades between the two around the crossover' do
      mid = render(note_events(81), 0.3)
      bright = render(note_events(81), 0.3, voice: :bright)
      clean = render(note_events(81), 0.3, voice: :clean)
      expect(mid).not_to eq(bright)
      expect(mid).not_to eq(clean)

      expect(render(note_events(81), 0.3, crossover: 4000)).to eq(bright)
      expect(render(note_events(81), 0.3, crossover: 200)).to eq(clean)
    end

    # (one noise burst's ring varies by several dB, so these average a few)
    it 'keeps the bright ring near the clean ring at every pitch' do
      [33, 45, 69, 93].each do |n|
        bright = 4.times.map { |s| rms_db(window(render(note_events(n), 0.3, seed: s, voice: :bright), 0.1, 0.3)) }.sum / 4
        clean = 4.times.map { |s| rms_db(window(render(note_events(n), 0.3, seed: s, voice: :clean), 0.1, 0.3)) }.sum / 4
        expect(bright).to be_within(4).of(clean), "note #{n}: bright #{bright.round(1)} dB, clean #{clean.round(1)} dB"
      end
    end

    it 'lowers the bright voice\'s click with --click without changing its ring' do
      full = render(note, 0.3, voice: :bright)
      soft = render(note, 0.3, voice: :bright, click: 0.5)
      expect(rms_db(window(soft, 0, 0.008))).to be < rms_db(window(full, 0, 0.008)) - 4
      expect(rms_db(window(soft, 0.1, 0.3))).to be_within(1).of(rms_db(window(full, 0.1, 0.3)))
    end
  end

  describe 'hammer-ons and pull-offs' do
    # A2 picked, hammer-on to B2 at 0.5 s, pull-off back to A2 at 1 s
    let(:events) {
      [E.note_on(45, 0.9, time: 0r), E.note_on(47, 0.8, time: 1/2r), E.note_off(47, time: 1r), E.note_off(45, time: 3/2r)]
    }

    it 'jumps to the new pitch at once and keeps the string ringing with a small new pick' do
      hammer = render(events, 1.4, hammer: true)
      repluck = render(events, 1.4)

      expect(pitch(window(hammer, 0.52, 0.62), 80, 160)).to be_within(0.5).of(MB::Sound::B2.frequency)
      expect(pitch(window(hammer, 1.02, 1.12), 80, 160)).to be_within(0.5).of(MB::Sound::A2.frequency)

      # The ring goes on (no fade from silence as a new pluck has), with a
      # smaller burst than a new pick
      before = rms_db(window(hammer, 0.45, 0.5))
      expect(rms_db(window(hammer, 0.5, 0.505))).to be > before - 3
      expect(window(hammer, 0.5, 0.55).abs.max).to be < window(repluck, 0.5, 0.55).abs.max * 0.5
      expect(window(hammer, 1.0, 1.05).abs.max).to be < window(repluck, 1.0, 1.05).abs.max * 0.5
    end

    it 'picks harder for hammer-ons than for pull-offs, and not at all with zero levels' do
      none = render(events, 1.2, hammer: true, hammer_level: 0, pull_level: 0)
      up = render(events, 1.2, hammer: true, hammer_level: 0.3, pull_level: 0)
      down = render(events, 1.2, hammer: true, hammer_level: 0, pull_level: 0.3)

      expect(rms_db(window(up, 0.505, 0.53))).to be > rms_db(window(none, 0.505, 0.53)) + 2
      # (the hammer-on's pick rings on, but the pull-off adds none to it)
      diff = up - none
      expect(rms_db(window(diff, 1.005, 1.03))).to be < rms_db(window(diff, 0.97, 0.995)) + 1
      expect(window(down, 0.5, 0.6)).to eq(window(none, 0.5, 0.6))
      expect(rms_db(window(down, 1.005, 1.03))).to be > rms_db(window(none, 1.005, 1.03)) + 2
    end

    it 'refuses a glide with hammer-ons' do
      expect { render(events, 0.1, hammer: true, glide: 0.1) }.to raise_error(ArgumentError, /glide or hammer/)
    end
  end

  it 'renders a MIDI file with --hammer, --bright, and --click' do
    out_file = tmp_path('pluck_hammer.flac')
    out = `bin/synths/pluck.rb -q --hammer --bright -C 0.5 spec/test_data/c_major.mid #{out_file.shellescape} 2>&1`
    expect($?).to be_success, out
    expect(File.size(out_file)).to be > 1000

    out = `bin/synths/pluck.rb -q --hammer -G 0.1 spec/test_data/c_major.mid #{out_file.shellescape} 2>&1`
    expect($?).not_to be_success
    expect(out).to include('--glide or --hammer')
  end
end
