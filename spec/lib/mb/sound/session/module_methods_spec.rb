# Session is one class made of many modules (Changes, Strip, Holds, Cue,
# ...).  A method two of them define is a silent override: the later
# include wins, whatever either module meant (ux-notes-2: Holds#held?(name)
# replaced Changes#held?(change), a change waiting for its warm-up, so
# warmed changes would have landed before their graphs were ready; no spec
# failed).  Modules that extend another's method register it (Strip.rule,
# Undo.claim) instead of overriding it.
RSpec.describe('Session modules', :aggregate_failures) do
  it 'define each method name once (Session and its modules)' do
    s = MB::Sound::Session
    mods = s.ancestors.take_while { |m| m != Object }.select { |m| m == s || m.name&.start_with?('MB::Sound::Session::') }
    expect(mods.length).to be > 20
    defs = Hash.new { |h, k| h[k] = [] }
    mods.each do |m|
      (m.instance_methods(false) + m.private_instance_methods(false) + m.protected_instance_methods(false)).each { |n| defs[n] << m.name }
    end
    twice = defs.select { |_, where| where.length > 1 }.map { |n, where| "#{n} (#{where.join(', ')})" }
    expect(twice).to eq([]), "defined in more than one of Session's modules: #{twice.join('; ')}"
  end
end
