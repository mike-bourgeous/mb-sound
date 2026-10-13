RSpec.describe('bin/synths/dnb.rb') do
  before(:all) { require File.expand_path('../../../bin/synths/dnb.rb', __dir__) }

  after { MB::Sound.rewind }

  let(:f1) { MB::Sound::F1.number }

  it 'plays a stereo Reese whose low end stays mono, highpassed off the sub' do
    l, r = render_patch(MB::Sound.dnb_reese_voice(patch_notes([f1, 0, 1.5])), 1.5)
    expect(peak_db(l)).to be_between(-12, 6)
    expect(l).not_to eq(r) # spread
    expect(band_share(seconds(l, 0.2, 1.4), 0, 80)).to be < 0.01
    side = seconds(l - r, 0.2, 1.4)
    expect(band_share(side, 0, 120) * rms_db(side)).to be < 1 # little side energy below the highpass
  end

  it 'opens the Reese with its cutoff knob' do
    dark = render_patch(MB::Sound.dnb_reese_voice(patch_notes([f1, 0, 1]), cutoff: 300), 1)[0]
    bright = render_patch(MB::Sound.dnb_reese_voice(patch_notes([f1, 0, 1]), cutoff: 6000), 1)[0]
    expect(band_share(seconds(bright, 0.2, 0.9), 2000, 20000)).to be > band_share(seconds(dark, 0.2, 0.9), 2000, 20000) * 10
  end

  it 'plays a clean sub with harmonics: false: the note\'s sine, nothing above the lowpass' do
    sub = render_patch(MB::Sound.dnb_sub_voice(patch_notes([f1, 0, 1]), harmonics: false), 1)[0]
    expect(peak_hz(seconds(sub, 0.2, 0.9), 20, 400)).to be_within(1.5).of(MB::Sound::F1.frequency)
    expect(band_share(seconds(sub, 0.2, 0.9), 300, 24000)).to be < 5e-3
  end

  it 'adds the 2nd and 3rd harmonics to the sub with harmonics:, keeping its RMS' do
    plain = render_patch(MB::Sound.dnb_sub_voice(patch_notes([f1, 0, 1]), harmonics: false), 1)[0]
    rich = render_patch(MB::Sound.dnb_sub_voice(patch_notes([f1, 0, 1]), harmonics: [0.4, 0.2]), 1)[0]
    f = MB::Sound::F1.frequency
    expect(band_share(seconds(rich, 0.2, 0.9), f * 1.5, f * 2.5)).to be_within(0.03).of(0.4**2 / 1.2)
    expect(band_share(seconds(rich, 0.2, 0.9), f * 2.5, f * 3.5)).to be_within(0.02).of(0.2**2 / 1.2)
    expect(rms_db(seconds(rich, 0.2, 0.9))).to be_within(0.5).of(rms_db(seconds(plain, 0.2, 0.9)))
  end

  it 'adds quieter dnb harmonics to the sub by default (harmonics: true)' do
    rich = render_patch(MB::Sound.dnb_sub_voice(patch_notes([f1, 0, 1])), 1)[0]
    expect((rich - render_patch(MB::Sound.dnb_sub_voice(patch_notes([f1, 0, 1]), harmonics: true), 1)[0]).abs.max).to eq(0)
    f = MB::Sound::F1.frequency
    h2, h3 = MB::Sound::DNB_SUB_HARMONICS
    power = 1 + h2**2 + h3**2
    loud = render_patch(MB::Sound.dnb_sub_voice(patch_notes([f1, 0, 1]), harmonics: [0.4, 0.2]), 1)[0]
    # (the lowpass takes a little of the fundamental, so the shares are a bit over h**2 / power)
    expect(band_share(seconds(rich, 0.2, 0.9), f * 1.5, f * 2.5)).to be_between(h2**2 / power, h2**2 / power * 1.5)
    expect(band_share(seconds(rich, 0.2, 0.9), f * 2.5, f * 3.5)).to be_between(h3**2 / power, h3**2 / power * 1.5)
    expect(band_share(seconds(rich, 0.2, 0.9), f * 1.5, f * 3.5)).to be < band_share(seconds(loud, 0.2, 0.9), f * 1.5, f * 3.5) / 3
  end

  it 'adds high end to the neuro bass with sync:, fold:, and noise:' do
    plain = render_patch(MB::Sound.with_seed(4) { MB::Sound.dnb_neuro_voice(patch_notes([f1, 0, 1])) }, 1)[0]
    top = band_share(seconds(plain, 0.1, 0.9), 4000, 24000)
    [:sync, :fold, :noise].each do |k|
      bright = render_patch(MB::Sound.with_seed(4) { MB::Sound.dnb_neuro_voice(patch_notes([f1, 0, 1]), k => 1) }, 1)[0]
      expect(band_share(seconds(bright, 0.1, 0.9), 4000, 24000)).to be > top * 1.5, k.to_s
      expect(peak_db(bright)).to be_between(-20, 6), k.to_s
    end
  end

  it 'crushes the neuro bass more with more grit' do
    clean = render_patch(MB::Sound.dnb_neuro_voice(patch_notes([f1, 0, 1]), grit: 0), 1)[0]
    gritty = render_patch(MB::Sound.dnb_neuro_voice(patch_notes([f1, 0, 1]), grit: 1), 1)[0]
    expect(peak_db(clean)).to be_between(-20, 3)
    expect((gritty - clean).abs.max).to be > 0.05
  end

  it 'rings the pad, pluck, and boom out in stereo after their notes' do
    {
      pad: MB::Sound.dnb_pad_voice(patch_notes([MB::Sound::F3.number, 0, 1], [MB::Sound::C4.number, 0, 1])),
      pluck: MB::Sound.dnb_pluck_voice(patch_notes([MB::Sound::C5.number, 0, 0.1])),
      boom: MB::Sound.dnb_boom_voice(patch_notes([f1, 0, 0.2])),
    }.each do |name, graph|
      l, r = render_patch(graph, 2.5)
      expect(peak_db(l)).to be > -40, name.to_s
      expect(rms_db(seconds(l, 1.5, 2.5))).to be > -110, name.to_s # the tail
      expect(l).not_to eq(r), name.to_s
    end
  end

  it 'plays the drums from GM notes, and the ghost kick is the drums\' kick' do
    kick = 36
    drums = render_patch(MB::Sound.dnb_drums(patch_notes([kick, 0, 0.1, 1.0])), 0.5)[0]
    ghost = render_patch(MB::Sound.dnb_ghost_kick(patch_notes([kick, 0, 0.1, 1.0])), 0.5)[0]
    expect(peak_db(drums)).to be > -12
    expect(peak_hz(seconds(ghost, 0.05, 0.4), 30, 200)).to be_within(6).of(54)
    expect(peak_hz(seconds(drums, 0.05, 0.4), 30, 200)).to be_within(6).of(54)
  end

  it 'tightens and highpasses only the kick with tight:, leaving the snare alone' do
    hits = -> { patch_notes([36, 0, 0.1, 1.0], [38, 0.5, 0.6, 1.0]) }
    full = render_patch(MB::Sound.dnb_drums(hits.(), parallel: 0), 1)[0]
    tight = render_patch(MB::Sound.dnb_drums(hits.(), parallel: 0, tight: true), 1)[0]
    expect(band_share(seconds(tight, 0, 0.45), 0, 60)).to be < band_share(seconds(full, 0, 0.45), 0, 60) / 4
    expect(peak_hz(seconds(tight, 0.01, 0.2), 30, 200)).to be_within(8).of(54 * 2**(5 / 12.0))
    expect(rms_db(seconds(tight, 0.25, 0.45))).to be < rms_db(seconds(full, 0.25, 0.45)) - 20 # (a shorter decay)
    snare = render_patch(MB::Sound.with_seed(3) { MB::Sound.dnb_drums(patch_notes([38, 0, 0.1, 1.0]), parallel: 0) }, 0.5)[0]
    tight_snare = render_patch(MB::Sound.with_seed(3) { MB::Sound.dnb_drums(patch_notes([38, 0, 0.1, 1.0]), parallel: 0, tight: true) }, 0.5)[0]
    expect((tight_snare - snare).abs.max).to be < 1e-6
  end

  it 'splashes the snare (not the kick) into a gated room with room:, in stereo' do
    kick = render_patch(MB::Sound.dnb_drums(patch_notes([36, 0, 0.1, 1.0]), parallel: 0), 1)
    kick_room = render_patch(MB::Sound.dnb_drums(patch_notes([36, 0, 0.1, 1.0]), parallel: 0, room: true), 1)
    expect((kick_room[0][0...kick[0].length] - kick[0]).abs.max).to be < 1e-6
    snare = render_patch(MB::Sound.with_seed(3) { MB::Sound.dnb_drums(patch_notes([38, 0, 0.1, 1.0]), parallel: 0) }, 1)
    roomy = render_patch(MB::Sound.with_seed(3) { MB::Sound.dnb_drums(patch_notes([38, 0, 0.1, 1.0]), parallel: 0, room: true) }, 1)
    expect(roomy[0]).not_to eq(roomy[1])
    expect(rms_db(seconds(roomy[0], 0.12, 0.22))).to be > rms_db(seconds(snare[0], 0.12, 0.22)) + 6 # the splash
    expect(rms_db(seconds(roomy[0], 0.6, 1.0))).to be < rms_db(seconds(roomy[0], 0.12, 0.22)) - 40 # gated
  end

  it 'compresses the kit as a bus with glue:' do
    hits = -> { patch_notes([36, 0, 0.1, 1.0], [38, 0.25, 0.35, 1.0], [42, 0.5, 0.55, 0.5]) }
    plain = render_patch(MB::Sound.with_seed(3) { MB::Sound.dnb_drums(hits.()) }, 1)[0]
    glued = render_patch(MB::Sound.with_seed(3) { MB::Sound.dnb_drums(hits.(), glue: { makeup: 0 }) }, 1)[0]
    # (a slow attack: the hits' first ms mostly pass, their bodies come down)
    expect(rms_db(seconds(glued, 0.03, 0.2))).to be < rms_db(seconds(plain, 0.03, 0.2)) - 1
    expect(peak_db(seconds(glued, 0, 0.004))).to be_within(2).of(peak_db(seconds(plain, 0, 0.004)))
    gentle = render_patch(MB::Sound.with_seed(3) { MB::Sound.dnb_drums(hits.(), glue: { ratio: 1.2, makeup: 0 }) }, 1)[0]
    expect(rms_db(seconds(gentle, 0.03, 0.2))).to be > rms_db(seconds(glued, 0.03, 0.2))
  end

  it 'masters a mix to its true-peak ceiling' do
    mix = 110.hz.saw.at(0.5)
    out = render_patch(MB::Sound.dnb_master(mix, drive: 11, ceiling: -0.5), 0.5)[0]
    expect(out.abs.max).to be <= -0.5.db + 1e-3
    expect(out.abs.max).to be > -3.db
  end

  it 'renders every patch from a MIDI file with -p' do
    # The smoke spec renders the default patch as a real process
    %w[neuro drums].each do |patch|
      out_file = tmp_path("dnb_#{patch}.flac")
      out, status = fork_script('bin/synths/dnb.rb', '-q', '-p', patch, 'spec/test_data/c_major.mid', out_file)
      expect(status).to be_success, out
      expect(MB::Sound.read(out_file)[0].abs.max).to be > 0.01
    end
  end
end
