require 'tmpdir'
require 'open3'

module MB
  module Sound
    module Mastering
      # Decoded true peaks of lossy encodes (mastering-1): lossy encoders
      # remove and smear high frequencies, so the decoded waveform peaks
      # above the master (often 0.5-1 dB, more for loud, bright masters),
      # and a master at -0.5 dBTP can clip a player's DAC after decoding.
      # Offline only: encodes with ffmpeg and measures the decoded audio
      # (BS.1770 Annex 2 true peak).
      module CodecPeaks
        # Encoders: name => [ffmpeg arguments, file extension, what it
        # stands for].  Bit rates are the usual high-quality settings of
        # the services that use each codec.
        CODECS = {
          mp3: [%w[-c:a libmp3lame -b:a 320k], 'mp3', 'MP3 320 kbps (downloads, many players)'],
          aac: [%w[-c:a aac -b:a 256k], 'm4a', 'AAC 256 kbps (Apple Music, YouTube)'],
          opus: [%w[-c:a libopus -b:a 160k], 'opus', 'Opus 160 kbps (YouTube)'],
          vorbis: [%w[-c:a libvorbis -q:a 9], 'ogg', 'Ogg Vorbis about 320 kbps (Spotify Very High)'],
        }.freeze

        # The codecs measured when none are named.
        DEFAULT = %i[mp3 aac].freeze

        # Encodes +source+ (a file path, or an Array of channels with
        # +sample_rate+) with each of +codecs+ (see CODECS), decodes it, and
        # returns { codec => true peak dBTP }.
        def self.measure(source, codecs: DEFAULT, sample_rate: 48000)
          codecs = Array(codecs)
          unknown = codecs - CODECS.keys
          raise ArgumentError, "Unknown codec #{unknown.map(&:inspect).join(', ')} (use #{CODECS.keys.map(&:inspect).join(', ')})" unless unknown.empty?

          Dir.mktmpdir('mb_sound_codec') do |dir|
            path = source
            unless source.is_a?(String)
              path = File.join(dir, 'master.flac')
              MB::Sound.write(path, source, sample_rate: sample_rate)
            end

            codecs.to_h { |c|
              args, ext, _ = CODECS[c]
              encoded = File.join(dir, "encoded.#{ext}")
              _out, err, status = Open3.capture3('ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-i', path, *args, encoded)
              raise IOError, "ffmpeg couldn't encode #{c}: #{err.strip}" unless status.success?

              # (decoded at 48 kHz; Opus decodes there anyway)
              data = MB::Sound.read(encoded)
              a = Loudness::Analyzer.new(channels: data.length, sample_rate: 48000)
              a.process(data)
              [c, a.true_peak]
            }
          end
        end
      end

      # Decoded true peaks of lossy encodes of +source+ (see CodecPeaks).
      #
      #     Mastering.codec_peaks('song.flac')   # => { mp3: -0.21, aac: -0.35 }
      def self.codec_peaks(source, codecs: CodecPeaks::DEFAULT, sample_rate: 48000)
        CodecPeaks.measure(source, codecs: codecs, sample_rate: sample_rate)
      end
    end
  end
end
