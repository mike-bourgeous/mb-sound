require 'json'
require_relative '../../../test_data/make_tone_reference'

# Null tests for oscillators: every case in spec/support/tone_reference_cases.rb
# must give exactly the samples recorded before the Tone/Oscillator
# consolidation (spec/test_data/tone_reference.json; regenerate or diff with
# spec/test_data/make_tone_reference.rb).
#
# Intended differences (each re-recorded with a reason) are listed in
# INTENDED.
RSpec.describe('Tone null-test reference') do
  REFERENCE = JSON.parse(File.read(File.expand_path('../../../test_data/tone_reference.json', __dir__)))

  # Case name => why its reference was re-recorded.
  INTENDED = {}.freeze

  it 'has a reference for every case' do
    expect(REFERENCE.keys.sort).to eq(ToneReferenceCases::CASES.keys.sort)
  end

  ToneReferenceCases::CASES.each_key do |name|
    it "matches the reference for #{name}" do
      expected = REFERENCE.fetch(name)
      actual = ToneReference.run(name).transform_values { |d| ToneReference.digest(d) }

      expect(actual.keys.sort).to eq(expected.keys.sort)
      actual.each do |out, d|
        e = expected.fetch(out)
        expect(d['length']).to eq(e['length']), "#{name}.#{out}: length #{d['length']}, expected #{e['length']}"
        next if d['sha256'] == e['sha256']

        raise RSpec::Expectations::ExpectationNotMetError, format(
          "%s.%s differs: rms %.9g (expected %.9g), peak %.9g (expected %.9g), head %s (expected %s)",
          name, out, d['rms'], e['rms'], d['peak'], e['peak'], d['head'].first(4), e['head'].first(4)
        )
      end
    end
  end
end
