require 'shellwords'

RSpec.describe('bin/synths/pluck.rb') do
  before(:all) { require File.expand_path('../../../bin/synths/pluck.rb', __dir__) }

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

  # The power-weighted mean frequency of +data+ in Hz, ignoring DC and
  # below 30 Hz (the string's slowly decaying DC)
  def centroid(data)
    x = Numo::DFloat.cast(data)
    s = Numo::Pocketfft.rfft(x).abs**2
    s[0...(30 * x.length / 48000.0).ceil] = 0
    f = Numo::DFloat.new(s.length).seq * (48000.0 / x.length)
    (s * f).sum / s.sum
  end

  # Averages over +seeds+ noise seeds of block's value for each render
  def seed_average(seeds = 4)
    seeds.times.map { |s| yield s }.sum / seeds
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

  describe 'velocity brightness' do
    it 'is the same as before at full velocity' do
      [33, 45, 81, 93].each do |n|
        ev = note_events(n, 1.0)
        expect(render(ev, 0.3)).to eq(render(ev, 0.3, velocity_brightness: false)), "note #{n}"
      end
    end

    it 'leaves the old velocity response alone with velocity_brightness: false (whatever the curve)' do
      ev = note_events(69, 0.4)
      old = render(ev, 0.2, velocity_brightness: false)
      expect(render(ev, 0.2, velocity_brightness: false, velocity_curve: :linear)).to eq(old)
      expect(render(ev, 0.2, velocity_brightness: false, velocity_curve: :smoothstep)).to eq(old)
      expect(render(ev, 0.2)).not_to eq(old)
    end

    it 'makes softer notes darker at every pitch' do
      [45, 69, 81, 93].each do |n|
        cents = [0.2, 0.5, 0.8, 1.0].map { |vel| seed_average { |s| centroid(window(render(note_events(n, vel), 0.1, seed: s), 0, 0.1)) } }
        expect(cents).to eq(cents.sort), "note #{n}: #{cents.map(&:round)}"
        expect(cents.first).to be < cents.last * 0.9, "note #{n}: #{cents.map(&:round)}"
      end
    end

    it 'moves soft low notes toward the clean voice' do
      soft = render(note_events(45, 0.1), 0.1)
      expect(soft[0...20].abs.max).to be < render(note_events(45, 0.1), 0.1, velocity_brightness: false)[0...20].abs.max * 0.5

      # Brightness 0 is the clean voice
      expect(render(note_events(45, 0.5), 0.2, velocity_brightness: 0.0)).to eq(render(note_events(45, 0.5), 0.2, voice: :clean, velocity_brightness: 0.0))
    end

    it 'keeps the ring level near the velocity-only voice and rising with velocity' do
      levels = [0.2, 0.5, 0.8, 1.0].map { |vel|
        [vel, seed_average { |s| rms_db(window(render(note_events(45, vel), 0.3, seed: s), 0.1, 0.3)) },
         seed_average { |s| rms_db(window(render(note_events(45, vel), 0.3, seed: s, velocity_brightness: false), 0.1, 0.3)) }]
      }
      levels.each do |vel, now, before|
        expect(now).to be_within(2.5).of(before), "velocity #{vel}: #{now.round(1)} dB, velocity only #{before.round(1)} dB"
      end
      expect(levels.map { |l| l[1] }).to eq(levels.map { |l| l[1] }.sort)
    end

    it 'takes a range, a curve, or a fixed brightness' do
      soft = note_events(45, 0.3)
      dark = seed_average { |s| centroid(window(render(soft, 0.1, seed: s), 0, 0.1)) }
      narrow = seed_average { |s| centroid(window(render(soft, 0.1, seed: s, velocity_brightness: 0.6..1.0), 0, 0.1)) }
      linear = seed_average { |s| centroid(window(render(soft, 0.1, seed: s, velocity_curve: :linear), 0, 0.1)) }
      fixed = seed_average { |s| centroid(window(render(soft, 0.1, seed: s, velocity_brightness: 1.0), 0, 0.1)) }
      full = seed_average { |s| centroid(window(render(note_events(45, 1.0), 0.1, seed: s), 0, 0.1)) }

      expect(narrow).to be > dark
      expect(linear).to be < dark
      expect(fixed).to be_within(3).percent_of(full)
      expect(rms_db(render(soft, 0.3, velocity_brightness: 1.0))).to be < rms_db(render(note_events(45, 1.0), 0.3)) - 6

      expect { render(soft, 0.1, velocity_brightness: 0..2) }.to raise_error(ArgumentError, /within 0..1/)
      expect { render(soft, 0.1, velocity_brightness: :loud) }.to raise_error(ArgumentError, /Range/)
    end

    it 'is the same for the same seed' do
      ev = note_events(57, 0.6)
      expect(render(ev, 0.2, seed: 3)).to eq(render(ev, 0.2, seed: 3))
      expect(render(ev, 0.2, seed: 3)).not_to eq(render(ev, 0.2, seed: 4))
    end
  end

  describe 'hammer-on finger bump' do
    def hammer_events(n)
      [E.note_on(n, 0.9, time: 0r), E.note_on(n + 2, 0.8, time: 1/2r), E.note_off(n + 2, time: 1r), E.note_off(n, time: 3/2r)]
    end

    # The ring a hammer-on adds (the loop is linear: with and without the hammer-on's pick)
    def hammer_ring(n, seed: 0, **options)
      ev = hammer_events(n)
      window(render(ev, 0.65, seed: seed, hammer: true, **options) - render(ev, 0.65, seed: seed, hammer: true, hammer_level: 0, pull_level: 0, **options), 0.5, 0.65)
    end

    it 'adds about as much ring as the noise pick, darker' do
      [45, 76].each do |n|
        rings = 5.times.map { |s| hammer_ring(n, seed: s, hammer_width: 0) }
        noise = rings.sum { |r| rms_db(r[960..]) } / rings.length
        finger_ring = hammer_ring(n, hammer_width: 0.5)
        finger = rms_db(finger_ring[960..])
        expect(finger).to be_within(2.5).of(noise), "note #{n}: finger #{finger.round(1)} dB, noise #{noise.round(1)} dB"

        # The default width (1 period, the user's pick) a little louder
        wide = rms_db(hammer_ring(n)[960..])
        expect(wide - noise).to be_between(-1.5, 5.5), "note #{n}: width 1 #{wide.round(1)} dB, noise #{noise.round(1)} dB"

        noise_centroid = rings.sum { |r| centroid(r) } / rings.length
        expect(centroid(finger_ring)).to be < noise_centroid * 0.85
      end
    end

    it 'is smoother when wider and the same at every seed' do
      expect(centroid(hammer_ring(45))).to be < centroid(hammer_ring(45, hammer_width: 0.5)) * 0.8
      expect(hammer_ring(45, seed: 1)).to be_within(1e-4).of(hammer_ring(45, seed: 2))
    end
  end

  describe 'hammer-on glide' do
    let(:events) {
      [E.note_on(45, 0.9, time: 0r), E.note_on(47, 0.8, time: 1/2r), E.note_off(47, time: 1r), E.note_off(45, time: 3/2r)]
    }

    it 'slides to the new pitch in a few ms without a click, then holds it' do
      instant = render(events, 0.65, hammer: true, hammer_glide: 0)
      glide = render(events, 0.65, hammer: true)
      expect(render(events, 0.65, hammer: true, hammer_glide: 4.ms)).to eq(glide)

      # The same before the hammer-on, different while it glides
      expect(window(glide, 0, 0.5)).to eq(window(instant, 0, 0.5))
      expect((window(glide, 0.5, 0.505) - window(instant, 0.5, 0.505)).abs.max).to be > 1e-3

      # The instant jump's click (a spike in the second difference, about 3x
      # the ringing string's; measured without the new pick) is about halved
      click = ->(d) { w = Numo::DFloat.cast(window(d, 0.499, 0.52)); (w[2..] - 2 * w[1...-1] + w[0...-2]).abs.max }
      silent = { hammer: true, hammer_level: 0, pull_level: 0 }
      expect(click.(render(events, 0.55, **silent))).to be < click.(render(events, 0.55, **silent, hammer_glide: 0)) * 0.6

      expect(pitch(window(glide, 0.52, 0.62), 80, 160)).to be_within(0.5).of(MB::Sound::B2.frequency)
    end
  end

  it 'has a dark tone preset' do
    ev = note_events(57, 0.8)
    dark = seed_average { |s| centroid(window(render(ev, 0.1, seed: s, tone: :dark), 0, 0.1)) }
    bright = seed_average { |s| centroid(window(render(ev, 0.1, seed: s), 0, 0.1)) }
    expect(dark).to be < bright * 0.9
    expect(render(ev, 0.1, tone: :dark)).to eq(render(ev, 0.1, velocity_brightness: 0.0..0.5))
    expect(render(ev, 0.1, tone: :dark, velocity_brightness: 1.0)).to eq(render(ev, 0.1, velocity_brightness: 1.0))
    expect { render(ev, 0.1, tone: :shiny) }.to raise_error(ArgumentError, /tone/)
  end

  it 'renders a MIDI file with --hammer, --bright, and --click' do
    out_file = tmp_path('pluck_hammer.flac')
    # In forks (see ForkScript); the example above is the real run
    out, status = fork_script('bin/synths/pluck.rb', *%w[-q --hammer --bright -C 0.5 spec/test_data/c_major.mid], out_file)
    expect(status).to be_success, out
    expect(File.size(out_file)).to be > 1000

    out, status = fork_script('bin/synths/pluck.rb', *%w[-q --hammer -G 0.1 spec/test_data/c_major.mid], out_file)
    expect(status).not_to be_success
    expect(out).to include('--glide or --hammer')
  end
end
