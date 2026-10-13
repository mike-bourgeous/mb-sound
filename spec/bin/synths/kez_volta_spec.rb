RSpec.describe('bin/synths/kez_volta.rb') do
  before(:all) { require File.expand_path('../../../bin/synths/kez_volta.rb', __dir__) }

  after { MB::Sound.rewind }

  let(:f1) { MB::Sound::F1.number }

  it 'plays a stereo Reese whose low end stays mono, highpassed off the sub' do
    l, r = render_patch(MB::Sound.kez_reese_voice(patch_notes([f1, 0, 1.5])), 1.5)
    expect(peak_db(l)).to be_between(-12, 6)
    expect(l).not_to eq(r) # spread
    expect(band_share(seconds(l, 0.2, 1.4), 0, 80)).to be < 0.01
    side = seconds(l - r, 0.2, 1.4)
    expect(band_share(side, 0, 120) * rms_db(side)).to be < 1 # little side energy below the highpass
  end

  it 'opens the Reese with its cutoff knob' do
    dark = render_patch(MB::Sound.kez_reese_voice(patch_notes([f1, 0, 1]), cutoff: 300), 1)[0]
    bright = render_patch(MB::Sound.kez_reese_voice(patch_notes([f1, 0, 1]), cutoff: 6000), 1)[0]
    expect(band_share(seconds(bright, 0.2, 0.9), 2000, 20000)).to be > band_share(seconds(dark, 0.2, 0.9), 2000, 20000) * 10
  end

  it 'plays a clean sub: the note\'s sine, nothing above the lowpass' do
    sub = render_patch(MB::Sound.kez_sub_voice(patch_notes([f1, 0, 1])), 1)[0]
    expect(peak_hz(seconds(sub, 0.2, 0.9), 20, 400)).to be_within(1.5).of(MB::Sound::F1.frequency)
    expect(band_share(seconds(sub, 0.2, 0.9), 300, 24000)).to be < 5e-3
  end

  it 'crushes the neuro bass more with more grit' do
    clean = render_patch(MB::Sound.kez_neuro_voice(patch_notes([f1, 0, 1]), grit: 0), 1)[0]
    gritty = render_patch(MB::Sound.kez_neuro_voice(patch_notes([f1, 0, 1]), grit: 1), 1)[0]
    expect(peak_db(clean)).to be_between(-20, 3)
    expect((gritty - clean).abs.max).to be > 0.05
  end

  it 'rings the pad, pluck, and boom out in stereo after their notes' do
    {
      pad: MB::Sound.kez_pad_voice(patch_notes([MB::Sound::F3.number, 0, 1], [MB::Sound::C4.number, 0, 1])),
      pluck: MB::Sound.kez_pluck_voice(patch_notes([MB::Sound::C5.number, 0, 0.1])),
      boom: MB::Sound.kez_boom_voice(patch_notes([f1, 0, 0.2])),
    }.each do |name, graph|
      l, r = render_patch(graph, 2.5)
      expect(peak_db(l)).to be > -40, name.to_s
      expect(rms_db(seconds(l, 1.5, 2.5))).to be > -110, name.to_s # the tail
      expect(l).not_to eq(r), name.to_s
    end
  end

  it 'plays the drums from GM notes, and the ghost kick is the drums\' kick' do
    kick = 36
    drums = render_patch(MB::Sound.kez_drums(patch_notes([kick, 0, 0.1, 1.0])), 0.5)[0]
    ghost = render_patch(MB::Sound.kez_ghost_kick(patch_notes([kick, 0, 0.1, 1.0])), 0.5)[0]
    expect(peak_db(drums)).to be > -12
    expect(peak_hz(seconds(ghost, 0.05, 0.4), 30, 200)).to be_within(6).of(54)
    expect(peak_hz(seconds(drums, 0.05, 0.4), 30, 200)).to be_within(6).of(54)
  end

  it 'masters a mix to its true-peak ceiling' do
    mix = 110.hz.saw.at(0.5)
    out = render_patch(MB::Sound.kez_master(mix, drive: 11, ceiling: -0.5), 0.5)[0]
    expect(out.abs.max).to be <= -0.5.db + 1e-3
    expect(out.abs.max).to be > -3.db
  end

  it 'renders every patch from a MIDI file with -p' do
    # The smoke spec renders the default patch as a real process
    %w[neuro drums].each do |patch|
      out_file = tmp_path("kez_#{patch}.flac")
      out, status = fork_script('bin/synths/kez_volta.rb', '-q', '-p', patch, 'spec/test_data/c_major.mid', out_file)
      expect(status).to be_success, out
      expect(MB::Sound.read(out_file)[0].abs.max).to be > 0.01
    end
  end
end
