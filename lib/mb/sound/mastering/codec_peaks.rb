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
      #
      # AAC needs a faithful encoder (aac-peaks, 2026-10-23): ffmpeg's
      # built-in +aac+ encoder (7.1) puts 3-6 ms noise bursts louder than
      # the music above 3 kHz into hot, bright masters, so its decodes
      # peaked +4 to +12 dBTP where MP3, Opus, and Vorbis decodes of the
      # same files peaked about +1 (and ffmpeg's ebur128 agreed with our
      # meter on every decode).  Streaming services don't use it, so :aac
      # encodes with Fraunhofer's libfdk_aac or Apple's aac_at (ffmpeg on
      # macOS) and is nil (not measured) without either; :aac_ffmpeg
      # measures the built-in encoder on request.
      module CodecPeaks
        # Encoders: name => [ffmpeg arguments, file extension, what it
        # stands for].  Bit rates are the usual high-quality settings of
        # the services that use each codec.  :aac's arguments come from
        # AAC_ENCODERS (see .encoder_args).
        CODECS = {
          mp3: [%w[-c:a libmp3lame -b:a 320k], 'mp3', 'MP3 320 kbps (downloads, many players)'],
          aac: [nil, 'm4a', 'AAC 256 kbps (Apple Music, YouTube), with libfdk_aac or aac_at'],
          aac_ffmpeg: [%w[-c:a aac -b:a 256k], 'm4a', "AAC 256 kbps with ffmpeg's built-in encoder (overstates peaks)"],
          opus: [%w[-c:a libopus -b:a 160k], 'opus', 'Opus 160 kbps (YouTube)'],
          vorbis: [%w[-c:a libvorbis -q:a 9], 'ogg', 'Ogg Vorbis about 320 kbps (Spotify Very High)'],
        }.freeze

        # AAC encoders that encode like the services' (best first): ffmpeg
        # encoder name => arguments.
        AAC_ENCODERS = {
          'libfdk_aac' => %w[-c:a libfdk_aac -b:a 256k],
          'aac_at' => %w[-c:a aac_at -b:a 256k],
        }.freeze

        # The codecs measured when none are named.
        DEFAULT = %i[mp3 aac].freeze

        # Why a codec has no number (shown by .notes).
        UNMEASURED = {
          aac: "aac n/a: this ffmpeg has no libfdk_aac or aac_at, and its built-in AAC encoder adds noise bursts " \
               "that overstate decoded peaks by several dB (codecs: [:aac_ffmpeg] measures it anyway)",
        }.freeze

        # The names of the audio encoders the installed ffmpeg has (read
        # once per process).
        def self.encoders
          @encoders ||= begin
            out, _err, status = Open3.capture3('ffmpeg', '-nostdin', '-hide_banner', '-encoders')
            status.success? ? out.scan(/^\s*A\S*\s+(\S+)/).flatten.freeze : [].freeze
          rescue SystemCallError
            [].freeze
          end
        end

        # The ffmpeg encoder name +codec+ (see CODECS) encodes with, or nil
        # when no suitable encoder is installed (only :aac).
        def self.encoder_name(codec)
          if codec == :aac
            AAC_ENCODERS.each_key.find { |name| encoders.include?(name) }
          else
            CODECS.fetch(codec)[0][1]
          end
        end

        # The ffmpeg encoder arguments for +codec+, or nil (see
        # .encoder_name).
        def self.encoder_args(codec)
          return CODECS.fetch(codec)[0] unless codec == :aac

          name = encoder_name(:aac)
          name && AAC_ENCODERS[name]
        end

        # Encodes +source+ (a file path, or an Array of channels with
        # +sample_rate+) with each of +codecs+ (see CODECS), decodes it, and
        # returns { codec => true peak dBTP }, nil for a codec without a
        # suitable encoder (:aac without libfdk_aac or aac_at).
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
              args = encoder_args(c)
              next [c, nil] unless args

              encoded = File.join(dir, "encoded.#{CODECS[c][1]}")
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

        # The peaks of .measure as report text: "mp3 0.52, aac n/a".
        def self.text(peaks)
          peaks.map { |c, tp| tp ? format('%s %.2f', c, tp) : "#{c} n/a" }.join(', ')
        end

        # Lines explaining the unmeasured codecs of +peaks+ (see .text).
        def self.notes(peaks)
          peaks.filter_map { |c, tp| UNMEASURED[c] if tp.nil? }
        end

        # The measured peaks of +peaks+ over +limit+ dBTP.
        def self.overs(peaks, limit)
          (peaks || {}).select { |_c, tp| tp && tp > limit }
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
