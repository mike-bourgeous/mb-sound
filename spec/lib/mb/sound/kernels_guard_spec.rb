# The kernel registry's guard (kernels-1; see spec/support/kernels_guard.rb
# and design/notes/kernels.md): no C function without a registered Ruby
# mirror or a reason, no C call outside a registered kernel's C path, and
# no kernel without a compare spec.
require_relative '../../../support/kernels_guard'

RSpec.describe('MB::Sound::Kernels guard') do
  before(:all) { KernelsGuard.load_library }

  let(:kernels) { MB::Sound::Kernels }

  it 'covers every C function and class of the Fast* extensions with a kernel or a reason in UNMIRRORED' do
    covered = kernels.coverage
    missing = KernelsGuard.c_functions.reject { |f| covered.key?(f) || KernelsGuard.unmirrored(f) }
    expect(missing).to eq([]), "C functions without a registered mirror (Kernels.register) or an UNMIRRORED reason:\n#{missing.join("\n")}"
  end

  it 'names only C functions that exist in covers: and UNMIRRORED' do
    all = KernelsGuard.c_functions
    stale = kernels.coverage.keys.reject { |f| all.include?(f) }
    expect(stale).to eq([]), "covers: names no C function: #{stale.join(', ')}"
    gone = kernels::UNMIRRORED.keys.reject { |k| all.any? { |f| f == k || f.start_with?("#{k}.", "#{k}::") } }
    expect(gone).to eq([]), "UNMIRRORED names no C function: #{gone.join(', ')}"
  end

  it 'calls C functions in lib/ only from C paths (methods named *_c)' do
    stray = KernelsGuard.stray_calls
    expect(stray).to eq([]), "C calls outside a kernel's C path (call them through MB::Sound::Kernels, or move them into the registered *_c method):\n" +
      stray.map { |loc, name, d| "#{loc}: #{name} in #{d}" }.join("\n")
  end

  it 'gives every kernel a mirror, and names each spec that compares a kernel the sweep misses' do
    kernels.entries.each_value do |e|
      next if e.kind == :path

      expect(e.ruby).not_to be_nil, "#{e.name} has no Ruby mirror"
    end
    KernelsGuard::COMPARED_ELSEWHERE.each do |name, spec|
      e = kernels[name]
      path = File.join(KernelsGuard::ROOT, spec)
      expect(File.exist?(path)).to eq(true), "#{name}: #{spec} is missing"
      text = File.read(path)
      words = [name.to_s, *e.covers.map { |c| c.split('.').last }]
      expect(words.any? { |w| text.include?(w) }).to eq(true), "#{name}: #{spec} names neither the kernel nor its C function"
    end
  end

  it 'lists the C functions without a mirror' do
    # (the brief's "guard listing": printed for the record, checked above)
    list = KernelsGuard.c_functions.select { |f| KernelsGuard.unmirrored(f) }
    expect(list).to include('FastAudio.devices', 'FastRecipe.frame_binding')
  end

  it 'refuses unknown modes, names, and kernel names that would hide its own methods' do
    expect { kernels.mode = :fast }.to raise_error(ArgumentError, /:c, :ruby, :check/)
    expect { kernels.set(svff: :ruby) }.to raise_error(ArgumentError, /did you mean :svf/)
    expect { kernels.register(:with, c: ->(x) { x }, ruby: ->(x) { x }) }.to raise_error(ArgumentError, /hide/)
    expect(kernels.unknown_overrides).to eq([])
  end
end
