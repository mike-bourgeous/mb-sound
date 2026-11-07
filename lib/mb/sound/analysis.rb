require_relative 'analysis/stft'
require_relative 'analysis/chroma'
require_relative 'analysis/key'
require_relative 'analysis/spectrum'
require_relative 'analysis/dsp'
require_relative 'analysis/signal'
require_relative 'analysis/modulation_spectrum'
require_relative 'analysis/pitch_contour'
require_relative 'analysis/perceived_pitch'
require_relative 'analysis/attack'
require_relative 'analysis/envelope'
require_relative 'analysis/pitch_envelope'
require_relative 'analysis/band_envelopes'
require_relative 'analysis/spectral_motion'
require_relative 'analysis/bleed'
require_relative 'analysis/comparison'
require_relative 'analysis/preferences'
require_relative 'analysis/look'
require_relative 'analysis/report'
require_relative 'analysis/impulse_response'

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
    #
    # The sound-matching toolkit (analysis-lib-1, 2026-11-03, from round 3
    # of the voice-match study; design/notes/analysis.md): Signal (one
    # sound at 48 kHz with its STFTs kept), ModulationSpectrum,
    # PitchContour, PerceivedPitch, Attack, BandEnvelopes, SpectralMotion,
    # Bleed, Comparison (L3) and Ranking, Preferences (does a distance
    # agree with a listener's picks?), Look (PNG images for reading), and
    # Report (all of it for one sound).  Entry points: Analysis.analyze,
    # .compare, .rank, .look (console: analyze, compare, look).
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
