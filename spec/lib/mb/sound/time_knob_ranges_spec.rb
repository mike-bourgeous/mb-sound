# Knob ranges for times (tuner-fixes-2; the maintainer, 2026-11-09:
# "sliders on envelope times maxed out at 20ms").  Every time setting the
# fit patcher or the inspector's bind can make a knob for (a DSL method's
# parameter named as a time: attack, decay, release, time, sweep_time, ...;
# Param::TIME_NAME) gets a knob reaching musical lengths: from 0.1 ms or
# less up to 10 s or more, on an :exp curve.
RSpec.describe('time knob ranges', :aggregate_failures) do
  # [[method label, parameter name, kind (:req/:opt/:key), index], ...] of
  # every time-named parameter of the methods a fit's code calls.
  def time_parameters
    MB::Sound::FitPatch.call_sources.flat_map { |mod|
      mod.public_instance_methods.flat_map { |n|
        m = mod.instance_method(n)
        m = m.super_method while m.super_method && m.parameters.map(&:first) == %i[rest keyrest block]
        pos = m.parameters.select { |t, _| t == :req || t == :opt }
        m.parameters.filter_map { |t, pn|
          next unless pn && pn.to_s.match?(MB::Sound::Param::TIME_NAME) && %i[req opt key].include?(t)
          ["#{mod.name.split('::').last}##{n}", pn, t, pos.index { |_, x| x == pn }]
        }
      }
    }
  end

  def seconds(r) = [MB::Sound::Param.magnitude(r.begin).to_f, MB::Sound::Param.magnitude(r.end).to_f]

  it 'finds the envelope, glide, and sweep times' do
    names = time_parameters.map { |_, pn, _, _| pn }.uniq
    expect(names).to include(:attack, :decay, :release, :time, :sweep_time, :drop_time, :index_decay, :glide_time)
    expect(names).not_to include(:glide, :hold, :sustain)
  end

  it "gives the inspector's bind a musical range for each, around a short or a long value" do
    time_parameters.map { |_, pn, _, _| pn }.uniq.each do |pn|
      [0.004, 2.5].each do |v|
        r = MB::Sound::Arrangement::LiteralBinding.knob_default(pn, v)
        lo, hi = seconds(r.range)
        expect(lo).to be <= 0.0001, "#{pn} at #{v}: #{r.range}"
        expect(hi).to be >= 10.0, "#{pn} at #{v}: #{r.range}"
        expect(MB::Sound::Param.magnitude(r.default).to_f).to be_within(1e-12).of(v)
      end
    end
  end

  it 'gives a fitted number at each a musical range on an exp curve' do
    time_parameters.each do |label, pn, kind, index|
      call = label.split('#').last
      slot = kind == :key ? pn : index
      entry = MB::Sound::FitPatch.time_entry([call, slot])
      expect(entry).not_to be_nil, "#{label} #{pn}"
      p = MB::Sound::FitPatch.musical_time(MB::Sound::Param.declare(:x, (0.001..0.02).at(0.005)), entry)
      expect(p.range.begin).to be <= 0.0001
      expect(p.range.end).to be >= 10.0
      expect(p.curve).to eq(:exp)
      expect(p.default).to eq(0.005)
    end
  end
end
