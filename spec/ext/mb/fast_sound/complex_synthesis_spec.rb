# The complex synthesis integrals behind the naive complex oscillators,
# kept as Ruby methods aside from the live paths (ext/mb/fast_sound/
# complex_synthesis.c), against mb-math's Ruby versions.
RSpec.describe(MB::FastSound::ComplexSynthesis) do
  let(:points) { [0.3, 1.0, 2.5, Math::PI / 2 + 0.01, 4.0, 5.9, -2.0, 12.0] }

  def expect_close(a, b)
    expect(a.real).to be_within(1e-12).of(b.real)
    expect(a.imag).to be_within(1e-12).of(b.imag)
  end

  it 'computes csc_int like MB::M.csc_int, for real and complex arguments' do
    points.each { |x| expect_close(described_class.csc_int(x), MB::M.csc_int(x)) }
    [Complex(0.5, 0.1), Complex(3.0, -0.25)].each { |z| expect_close(described_class.csc_int(z), MB::M.csc_int(z)) }
  end

  it 'computes csc_int_int like MB::M.csc_int_int' do
    points.each { |x| expect_close(described_class.csc_int_int(x), MB::M.csc_int_int(x)) }
  end

  it 'computes cot_int like MB::M.cot_int, for real and complex arguments' do
    points.each { |x| expect_close(described_class.cot_int(x), MB::M.cot_int(x)) }
    [Complex(0.5, 0.1), Complex(3.0, -0.25)].each { |z| expect_close(described_class.cot_int(z), MB::M.cot_int(z)) }
  end

  it 'is no longer on FastSound itself, with the superseded helpers gone' do
    %i[csc_int csc_int_int cot_int adsr adsr_narray f64to32 fdiv fmod idiv imod narray_to_array remainder smootherstep wrap wrapsize complex].each do |name|
      expect(MB::FastSound).not_to respond_to(name)
    end
  end
end
