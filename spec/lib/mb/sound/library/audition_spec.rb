# `audition entry` (ui-scaffold-1, the library picker's `a` key): plays an
# entry for a listen as player :audition, on CUE when the output has it,
# else on MAIN under the set; every kind with a sound plays something
# (effects and mastering chains on the Bench arp, envelopes shaping a
# triangle and noise).
RSpec.describe(MB::Sound::Library::Audition, :aggregate_failures) do
  before { @sessions = [] }
  after {
    @sessions.each(&:close)
    MB::Sound.rewind
  }

  def session
    s = MB::Sound::Session.new(output: MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: 800), realtime: false)
    @sessions << s
    s
  end

  it 'plays something for every entry kind with a sound, and says what the others are' do
    idx = MB::Sound::Library.index
    groups = idx.entries.reject { |e| %i[set clip].include?(e.kind) }.group_by { |e| [e.kind, e.family] }
    played = groups.filter_map do |(kind, family), entries|
      e = entries.first
      begin
        g = MB::Sound::Playable.graph(described_class.playable(e))
      rescue MB::Sound::Playable::Unplayable => err
        expect(kind).to eq(:sample_edit), "#{e.head_path}: #{err.message}"
        next
      end
      peak = 60.times.map { g.nodes.map { |n| (b = n.sample(800)) ? b.abs.max : 0 }.max }.max
      expect(peak).to be > 0.001, "#{e.head_path} (#{kind} #{family}) is silent"
      [kind, family]
    end
    expect(played.map(&:first).uniq).to include(:instrument, :kit, :effect, :master, :envelope)
  end

  it 'plays on MAIN at -6 dB without CUE, on CUE with it, and stops' do
    s = session
    MB::Sound::Session.with_context(session: s) do
      r = MB::Sound.audition(MB::Sound::L.inst.dnb.dnb_sub)
      expect(r.where).to eq(:main)
      expect(r.to_s).to eq('audition L.inst.dnb_sub: playing a demo phrase, on MAIN at -6 dB (no CUE on this output); audition off stops it')
      s.process_buffer
      expect(s.players.keys).to eq([:audition])
      expect(MB::Sound.audition(:off).map(&:to_s)).to all(start_with('stop :audition'))
      4.times { s.process_buffer }
      expect(s.players.keys).to be_empty
      expect(MB::Sound.audition(:off)).to eq('audition: nothing playing')

      s.cue_output = :phones
      expect(s.cue_heard?).to eq(true)
      r = MB::Sound.audition(MB::Sound::L.fx.reverb.hall)
      expect(r.where).to eq(:cue)
      expect(r.to_s).to include('on the A7 arp (its Bench material), on CUE')
      s.process_buffer
      expect(s.players.keys).to eq([:"audition/cue"])
      MB::Sound.audition(:off)
      4.times { s.process_buffer }
      expect(s.players.keys).to be_empty
    end
  end

  it 'takes names, and explains ambiguous and unknown ones' do
    expect(described_class.entry_for(:tr909).head_path).to eq('L.kit.tr909')
    expect { described_class.entry_for(:dnb) }.to raise_error(ArgumentError, /audition :dnb: \d+ entries are named or tagged dnb \(L\./)
    expect { described_class.entry_for(:hal) }.to raise_error(ArgumentError, /audition :hal: nothing under L.all is :hal.*hall/m)
    expect { described_class.entry_for('hall') }.to raise_error(ArgumentError, /takes a library entry/)
  end
end
