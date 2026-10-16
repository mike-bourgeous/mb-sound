# A tiny SoundFont 2 writer for specs (see MB::Sound::Sampler::SF2): builds
# the RIFF sfbk form with INFO, sdta (smpl, optionally sm24), and the pdta
# hydra from plain Hashes, so specs can make small fonts with exactly the
# zones, generators, and samples they test.
#
#     SF2Writer.write(path,
#       samples: [{ name: 'sine', data: [...floats...], rate: 44100, pitch: 60, loop: [100, 900] }],
#       instruments: [{ name: 'Sine', global: { attack_vol_env: -1200 }, zones: [{ key_range: [0, 63], sample_id: 0 }] }],
#       presets: [{ name: 'Sine', program: 0, zones: [{ instrument: 0 }] }])
#
# Generators are named as in SF2::GENERATORS (ranges as [lo, hi]); zone Hashes
# may hold +mods:+ (a count of dummy modulator records).  Samples: +data+
# (floats -1..1), +rate+, +pitch+ (original key), +correction+ (cents),
# +loop+ [start, end] relative to the sample, +type+ (1 mono, 2 right, 4
# left, 0x8001 ROM), +link+.  Options: +sm24+ (write 24-bit samples),
# +terminals+ (false leaves out the EOP/EOI/EOS records), +info+.
module SF2Writer
  G = MB::Sound::Sampler::SF2::GENERATOR_NUMBERS

  module_function

  def write(path, samples:, instruments:, presets:, sm24: false, terminals: true, info: { 'INAM' => 'Spec Font' })
    File.binwrite(path, build(samples: samples, instruments: instruments, presets: presets, sm24: sm24, terminals: terminals, info: info))
    path
  end

  def build(samples:, instruments:, presets:, sm24: false, terminals: true, info: {})
    words = []
    lows = []
    shdr = +''
    samples.each do |s|
      data = s[:data].to_a
      start = words.length
      data.each do |x|
        v = (x.clamp(-1.0, 1.0) * 8388607).round
        words << (v >> 8)
        lows << (v & 0xff)
      end
      46.times { words << 0; lows << 0 }
      loop = s[:loop] || [0, 0]
      shdr << [s[:name].to_s, start, start + data.length, start + loop[0], start + loop[1], s[:rate] || 44100, s[:pitch] || 60,
               s[:correction] || 0, s[:link] || 0, s[:type] || 1].pack('a20VVVVVCcvv')
    end
    shdr << ['EOS', 0, 0, 0, 0, 0, 0, 0, 0, 0].pack('a20VVVVVCcvv') if terminals

    phdr, pbag, pmod, pgen = hydra(presets, :instrument) { |p, bag| [p[:name].to_s, p[:program] || 0, p[:bank] || 0, bag, 0, 0, 0].pack('a20vvvVVV') }
    phdr << ['EOP', 0, 0, pbag.bytesize / 4, 0, 0, 0].pack('a20vvvVVV') if terminals
    inst, ibag, imod, igen = hydra(instruments, :sample_id) { |i, bag| [i[:name].to_s, bag].pack('a20v') }
    inst << ['EOI', ibag.bytesize / 4].pack('a20v') if terminals
    info_list = info.map { |id, text| chunk(id, text + "\0") }.join
    info_list = chunk('ifil', [2, 4].pack('vv')) + info_list
    sdta = chunk('smpl', words.pack('s<*'))
    sdta += chunk('sm24', lows.pack('C*')) if sm24
    pdta = chunk('phdr', phdr) + chunk('pbag', pbag) + chunk('pmod', pmod) + chunk('pgen', pgen) +
           chunk('inst', inst) + chunk('ibag', ibag) + chunk('imod', imod) + chunk('igen', igen) + chunk('shdr', shdr)
    body = 'sfbk' + list('INFO', info_list) + list('sdta', sdta) + list('pdta', pdta)
    'RIFF' + [body.bytesize].pack('V') + body
  end

  # [headers, bags, mods, gens] for presets or instruments (+terminal+ the
  # generator ending a local zone); the block packs one header.
  def hydra(list, terminal)
    headers = +''
    bags = +''
    mods = +''
    gens = +''
    list.each do |item|
      headers << yield(item, bags.bytesize / 4)
      zones = []
      zones << item[:global] if item[:global]
      zones.concat(item[:zones] || [])
      zones.each do |z|
        bags << [gens.bytesize / 4, mods.bytesize / 10].pack('vv')
        (z[:mods] || 0).times { mods << [0x0502, 48, 960, 0, 0].pack('vvs<vv') }
        ordered = z.reject { |k, _| k == :mods }.sort_by { |k, _| [k == :key_range ? 0 : k == :vel_range ? 1 : k == terminal ? 3 : 2] }
        ordered.each do |k, v|
          amount = v.is_a?(Array) ? (v[0] | (v[1] << 8)) : v
          gens << [G.fetch(k), amount].pack(amount.negative? ? 'vs<' : 'vv')
        end
      end
    end
    bags << [gens.bytesize / 4, mods.bytesize / 10].pack('vv')
    mods << [0, 0, 0, 0, 0].pack('vvs<vv')
    gens << [0, 0].pack('vv')
    [headers, bags, mods, gens]
  end

  def chunk(id, data)
    data = data.b
    id.b + [data.bytesize].pack('V') + data + (data.bytesize.odd? ? "\0" : '')
  end

  def list(type, data)
    chunk('LIST', type + data)
  end

  # A sine of +freq+ Hz at +rate+ for +n+ samples at +amp+.
  def sine(freq, n, rate: 44100, amp: 0.5)
    Array.new(n) { |i| amp * Math.sin(2 * Math::PI * freq * i / rate) }
  end
end
