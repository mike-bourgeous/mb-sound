require_relative 'analysis/stft'
require_relative 'analysis/chroma'
require_relative 'analysis/key'

module MB
  module Sound
    # The listening tools' shared analysis layer (listen-1, 2026-10-30):
    # pure Ruby + Numo, offline.  STFT magnitudes a chunk at a time
    # (Analysis::STFT), chromagrams (Analysis::Chroma), keys by the
    # Krumhansl-Schmuckler method (Analysis::Key), and long-term spectra and
    # their tilt (Analysis::Spectrum).  Structure analysis
    # (MB::Sound::Structure) reads its frames through the same STFT and
    # chroma fold; Sample#detect_key, `loops(..., detect: true)`, and the
    # :match mastering preset read keys and spectra from here.
    module Analysis
      # A mono Numo::DFloat of +data+: a Numo array, an Array of channels
      # (averaged), or an Array of numbers.
      def self.mono(data)
        return Numo::DFloat.cast(data) if data.is_a?(Numo::NArray)
        raise ArgumentError, "Pass audio as a Numo array or an Array of channels (got #{data.class})" unless data.is_a?(Array) && !data.empty?
        return Numo::DFloat.cast(data) if data[0].is_a?(Numeric)
        data.map { |c| Numo::DFloat.cast(c) }.sum / data.length
      end
    end
  end
end
