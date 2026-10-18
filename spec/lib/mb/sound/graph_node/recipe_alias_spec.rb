# Aliases of recorded DSL methods print and save under their official name
# (Recipe.official_name, omnibus9), unless Recipe::KEEP_SPELLING says why not.
RSpec.describe('recipe aliases', :aggregate_failures) do
  recipe = MB::Sound::GraphNode::Recipe

  # [target, alias, official] for every recorded method that is an alias
  # (its definition, at the end of the super chain, has another name)
  aliases = recipe.instance_variable_get(:@wrapped).flat_map { |key, names|
    target = key == :sound ? MB::Sound.singleton_class : key
    next [] unless target.is_a?(Module)
    names.filter_map { |n|
      m = target.instance_method(n) rescue next
      m = m.super_method while m.super_method
      [target, n, m.original_name] if m.original_name != n
    }
  }

  it 'finds the aliases (fb, saw, for, ...)' do
    found = aliases.map { |_, n, o| [n, o] }
    expect(found).to include([:fb, :feedback], [:saw, :ramp], [:for, :until], [:skew, :pwm], [:vowel, :formant], [:crush_rate, :decimate])
  end

  it 'records every alias under an official name that is itself a recorded public method, or keeps its spelling with a reason' do
    bad = aliases.reject { |target, n, official|
      next true if recipe::KEEP_SPELLING.key?(n)
      recipe.official_name(target, n) == official && target.public_method_defined?(official)
    }
    expect(bad.map { |t, n, o| "#{t}##{n} -> #{o}" }).to eq([])
  end

  it 'keeps no stale KEEP_SPELLING entries' do
    expect(recipe::KEEP_SPELLING.keys - aliases.map { |_, n, _| n }).to eq([])
  end

  it 'prints and saves the official names, and old documents with aliases still load' do
    g = 110.hz.saw.skew(0.3).at(0.2).fb { |f, i| i + f.delay(0.01) * 0.5 }.for(0.02)
    code = g.to_ruby
    expect(code).to include('.ramp', '.pwm(0.3)', '.feedback {', '.until(0.02)')
    expect(code).not_to match(/\.saw|\.skew|\.fb |\.for\(/)

    old = MB::Sound::GraphIO.load("110.hz.saw.skew(0.3).at(0.2).fb { |f, i| i + f.delay(0.01) * 0.5 }.for(0.02)")
    expect(MB::Sound::GraphIO.dump(old)).to include('.ramp.pwm(0.3)', '.until(0.02)')
  end
end
