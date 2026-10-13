RSpec.describe('bin/synths/funk.rb') do
  before(:all) { require File.expand_path('../../../bin/synths/funk.rb', __dir__) }

  after { MB::Sound.rewind }

  it 'plays the mouth drums and the perc from GM notes' do
    beat = render_patch(MB::Sound.funk_beat(patch_notes([36, 0, 0.1, 1.0], [38, 0.5, 0.6, 1.0])), 1)[0]
    expect(peak_db(seconds(beat, 0, 0.4))).to be > -10
    expect(peak_db(seconds(beat, 0.5, 0.9))).to be > -10

    perc = render_patch(MB::Sound.funk_perc(patch_notes([70, 0, 0.1, 1.0], [64, 0.5, 0.6, 1.0])), 1)[0]
    expect(peak_db(perc)).to be > -25
    expect(band_share(perc, 0, 100)).to be < 0.02
  end

  it 'says the drums as vowels with beatbox:' do
    hits = -> { patch_notes([36, 0, 0.1, 1.0], [38, 0.5, 0.6, 1.0], [42, 0.75, 0.8, 1.0]) }
    plain = render_patch(MB::Sound.funk_beat(hits.()), 1)[0]
    boxed = render_patch(MB::Sound.funk_beat(hits.(), beatbox: true), 1)[0]
    expect(peak_db(boxed)).to be_within(4).of(peak_db(plain))
    # The kick's sine gets harmonics for its "boo"; the snare and hats move up
    expect(band_share(seconds(boxed, 0, 0.4), 150, 1000)).to be > band_share(seconds(plain, 0, 0.4), 150, 1000) * 2
    expect(rms_db(seconds(boxed, 0.5, 1))).to be_within(6).of(rms_db(seconds(plain, 0.5, 1)))
    half = render_patch(MB::Sound.funk_beat(hits.(), beatbox: 0.5), 1)[0]
    expect((half - boxed).abs.max).to be > 0.01
  end

  # Renders +graph+ (a block, built inside the render) for +bars+ at 96 BPM
  # in a Session, so tempo-synced LFOs follow the timeline; the left channel.
  def render_bars(bars)
    path = tmp_path('bars.flac')
    MB::Sound.render(path, bars: bars, overwrite: true, gain: 0.db) do
      MB::Sound.bpm 96
      MB::Sound.bg :x, MB::Sound.with_seed(3) { yield }, fade: 0
    end
    MB::Sound.read(path)[0]
  end

  # The share of +x+'s power from +lo+ to +hi+ Hz in each +step+ seconds.
  def band_steps(x, step, lo, hi)
    n = (step * 48000).round
    (x.length / n).times.map { |i| band_share(x[(i * n)...((i + 1) * n)].dup, lo, hi) }
  end

  it 'sweeps the mouth with wobble: (by default only the beatbox), so the backbeats say different vowels' do
    kit = -> { MB::Sound.grid(16, snare: '....X.......X...').loop }
    beat = 60.0 / 96
    snares = ->(x) { [1, 3].map { |b| band_share(seconds(x, b * beat, b * beat + 0.1).dup, 200, 1500) } }
    [false, true].each do |box|
      still = snares.(render_bars(1) { MB::Sound.funk_beat(kit.(), beatbox: box, wobble: 0) })
      swept = snares.(render_bars(1) { MB::Sound.funk_beat(kit.(), beatbox: box, wobble: 0.8) })
      default = snares.(render_bars(1) { MB::Sound.funk_beat(kit.(), beatbox: box) })
      expect(default).to eq(box ? swept : still), "beatbox: #{box}: the default wobbles only the beatbox"
      ratio = ->((a, b)) { (10 * Math.log10(a / b)).abs }
      expect(ratio.(swept)).to be > ratio.(still) + 1, "beatbox: #{box}: #{still} -> #{swept}"
    end
  end

  it 'moves the talkbox\'s mouth with the groove on a held note with groove:' do
    held = -> { MB::Sound.seq(MB::Sound::A4.n1).loop }
    still = band_steps(render_bars(1) { MB::Sound.funk_talkbox_voice(held.(), echo: 0, groove: 0) }, 60.0 / 96 / 8, 900, 2500)[8..]
    moving = band_steps(render_bars(1) { MB::Sound.funk_talkbox_voice(held.(), echo: 0) }, 60.0 / 96 / 8, 900, 2500)[8..]
    spread = ->(v) { db = v.map { 10 * Math.log10(_1) }; db.max - db.min }
    expect(spread.(moving)).to be > spread.(still) + 2
  end

  it 'plays the bass louder and a little brighter with velocity' do
    d2 = MB::Sound::D2.number
    soft = render_patch(MB::Sound.funk_bass_voice(patch_notes([d2, 0, 0.5, 0.3])), 0.5)[0]
    hard = render_patch(MB::Sound.funk_bass_voice(patch_notes([d2, 0, 0.5, 1.0])), 0.5)[0]
    expect(peak_hz(seconds(hard, 0.05, 0.45), 40, 120)).to be_within(3).of(MB::Sound::D2.frequency)
    expect(rms_db(seconds(hard, 0, 0.1))).to be > rms_db(seconds(soft, 0, 0.1)) + 9
    # (the saw's lowpass opens with velocity, but the sine body dominates:
    # 1.38% of the power at 300 Hz-3 kHz at velocity 0.3, 1.46% at 1.0)
    expect(band_share(seconds(hard, 0, 0.1), 300, 3000)).to be > band_share(seconds(soft, 0, 0.1), 300, 3000)
  end

  it 'plays the keys, clav, and talkbox' do
    {
      keys: [MB::Sound.funk_keys_voice(patch_notes([MB::Sound::F3.number, 0, 0.5], [MB::Sound::A3.number, 0, 0.5])), 2],
      clav: [MB::Sound.funk_clav_voice(patch_notes([MB::Sound::Gs4.number, 0, 0.1])), 1],
      talkbox: [MB::Sound.funk_talkbox_voice(patch_notes([MB::Sound::D5.number, 0, 0.5])), 1],
    }.each do |name, (graph, channels)|
      out = render_patch(graph, 1)
      expect(out.length).to eq(channels), name.to_s
      expect(peak_db(out[0])).to be_between(-40, 0), "#{name}: #{peak_db(out[0]).round(1)} dB"
    end
  end

  it 'loops the choir only while the footswitch is down, losing 1 - keep each pass' do
    MB::Sound.transport.bpm = 120 # 4 bars = 8 s
    chord = -> { patch_notes([MB::Sound::A3.number, 0, 1], [MB::Sound::D4.number, 0, 1]) }
    dry = render_patch(MB::Sound.funk_dub_loop(MB::Sound.funk_choir_voice(chord.()), dub: 0), 10)[0]
    dubbed = render_patch(MB::Sound.funk_dub_loop(MB::Sound.funk_choir_voice(chord.()), dub: 1, keep: 0.5), 10)[0]
    expect(rms_db(seconds(dry, 8.2, 8.8))).to be < -100
    expect(rms_db(seconds(dubbed, 8.2, 8.8))).to be_within(1).of(rms_db(seconds(dubbed, 0.2, 0.8)))
  ensure
    MB::Sound.rewind
  end

  it 'renders the choir with its looper from a MIDI file' do
    out_file = tmp_path('funk_choir.flac')
    out, status = fork_script('bin/synths/funk.rb', '-q', '-p', 'choir', '-d', '1', '-k', '0.5', 'spec/test_data/c_major.mid', out_file)
    expect(status).to be_success, out
    expect(MB::Sound.read(out_file)[0].abs.max).to be > 0.001
  end
end
