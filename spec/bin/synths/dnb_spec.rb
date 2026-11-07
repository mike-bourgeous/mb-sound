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

  describe 'the Reese preset\'s LFO params and moving params (reese-params-1)' do
    # High-band shares of the left channel in 0.2 s windows from 0.2 to 1.8 s.
    def shares(x) = (0...8).map { |i| band_share(seconds(x, 0.2 + i * 0.2, 0.4 + i * 0.2), 2000, 20000) }

    def reese(length = 2, **params) = render_patch(MB::Sound.preset(:dnb_reese, midi: patch_notes([f1, 0, length]), **params), length)[0]

    it 'turns the cutoff LFO off with lfo_depth: 0 and sets its cycle in bars with lfo_bars:' do
      # (measured: 10x over a cycle a second at 120 BPM; 1.65x from the
      # unison's beating alone)
      wobble = shares(reese(lfo_bars: 0.5))
      expect(wobble.max / wobble.min).to be > 5

      steady = reese(lfo_depth: 0, lfo_bars: 0.5)
      expect(shares(steady).max / shares(steady).min).to be < 2
      expect(reese(lfo_depth: 0, lfo_bars: 7)).to eq(steady) # (no LFO, no rate)
      expect(reese(lfo_depth: 0.8, lfo_bars: 2)).to eq(reese) # the defaults
    end

    it 'drives a param over time with a node: a tween on the cutoff, saved and loaded' do
      g = MB::Sound.preset(:dnb_reese, midi: patch_notes([f1, 0, 2]), lfo_depth: 0, cutoff: MB::Sound.tween([300.hz, 3000.hz], 1.bar, loop: false))
      text = MB::Sound::GraphIO.dump(g)
      expect(text).to include('tween([300.hz, 3000.hz], 1.bar, loop: false)')
      loaded = MB::Sound::GraphIO.load(text, inputs: { midi: patch_notes([f1, 0, 2]) })

      out = render_patch(g, 2)[0]
      expect(render_patch(loaded, 2)[0]).to eq(out)
      expect(band_share(seconds(out, 1.5, 1.9), 2000, 20000)).to be > band_share(seconds(out, 0.1, 0.4), 2000, 20000) * 10
    end

    it 'saves lfo_bars as a live param, so both LFO knobs turn on a track: no rebuild, the same samples at any buffer size' do
      text = File.read(File.join(MB::Sound::GraphIO.library_presets_dir, 'dnb_reese.mbg.rb'))
      expect(text).to include('v.lfo(lfo_bars.bars, shape: :sine, depth: lfo_depth)')

      play = lambda do |size, turns|
        session = MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120),
                                         channels: 2, buffer_size: size, realtime: false, raise_errors: true)
        MB::Sound::Session.with_context(session: session) {
          MB::Sound.instance_eval {
            track :reese, :dnb_reese
            bg :reese, seq(MB::Sound::F1).n1.loop
          }
        }
        out = [session.process_buffer.map(&:dup)]
        graph = session.ui_graphs[:reese]
        expect(session.knobs.keys).to include(:"reese/lfo_bars", :"reese/lfo_depth")
        expect(session.arrangement.build_knob?(:"reese/lfo_bars")).to eq(false)
        MB::Sound::Session.with_context(session: session) { MB::Sound.turn(:"reese/lfo_bars", 0.5, at: MB::Sound.bar(2)); MB::Sound.turn(:"reese/lfo_depth", 1.0, at: MB::Sound.bar(2)) } if turns
        out << session.process_buffer.map(&:dup) while out.sum { |b| b[0].length } < 3.5 * 48000
        expect(session.ui_graphs[:reese]).to equal(graph) # (turned, not rebuilt)
        Numo::SFloat.cast(SpecBuffers.join(out.map(&:first)))[0...(3.5 * 48000).round]
      ensure
        session&.close
        MB::Sound.rewind
      end

      turned = play.(800, true)
      plain = play.(800, false)
      expect(turned[0...90_000]).to eq(plain[0...90_000]) # (the turns land on bar 2: 2 s at 120 BPM)
      expect((turned[100_000..] - plain[100_000..]).abs.max).to be > 0.01
      expect(play.(367, true)).to eq(turned)
    end
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
    plain = render_patch(MB::Sound.with_seed(4) { MB::Sound.dnb_neuro_voice(patch_notes([f1, 0, 1]), sync: 0, noise: 0) }, 1)[0]
    top = band_share(seconds(plain, 0.1, 0.9), 4000, 24000)
    [:sync, :fold, :noise].each do |k|
      bright = render_patch(MB::Sound.with_seed(4) { MB::Sound.dnb_neuro_voice(patch_notes([f1, 0, 1]), sync: 0, noise: 0, k => 1) }, 1)[0]
      expect(band_share(seconds(bright, 0.1, 0.9), 4000, 24000)).to be > top * 1.5, k.to_s
      expect(peak_db(bright)).to be_between(-20, 6), k.to_s
    end

    # The default top end: noise 0.5 and a little sync (patches-4)
    default = render_patch(MB::Sound.with_seed(4) { MB::Sound.dnb_neuro_voice(patch_notes([f1, 0, 1])) }, 1)[0]
    explicit = render_patch(MB::Sound.with_seed(4) { MB::Sound.dnb_neuro_voice(patch_notes([f1, 0, 1]), sync: 0.2, noise: 0.5) }, 1)[0]
    expect(default).to eq(explicit)
    expect(band_share(seconds(default, 0.1, 0.9), 4000, 24000)).to be > top * 1.5
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

  it 'closes the room within an eighth note at 174 BPM, and leaves quiet (ghost) snares dry' do
    snare = render_patch(MB::Sound.with_seed(3) { MB::Sound.dnb_drums(patch_notes([38, 0, 0.1, 1.0]), parallel: 0) }, 1)
    roomy = render_patch(MB::Sound.with_seed(3) { MB::Sound.dnb_drums(patch_notes([38, 0, 0.1, 1.0]), parallel: 0, room: true) }, 1)
    long = render_patch(MB::Sound.with_seed(3) { MB::Sound.dnb_drums(patch_notes([38, 0, 0.1, 1.0]), parallel: 0, room: true, room_gate: 0.18, room_threshold: -30.db, room_decay: 2.5) }, 1)
    wet = ->(x) { x[0][0...snare[0].length] - snare[0] }
    splash = rms_db(seconds(wet.(roomy), 0.03, 0.12))
    expect(rms_db(seconds(wet.(roomy), 0.25, 0.45))).to be < splash - 40 # closed an eighth (0.17 s) after the hit
    expect(rms_db(seconds(wet.(long), 0.25, 0.45))).to be > splash - 20 # (patches-3's room was still open)

    # An audible decay while the gate is open (patches-5): the splash falls 10+ dB from its peak (40-60 ms) by
    # 130-150 ms, still sounding; patches-4's bigger, longer room held within a few dB until the gate cut it
    p4 = render_patch(MB::Sound.with_seed(3) { MB::Sound.dnb_drums(patch_notes([38, 0, 0.1, 1.0]), parallel: 0, room: true, room_size: 0.7, room_decay: 1.0) }, 1)
    fall = ->(x) { rms_db(seconds(wet.(x), 0.04, 0.06)) - rms_db(seconds(wet.(x), 0.13, 0.15)) }
    expect(fall.(roomy)).to be_between(10, 25)
    expect(fall.(p4)).to be < 7

    ghost = render_patch(MB::Sound.with_seed(3) { MB::Sound.dnb_drums(patch_notes([38, 0, 0.1, 0.2]), parallel: 0) }, 1)
    ghost_room = render_patch(MB::Sound.with_seed(3) { MB::Sound.dnb_drums(patch_notes([38, 0, 0.1, 0.2]), parallel: 0, room: true) }, 1)
    expect(rms_db(seconds(ghost_room[0][0...ghost[0].length] - ghost[0], 0.03, 0.12))).to be < rms_db(seconds(ghost[0], 0.03, 0.12)) - 20
  end

  it 'compresses the kit as a bus with glue:' do
    hits = -> { patch_notes([36, 0, 0.1, 1.0], [38, 0.25, 0.35, 1.0], [42, 0.5, 0.55, 0.5]) }
    plain = render_patch(MB::Sound.with_seed(3) { MB::Sound.dnb_drums(hits.()) }, 1)[0]
    glued = render_patch(MB::Sound.with_seed(3) { MB::Sound.dnb_drums(hits.(), glue: { makeup: 0.db }) }, 1)[0]
    # (a slow attack: the hits' first ms mostly pass, their bodies come down)
    expect(rms_db(seconds(glued, 0.03, 0.2))).to be < rms_db(seconds(plain, 0.03, 0.2)) - 1
    expect(peak_db(seconds(glued, 0, 0.004))).to be_within(2).of(peak_db(seconds(plain, 0, 0.004)))
    gentle = render_patch(MB::Sound.with_seed(3) { MB::Sound.dnb_drums(hits.(), glue: { ratio: 1.2, makeup: 0.db }) }, 1)[0]
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
