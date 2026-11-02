module MB
  module Sound
    module Tracker
      # Reads ProTracker-style MOD files (31 samples; the M.K. family and
      # the common multichannel signatures) into a Song.
      #
      # Layout (big-endian words): a 20-byte title; 31 sample headers of 30
      # bytes (name 22, length in words, finetune nibble, volume 0..64, loop
      # start and loop length in words); the song length, a restart byte,
      # 128 order entries, and a 4-byte signature at 1080 saying how many
      # channels; then the patterns (64 rows of 4-byte cells per channel:
      # sample number split over two nibbles, a 12-bit Amiga period, an
      # effect nibble and its parameter), then the samples' signed 8-bit
      # data in order.
      module ModReader
        # Signatures and their channel counts (xxCH/xxCN/TDZx/nCHN are
        # read from their digits).
        SIGNATURES = {
          'M.K.' => 4, 'M!K!' => 4, 'M&K!' => 4, 'FLT4' => 4, '4CHN' => 4, 'N.T.' => 4, 'FEST' => 4,
          'FLT8' => 8, 'CD81' => 8, 'OKTA' => 8, 'OCTA' => 8,
        }.freeze

        # The Amiga periods of five octaves at finetune 0 (ProTracker's
        # three plus the octaves above and below some trackers use), from
        # C-0 (note 36) to B-4 (note 95); period 428 is note 60.
        PERIODS = [
          1712, 1616, 1525, 1440, 1357, 1281, 1209, 1141, 1077, 1017, 961, 907,
          856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
          428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
          214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113,
          107, 101, 95, 90, 85, 80, 76, 71, 67, 64, 60, 57,
        ].freeze

        # The neutral note number of PERIODS[0].
        FIRST_NOTE = 36

        module_function

        # True if +bytes+ look like a MOD with a known signature.
        def match?(bytes)
          !channels_for(bytes.byteslice(1080, 4).to_s).nil?
        end

        # The channel count for signature +sig+, or nil.
        def channels_for(sig)
          return nil unless sig.bytesize == 4
          return SIGNATURES[sig] if SIGNATURES.key?(sig)
          return sig[0, 2].to_i if sig =~ /\A\d\dC[HN]\z/ && sig[0, 2].to_i.between?(1, 32)
          return sig[0].to_i if sig =~ /\A\dCHN\z/ && sig[0].to_i > 0
          return sig[3].to_i if sig =~ /\ATDZ\d\z/ && sig[3].to_i > 0
          nil
        end

        # The neutral note of Amiga +period+ (the nearest table period), or
        # nil for 0.
        def note_of(period)
          return nil if period.nil? || period <= 0
          i = PERIODS.each_index.min_by { |k| (Math.log(PERIODS[k].to_f / period)).abs }
          FIRST_NOTE + i
        end

        def read(bytes, name: 'module')
          b = Binary.new(bytes, name: name)
          sig = b.slice(1080, 4, 'the MOD signature')
          channels = channels_for(sig) or raise FormatError, "#{name}: not a 31-sample MOD (signature #{sig.inspect})"
          problems = []
          title = b.text(0, 20, 'the title')

          headers = Array.new(31) { |i|
            o = 20 + i * 30
            {
              name: b.text(o, 22, "sample #{i + 1}'s name"),
              length: b.u16be(o + 22) * 2,
              finetune: (b.u8(o + 24) & 0x0F).then { |f| f >= 8 ? f - 16 : f },
              volume: [b.u8(o + 25), 64].min,
              loop_start: b.u16be(o + 26) * 2,
              loop_length: b.u16be(o + 28) * 2,
            }
          }

          song_length = b.u8(950, 'the song length')
          restart = b.u8(951)
          table = Array.new(128) { |i| b.u8(952 + i, 'the order table') }
          song_length = 128 if song_length > 128
          song_length = 1 if song_length < 1
          orders = table.first(song_length)
          count = table.max + 1

          pattern_size = 64 * channels * 4
          offset = 1084
          available = (b.size - offset) / pattern_size
          if available < count
            problems << "#{count - available} of #{count} patterns are past the end of the file (left empty)"
          end
          patterns = Array.new(count) { |p|
            o = offset + p * pattern_size
            next Pattern.new(rows: Array.new(64) { Array.new(channels) }) if p >= available
            raw = b.slice(o, pattern_size, "pattern #{p}")
            Pattern.new(rows: Array.new(64) { |r|
              Array.new(channels) { |c|
                k = (r * channels + c) * 4
                b0, b1, b2, b3 = raw.getbyte(k), raw.getbyte(k + 1), raw.getbyte(k + 2), raw.getbyte(k + 3)
                cell(b0, b1, b2, b3)
              }
            })
          }

          offset += count * pattern_size
          samples = headers.each_with_index.map { |h, i|
            raw = b.clamped(offset, h[:length])
            problems << "sample #{i + 1} (#{h[:name]}) is truncated: #{raw.bytesize} of #{h[:length]} bytes" if raw.bytesize < h[:length]
            offset += h[:length]
            data = Binary.pcm8(raw)
            loop = loop_of(h, data.length)
            SampleData.new(name: h[:name], data: data.empty? ? [] : [data], rate: 8363.0, loop: loop, loop_mode: loop ? :forward : nil,
                           volume: h[:volume], finetune: h[:finetune], bits: 8)
          }

          Song.new(
            format: :mod, title: title, channels: channels, pans: Array.new(channels) { |c| [-1.0, 1.0, 1.0, -1.0][c % 4] },
            samples: samples, patterns: patterns, orders: orders, restart: restart < song_length ? restart : nil, speed: 6, tempo: 125,
            flags: { signature: sig }, problems: problems, tracker: tracker_name(sig)
          )
        end

        # The Cell of one MOD pattern entry's four bytes (nil if empty).
        def cell(b0, b1, b2, b3)
          sample = (b0 & 0xF0) | (b2 >> 4)
          period = ((b0 & 0x0F) << 8) | b1
          effect = b2 & 0x0F
          return nil if sample == 0 && period == 0 && effect == 0 && b3 == 0
          Cell.new(note: note_of(period), instrument: sample == 0 ? nil : sample, effect: effect == 0 && b3 == 0 ? nil : effect, param: b3,
                   period: period == 0 ? nil : period)
        end

        # The loop of a sample header (Range-like [start, end) in frames) or
        # nil: loops of one word are none; loop starts past the end are
        # read as bytes (an old SoundTracker habit), then clamped.
        def loop_of(h, length)
          return nil if h[:loop_length] <= 2 || length == 0
          start = h[:loop_start]
          start /= 2 if start + h[:loop_length] > length && (start / 2) + h[:loop_length] <= length
          stop = [start + h[:loop_length], length].min
          return nil if stop - start < 2 || start >= length
          [start, stop]
        end

        def tracker_name(sig)
          case sig
          when 'M.K.', 'M!K!' then 'ProTracker'
          when 'FLT4', 'FLT8' then 'StarTrekker'
          else "#{sig.strip} MOD"
          end
        end
      end
    end
  end
end
