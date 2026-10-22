# Perturbations for calibrating the sound guards (golden/calibration/calibrate.rb),
# loaded into a render process with RUBYOPT=-r<this file> and selected by
# MB_SOUND_GUARD_PERTURB:
#   buffer:N      - renders use N-sample buffers instead of 800 (inaudible)
#   tuning:NAME   - every lp4/diode uses tuning: NAME (:hardware: the
#                   pre-filters-1 cutoffs; audible on resonant patches)
#   cutoff:R      - every lp4/diode cutoff times R (1.1: a small move)
require 'mb-sound'

kind, value = ENV.fetch('MB_SOUND_GUARD_PERTURB', '').split(':', 2)
case kind
when 'buffer'
  size = Integer(value)
  MB::Sound.singleton_class.prepend(Module.new {
    define_method(:render_session) { |*a, **kw, &b| super(*a, **kw, buffer_size: size, &b) }
  })
when 'tuning'
  tuning = value.to_sym
  MB::Sound::Filter::FourPole.prepend(Module.new {
    define_method(:initialize) { |*a, **kw| super(*a, **kw, tuning: tuning) }
  })
when 'cutoff'
  ratio = Float(value)
  MB::Sound::GraphNode::FourPole.singleton_class.prepend(Module.new {
    define_method(:param) { |v, name, **kw|
      p = super(v, name, **kw)
      next p unless name == 'Cutoff'
      p.is_a?(Numeric) ? p * ratio : p * ratio
    }
  })
when nil, ''
else
  raise ArgumentError, "Unknown MB_SOUND_GUARD_PERTURB #{ENV['MB_SOUND_GUARD_PERTURB'].inspect}"
end
