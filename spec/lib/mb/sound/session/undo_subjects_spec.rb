# Undo subjects are registered (session-core-1, arch-session section 3):
# Undo dispatches snapshots and restores through Undo.subject's table, not
# through super chains across the Session's modules, so include order
# doesn't matter.  This guards the table: every subject type is registered
# with methods the Session has, and no other module overrides the
# dispatching methods again.
RSpec.describe(MB::Sound::Session::Undo, 'subjects', :aggregate_failures) do
  let(:session_class) { MB::Sound::Session }
  let(:undo) { described_class }

  it 'keeps the dispatching methods in Undo alone' do
    %i[snapshot_subject undo_snapshot restore_change].each do |m|
      expect(session_class.instance_method(m).owner).to eq(undo)
      others = session_class.ancestors.select { |a| a != undo && (a.instance_methods(false) + a.private_instance_methods(false)).include?(m) }
      expect(others).to eq([]), "#{m} is defined again in #{others.join(', ')}: register an undo subject instead (Undo.subject)"
    end
  end

  it 'registers every *Subject type in the Session namespace, with methods the Session has' do
    defined = (session_class.constants.map { |c| session_class.const_get(c) }.grep(Module) + [session_class]).flat_map { |m|
      m.constants.filter_map { |c| (v = m.const_get(c)).is_a?(Class) && v < Data && c.to_s.end_with?('Subject') ? v : nil }
    }.uniq
    expect(defined).not_to be_empty
    expect(undo.subject_types).to match_array(defined)

    methods = session_class.instance_methods + session_class.private_instance_methods
    undo.subject_types.each do |type|
      kind = undo.subject_kind(type.members.empty? ? type.new : type.new(*type.members.map { :x }))
      expect(methods).to include(kind.snapshot, kind.restore)
    end
    undo.claims.each { |claim| expect(methods).to include(claim.name) }
    expect(undo.claims.map(&:order)).to eq(undo.claims.map(&:order).sort)
  end

  it 'maps the subject Symbols, and anything else to a player name' do
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new, realtime: false)
    change = ->(kind, subject, data = {}) { Struct.new(:kind, :subject, :entry).new(kind, subject, Struct.new(:data).new(data)) }
    sub = ->(c) { s.send(:snapshot_subject, c) }
    expect(sub.(change.(:master, :master))).to eq(MB::Sound::Session::Master::MasterSubject.new)
    expect(sub.(change.(:mute, :strip))).to eq(MB::Sound::Session::Strip::StripSubject.new)
    expect(sub.(change.(:seek, :anything))).to eq(MB::Sound::Session::Seeks::TimelineSubject.new)
    expect(sub.(change.(:restore, :timeline))).to eq(MB::Sound::Session::Seeks::TimelineSubject.new)
    expect(sub.(change.(:tempo, :tempo))).to eq(MB::Sound::Session::TempoChanges::TempoSubject.new)
    expect(sub.(change.(:key, :key))).to eq(MB::Sound::Session::KeyChanges::KeySubject.new)
    expect(sub.(change.(:turn, :cut))).to eq(MB::Sound::Session::Knobs::KnobSubject.new(:cut))
    expect(sub.(change.(:restore, :cut, { knob: true }))).to eq(MB::Sound::Session::Knobs::KnobSubject.new(:cut))
    expect(sub.(change.(:bus, :verb))).to eq(MB::Sound::Session::Buses::BusSubject.new(:verb))
    expect(sub.(change.(:send, :keys, { bus: :verb }))).to eq(MB::Sound::Session::Buses::SendSubject.new(:keys, :verb))
    expect(sub.(change.(:cue, :acid))).to eq(MB::Sound::Session::Cue::CueSubject.new(:acid))
    expect(sub.(change.(:restore, :acid, { cue: :pfl }))).to eq(MB::Sound::Session::Cue::CueSubject.new(:acid))
    expect(sub.(change.(:bg, :bass))).to eq(undo::PlayerSubject.new(:bass))
    expect(sub.(change.(:bg, 'bass'))).to eq(undo::PlayerSubject.new('bass'))
  ensure
    s&.close
  end

  it 'refuses a subject type registered twice' do
    expect { undo.subject(undo::PlayerSubject, snapshot: :x, restore: :y) }.to raise_error(ArgumentError, /already/)
  end
end
