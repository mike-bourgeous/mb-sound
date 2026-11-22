# The master chain kept as an effect rack, and effect racks on the master
# and on tracks (master-rack-1; the maintainer, 2026-11-22: "Rack, and
# master takes racks"): `master.save_rack :glue` writes a rack document
# from the chain's recipes, `master :glue` / `master rack(:glue)` / `master
# arack { }` play racks, `fx :drums, :glue` puts one on a track, and the
# names a rack can't take.
RSpec.describe(MB::Sound::Session::MasterRack, :aggregate_failures) do
  let(:s) { MB::Sound }
  let(:mr) { described_class }

  # A master chain with a knob it defines, a knob it only reads, a
  # per-channel part, and a mastering preset at its end (a block made with
  # MB::Sound as self, as console blocks are)
  CHAIN = MB::Sound.instance_eval {
    proc { |mix| mix.hp1(30).lp4(knob(:cut, 2000, range: 200..8000, curve: :exp)).softclip(0.3, 0.9) * knob(:turned) }
  }

  around(:each) do |ex|
    old = ENV.to_h.slice('MB_SOUND_PRESETS', 'XDG_DATA_HOME')
    ENV['MB_SOUND_PRESETS'] = tmp_path('presets')
    ENV['XDG_DATA_HOME'] = tmp_path('xdg')
    MB::Sound::Library.reload!
    ex.run
  ensure
    ENV.delete('MB_SOUND_PRESETS')
    ENV.delete('XDG_DATA_HOME')
    old.each { |k, v| ENV[k] = v }
    MB::Sound::Library.reload!
  end

  before { @sessions = [] }
  after {
    @sessions.each(&:close)
    MB::Sound.rewind
  }

  def session_for(size = 800, channels: 2)
    out = MB::Sound::Sampler::CaptureOutput.new(channels: channels, buffer_size: size)
    MB::Sound::Session.new(output: out, channels: channels, buffer_size: size, master_gain: 1, realtime: false, raise_errors: true,
                            transport: MB::Sound::Sequence::Transport.new(bpm: 120)).tap { @sessions << _1 }
  end

  def within(session, &block)
    MB::Sound::Session.with_context(session: session, &block)
  end

  # Renders +frames+ frames (whole buffers) and returns the channels.
  def render(session, frames)
    (frames.to_f / session.buffer_size).ceil.times { session.process_buffer }
    session.output.captured.map { |c| Numo::SFloat.cast(c)[0...frames] }
  end

  def source
    MB::Sound.with_seed(5) { [220.hz.saw.at(0.5), (330.hz.triangle * 0.4 + MB::Sound.noise.at(0.05))] }
  end

  # A session playing source through the master chain of +setup+ (run in
  # its context first).
  def play(size, &setup)
    session = session_for(size)
    within(session) {
      setup.call(session)
      session.add(source, name: :src)
    }
    session
  end

  describe 'master.save_rack' do
    it 'saves the chain as a rack document that plays the same in a fresh session, at 800 and 367 frames' do
      rack = nil
      originals = [800, 367].to_h { |size|
        a = play(size) { |ses|
          s.knob(:turned, 0.5, range: 0..2)
          ses.knobs[:turned].set(0.8, frame: 0, smooth: 0)
          s.master(:club, lufs: -9, &CHAIN)
        }
        out = render(a, 9600)
        rack = within(a) { expect { rack = s.master.save_rack(:glue) }.to output(/Saved glue/).to_stdout; rack } if size == 800
        [size, out]
      }

      expect(rack).to be_a(MB::Sound::Rack)
      expect(rack.name).to eq(:glue)
      text = File.read(File.join(tmp_path('presets'), 'glue.mbg.rb'))
      expect(text).to include('rack: :arack')
      expect(text).to include("knob :turned, (0..2).at(0.8)\n") # (its current value)
      expect(text).to include("knob :cut, (200..8000).at(2000), curve: :exp\n")
      expect(text).to end_with("\n(sig.hp1(30).lp4(cut).softclip(0.3, 0.9) * turned).master(:club, lufs: -9)\n")

      [800, 367].each do |size|
        b = play(size) { s.master(:glue) }
        expect(b.master_info).to start_with('master: rack(:glue)')
        expect(b.knobs.keys).to include(:"glue/cut", :"glue/turned")
        got = render(b, 9600)
        expect(got[0].abs.max).to be > 0.05
        expect(got).to eq(originals[size]), "#{size}-frame buffers"
      end
    end

    it 'prints per-channel blocks, stereo methods, and a chain that is already a rack' do
      a = session_for
      within(a) {
        s.master { |l, r| [l, r.delay(0.01)] }
        expect(mr.text(a, :haas)).to end_with("\nchannels(sig[0], sig[1].delay(0.01))\n")
        s.master { |mix| mix.mono.softclip }
        expect(mr.text(a, :m)).to end_with("\nsig.mono.softclip\n")
        s.master { |mix| mix.width(1.3) }
        expect(mr.text(a, :w)).to end_with("\nsig.width(1.3)\n")
        s.master(:quiet)
        expect(mr.text(a, :q)).to end_with("\nsig.master(:quiet)\n")
        s.arack(:inner) { |sig| sig.softclip(0.2, 0.8) }
        s.master(:inner)
        text = mr.text(a, :outer)
        expect(text).to include('arack(:inner) { |sig|').and end_with("\nsig.then(&rack(:inner))\n")
      }
    end

    it 'loads per-channel chains back bit for bit' do
      blocks = [proc { |l, r| [l, r.delay(0.01)] }, proc { |mix| mix.width(1.4).softclip }, proc { |mix| mix.mono.softclip(0.2, 0.7) }]
      blocks.each_with_index do |blk, i|
        a = play(367) { s.master(&blk) }
        loaded = within(a) { mr.rack(a, :"ch#{i}") }
        ref = render(a, 4000)
        b = play(367) { s.master(loaded) }
        expect(render(b, 4000)).to eq(ref), "block #{i}"
      end
    end

    it 'refuses names a rack cannot take, and replaces with save_rack!' do
      a = session_for
      within(a) {
        s.master { |mix| mix.softclip }
        expect { s.master.save_rack(:club) }.to raise_error(ArgumentError, /master :club plays the mastering preset.*:club_glue/)
        expect { s.master.save_rack(:show) }.to raise_error(ArgumentError, /shows the master chain/)
        s.track(:drums, s.seq(s::C4).n4.loop) { |c| c.tone.saw * c.env }
        expect { s.master.save_rack(:drums) }.to raise_error(ArgumentError, /:drums names a track/)
        expect { s.master.save_rack('glue') }.to raise_error(ArgumentError, /Symbols/)

        expect { s.master.save_rack(:glue) }.to output(/Saved glue/).to_stdout
        expect { s.master.save_rack(:glue) }.to raise_error(ArgumentError, /rack :glue is defined in this session; master.save_rack! :glue replaces it/)
        s.master { |mix| mix.softclip(0.1, 0.5) }
        r = nil
        expect { r = s.master.save_rack!(:glue) }.to output(/Saved glue .*\(replaced\)/).to_stdout
        expect(a.racks[:glue]).to equal(r)
        expect(File.read(File.join(tmp_path('presets'), 'glue.mbg.rb'))).to end_with("\nsig.softclip(0.1, 0.5)\n")

        s.master(nil)
        expect { s.master.save_rack(:none) }.to raise_error(ArgumentError, /master is bypass: nothing to save/)
      }
    end

    it 'saves what master showed, even after the chain changed' do
      a = session_for
      within(a) {
        s.master { |mix| mix.softclip(0.4, 0.9) }
        shown = s.master
        expect(shown).to eq(a.master_info)
        expect(shown).to be_a(String)
        s.master { |mix| mix.lp4(900) }
        expect { shown.save_rack(:first) }.to output(/Saved first/).to_stdout
        expect(File.read(File.join(tmp_path('presets'), 'first.mbg.rb'))).to end_with("\nsig.softclip(0.4, 0.9)\n")
      }
    end
  end

  describe 'master with racks' do
    it 'takes a rack, its name, an anonymous rack, or a library effect; a mastering preset name plays the preset' do
      a = session_for
      within(a) {
        s.arack(:soft) { |sig| sig.softclip(0.3, 0.9) }
        shown = ->(cmd) { cmd.(); a.process_buffer; a.master_info }
        expect(shown.(-> { s.master(:soft) })).to eq('master: rack(:soft)')
        expect(shown.(-> { s.master(s.rack(:soft)) })).to eq('master: rack(:soft)')
        expect(shown.(-> { s.master(s.arack { |sig| sig.lp4(1200) }) })).to eq('master: an arack')
        expect(shown.(-> { s.master(:hall) })).to eq('master: L.fx.hall')
        expect(shown.(-> { s.master(s::L.fx.reverb.plate) })).to eq('master: L.fx.reverb.plate')
        expect { s.master(:plate) }.to raise_error(ArgumentError, /2 effects are named plate \(L.fx.reverb.plate, L.fx.resonator.plate\): give one, e.g. master L.fx.reverb.plate/)

        s.arack(:club) { |sig| sig * 0.5 }
        expect(shown.(-> { s.master(:club) })).to start_with('master: :club')
        expect(shown.(-> { s.master(s.rack(:club)) })).to eq('master: rack(:club)')
      }
    end

    it 'answers wrong guesses with the spelling that works' do
      a = session_for
      within(a) {
        s.arack(:glue) { |sig| sig.softclip }
        expect { s.master(:clubb) }.to raise_error(ArgumentError, /no mastering preset, rack, or effect is named :clubb.*:club/m)
        expect { s.master(:glu) }.to raise_error(ArgumentError, /Did you mean\?  :glue/)
        expect { s.master(:glue, lufs: -9) }.to raise_error(ArgumentError, /master rack\(:glue\) takes no options \(lufs: go with a mastering preset/)
        expect { s.master(:glue) { |mix| mix } }.to raise_error(ArgumentError, /takes no block/)
        s.mrack(:arp) { it.transpose(12) }
        expect { s.master(:arp) }.to raise_error(ArgumentError, /master plays effect racks.*rack :arp is a note_fx/)
        expect { s.master(s::L.inst.first) }.to raise_error(ArgumentError, /master plays effects; L\.inst\.\w+ is an instrument/)
        expect(a.master_info).to start_with('bypass')
      }
    end

    it "joins the rack's knobs to the session, and keeps them through panic and undo" do
      a = play(800) { s.arack(:wet) { |sig| sig * s.knob(:amount, 0.5) }; s.master(:wet) }
      render(a, 1600)
      expect(a.knobs.keys).to include(:"wet/amount")
      within(a) { s.turn(:"wet/amount", 0.25, smooth: 0) }
      render(a, 1600)
      expect(a.knobs[:"wet/amount"].value).to eq(0.25)
      within(a) { a.reset_master }
      render(a, 1600)
      expect(a.knobs[:"wet/amount"].value).to eq(0.25)
      within(a) { s.master { |mix| mix } }
      render(a, 1600)
      within(a) { s.undo }
      render(a, 1600)
      expect(a.master_info).to start_with('master: rack(:wet)')
    end
  end

  describe 'fx with racks' do
    let(:riff) { s.seq(s::A3, s::C4, s::E4).n8.loop }

    it 'plays a saved master chain on a track by name, like the rack in a patch block' do
      a = session_for
      within(a) {
        s.knob(:turned, 0.7)
        s.master(&CHAIN)
        expect { s.master.save_rack(:glue) }.to output(/Saved glue/).to_stdout
        s.master(nil)
        MB::Sound.seed(1)
        s.track(:keys, :funk_keys, fx: :glue)
        s.bg(:keys, riff)
      }
      out = render(a, 24000)
      expect(out[0].abs.max).to be > 0.01
      expect(a.arrangement.tracks[:keys].fx.map(&:name)).to eq([:glue])
      expect(a.knobs.keys).to include(:"glue/cut", :"glue/turned")

      b = session_for
      within(b) {
        MB::Sound.seed(1)
        s.track(:keys) { |c| s.preset(:funk_keys, midi: c).then(&s.preset(:glue)) }
        s.bg(:keys, riff)
      }
      expect(render(b, 24000)).to eq(out)
    end

    it 'labels racks, saves named ones by name, and refuses racks that are not effects' do
      a = session_for
      within(a) {
        s.arack(:soft) { |sig| sig.softclip }
        s.track(:keys, :funk_keys, fx: s.rack(:soft))
        tr = a.arrangement.tracks[:keys]
        expect(MB::Sound::Arrangement::Fx.label(tr.fx)).to eq('rack(:soft)')
        expect(MB::Sound::Arrangement::Fx.set_value(tr.fx)).to eq(:soft)
        s.fx(:keys, [s.arack { |sig| sig * 0.5 }, :soft])
        expect(MB::Sound::Arrangement::Fx.label(tr.fx)).to eq('an arack + L.fx.soft')
        expect(MB::Sound::Arrangement::Fx.set_value(tr.fx)).to be_nil
        s.mrack(:up) { it.transpose(12) }
        expect { s.fx(:keys, s.rack(:up)) }.to raise_error(ArgumentError, /rack :up is a note_fx rack .*not an effect rack/)
      }
    end
  end
end
