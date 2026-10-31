# The strip is a registry (session-2, the maintainer's "Registry",
# 2026-10-31): who is audible and whose mute/solo levels ramp are
# registered rules and steps (Strip.rule, Strip.step), like Undo.claim,
# not a super chain across Strip, Buses, and Cue that worked in one
# include order only.  This guards the registry: the dispatching methods
# live in Strip alone, and every rule and step method is registered and
# exists.
RSpec.describe(MB::Sound::Session::Strip, 'registry', :aggregate_failures) do
  let(:session_class) { MB::Sound::Session }
  let(:strip) { described_class }

  def all_methods(mod)
    mod.instance_methods(false) + mod.private_instance_methods(false)
  end

  it 'keeps the dispatching methods in Strip alone' do
    %i[audible_unlocked? apply_strip].each do |m|
      expect(session_class.instance_method(m).owner).to eq(strip)
      others = session_class.ancestors.select { |a| a != strip && all_methods(a).include?(m) }
      expect(others).to eq([]), "#{m} is defined again in #{others.join(', ')}: register a strip rule or step instead (Strip.rule, Strip.step)"
    end
  end

  it 'registers every *_strip_rule and *_strip_step method, in order, and each exists' do
    defined = session_class.ancestors.flat_map { |a| all_methods(a) }.uniq
    rules = defined.grep(/_strip_rule\z/)
    steps = defined.grep(/_strip_step\z/)
    expect(rules).not_to be_empty
    expect(strip.rules.map(&:name)).to match_array(rules), 'a *_strip_rule method is not registered with Strip.rule (or a registered one is gone)'
    expect(strip.steps.map(&:name)).to match_array(steps), 'a *_strip_step method is not registered with Strip.step (or a registered one is gone)'
    expect(strip.rules.map(&:order)).to eq(strip.rules.map(&:order).sort)
    expect(strip.steps.map(&:order)).to eq(strip.steps.map(&:order).sort)
    expect(strip.rules.map(&:order).uniq.length).to eq(strip.rules.length), 'two strip rules share an order'
    expect(strip.rules.map(&:name)).to eq(%i[cue_strip_rule mute_strip_rule solo_strip_rule bus_solo_strip_rule])
    expect(strip.steps.map(&:name)).to eq(%i[player_strip_step bus_strip_step])
  end

  it 'refuses a rule or step registered twice' do
    expect { strip.rule(:mute_strip_rule, order: 99) }.to raise_error(ArgumentError, /already/)
    expect { strip.step(:bus_strip_step, order: 99) }.to raise_error(ArgumentError, /already/)
  end

  it 'answers as the rules say: cue players, mutes, monitors, solos, solo in place through buses' do
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new, realtime: false)
    heard = ->(n) { s.instance_eval { @render_lock.synchronize { audible_unlocked?(n) } } }
    MB::Sound::Session.with_context(session: s) do
      s.bus(:verb, on: :now) { |sig| sig }
      s.route(:keys, send: { verb: 0.5 })
      expect(%i[keys bass verb lead/live keys/cue].map(&heard)).to all(eq(true))
      s.mute(:lead)
      expect(heard.(:"lead/live")).to eq(false)
      s.solo(:keys)
      expect(%i[keys verb keys/cue].map(&heard)).to eq([true, true, true]) # (the bus it feeds; cue players ignore solos)
      expect(%i[bass lead/live].map(&heard)).to eq([false, false])
      s.mute(:keys)
      expect(%i[keys keys/cue].map(&heard)).to eq([false, false])
    end
  ensure
    s&.close
  end
end
