require 'prism'

# The kernel registry guard (kernels-1; MB::Sound::Kernels,
# design/notes/kernels.md): every C function of a Fast* extension module is
# covered by a registered kernel (with a Ruby mirror) or listed in
# Kernels::UNMIRRORED with a reason, lib/ calls C functions only from the C
# path of a registered kernel (a method named *_c), and every kernel with
# a mirror is compared somewhere: by the check-mode graph sweep
# (kernels_check_spec.rb) or by the spec COMPARED_ELSEWHERE names.
module KernelsGuard
  ROOT = File.expand_path('../..', __dir__)

  # Kernels the check-mode graph sweep doesn't reach, and the spec that
  # compares each with its mirror (the file must exist and name the
  # kernel's C function or its Kernels name).
  COMPARED_ELSEWHERE = {
    filter_tan: 'spec/lib/mb/sound/filter/four_pole_spec.rb',
    filter_tanh: 'spec/lib/mb/sound/filter/four_pole_spec.rb',
    filter_secant: 'spec/lib/mb/sound/filter/four_pole_spec.rb',
    resonance_curve: 'spec/lib/mb/sound/filter/four_pole_spec.rb',
    self_osc_gain: 'spec/lib/mb/sound/filter/four_pole_spec.rb',
    tuning_scale: 'spec/lib/mb/sound/filter/four_pole_spec.rb',
    diode_compensation: 'spec/lib/mb/sound/filter/diode_ladder_spec.rb',
    diode_cutoff_scale: 'spec/lib/mb/sound/filter/diode_ladder_spec.rb',
    diode_headroom: 'spec/lib/mb/sound/filter/diode_ladder_spec.rb',
    diode_loop_gain: 'spec/lib/mb/sound/filter/diode_ladder_spec.rb',
    diode_resonance_curve: 'spec/lib/mb/sound/filter/diode_ladder_spec.rb',
    wavetable_shape_at: 'spec/lib/mb/sound/wavetable_spec.rb',
    latency_bucket: 'spec/ext/mb/sound/fast_latency_spec.rb',
    latency_bucket_floor: 'spec/ext/mb/sound/fast_latency_spec.rb',
    latency_percentile: 'spec/ext/mb/sound/fast_latency_spec.rb',
  }.freeze

  module_function

  # Loads every lib/ file, so every kernel is registered and every
  # extension loaded.
  def load_library
    Dir[File.join(ROOT, 'lib/mb/sound/**/*.rb')].sort.each do |f|
      next if f.include?('/four_pole/make_tuning.rb') # (a generator script)

      require f
    end
  end

  # The Fast* extension modules (MB::FastSound, MB::Sound::Fast*,
  # MB::Term::FastTerm).
  def extension_modules
    ObjectSpace.each_object(Module).select { |m|
      m.name && m.name.match?(/\AMB::(Sound::|Term::)?Fast[A-Z]\w*\z/)
    }.sort_by(&:name)
  end

  # "Module.function" names of every C function, and "Module::Class" names
  # of every class an extension defines.
  def c_functions
    extension_modules.flat_map { |m|
      short = short_name(m)
      fns = m.singleton_methods(false).map { |f| "#{short}.#{f}" }
      classes = Module.instance_method(:constants).bind_call(m).filter_map { |c|
        v = m.const_get(c)
        "#{short}::#{c}" if v.is_a?(Module) && !(v.is_a?(Class) && v <= Exception)
      }
      fns + classes
    }.sort
  end

  def short_name(mod)
    mod.name.sub(/\AMB::(Sound::)?/, '')
  end

  # The UNMIRRORED entry covering +name+ ("FastAudio.devices" is covered by
  # "FastAudio"), or nil.
  def unmirrored(name)
    u = MB::Sound::Kernels::UNMIRRORED
    return name if u.key?(name)

    parts = name.split(/(?=[.:])/)
    (1...parts.length).map { |n| parts.first(n).join.sub(/::\z/, '') }.find { |p| u.key?(p) }
  end

  # Entries with a Ruby mirror that check mode compares.
  def checkable_entries
    MB::Sound::Kernels.entries.values.select { |e| e.kind != :path && e.check == true }
  end

  # Calls of C functions in lib/ outside a C path: [file:line, call, def].
  # A C path is a method named *_c (the +c:+ of a registered kernel or a
  # helper it calls); registrations (FastX.method(:y)) and C functions in
  # UNMIRRORED are allowed anywhere.
  def stray_calls
    Dir[File.join(ROOT, 'lib/**/*.rb')].sort.flat_map { |f| stray_calls_in(f) }
  end

  def stray_calls_in(path)
    found = []
    walk = lambda do |node, defs|
      return unless node.is_a?(Prism::Node)

      defs = defs + [node.name.to_s] if node.is_a?(Prism::DefNode)
      if node.is_a?(Prism::CallNode) && node.receiver && (mod = fast_module(node.receiver)) && node.name != :method && node.name != :respond_to?
        name = "#{mod}.#{node.name}"
        name = "#{mod}::#{node.name}" if node.name.to_s.match?(/\A[A-Z]/)
        unless unmirrored(name) || defs.last&.end_with?('_c', '_c?')
          found << ["#{path.delete_prefix(ROOT + '/')}:#{node.location.start_line}", name, defs.last || '(top level)']
        end
      end
      node.compact_child_nodes.each { |c| walk.(c, defs) }
    end
    walk.(Prism.parse_file(path).value, [])
    found
  end

  # The short name of a Fast* module a receiver names (FastFilter,
  # MB::Sound::FastFilter, MB::FastSound, FastAudio::Capture), else nil.
  def fast_module(node)
    text = node.slice
    return nil unless text.match?(/\A(::)?(MB::)?(Sound::|Term::)?Fast[A-Z]\w*(::[A-Z]\w*)?\z/)

    text.sub(/\A(::)?MB::(Sound::)?/, '').sub(/\A::/, '')
  end
end
